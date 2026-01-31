> *"Move fast and break things"* — Mark Zuckerberg  
> *"I moved fast. Things are broken."* — Me, at 3 AM  
> *"Have you tried turning it off and on again?"* — My mom, who has heard enough

Welcome to **dev-oops** — my personal laboratory where I cosplay as a DevOps engineer, ARP-spoof my children's tablets, and treat `terraform destroy` as a form of meditation.

This is what happens when you have more CPU cores than friends.

---

## What is This?

This repository contains **enterprise-grade infrastructure** for a **hobbyist-grade homelab**. It's over-engineered, over-documented, and occasionally over-heated.

I treat my homelab like a Fortune 500 company's infrastructure, except:
- My SLA is "probably up"
- My incident response is "wake up and panic"  
- My disaster recovery plan is "cry, then restore from ~~backup~~ MinIO"
- My change management process is `git push --force` and pray
- My parental controls involve **literal ARP poisoning** (see: [The Sentry Project](#-parental-controls-via-cyberwarfare))

---

## The Victim (Hardware Specs)

| Component | Spec | Notes |
|-----------|------|-------|
| **CPU** | 56 x Intel Xeon E5-2680 v4 @ 2.40GHz | Two sockets of raw, slightly-aged power |
| **RAM** | 62GB | Enough to run Kubernetes. Barely. |
| **Boot Mode** | Legacy BIOS | *"I don't do UEFI here"* |
| **Hypervisor** | Proxmox VE 9.0.3 | The backbone of my chaos |
| **Kernel** | Linux 6.14.8-2-pve | Latest and greatest (until tomorrow) |
| **Electricity Bill** | Yes | I don't talk about this |

### Storage Situation

```
┌─────────────┬─────────┬──────────────────────────────────────────────┐
│ Device      │ Size    │ Purpose                                      │
├─────────────┼─────────┼──────────────────────────────────────────────┤
│ sda         │ 465.8G  │ Spinning rust from 2014 (the "OG")           │
│ sdb         │ 931.5G  │ More spinning rust (the "backup OG")         │
│ nvme0n1     │ 1.8T    │ The fast boi (VMs live here, briefly)        │
└─────────────┴─────────┴──────────────────────────────────────────────┘
```

### The Production Network (ansible/core/inventory.ini)

```
┌─────────────────────┬────────────────┬──────────────────────────────────────┐
│ Host                │ IP             │ What It Does                         │
├─────────────────────┼────────────────┼──────────────────────────────────────┤
│ pve-master          │ 192.168.1.120  │ Proxmox Hypervisor (the boss)        │
│ ubuntu-server       │ 192.168.1.121  │ Docker + Traefik (the workhorse)     │
│ teleport            │ 192.168.1.122  │ Zero-trust access (fancy SSH)        │
│ vpn-server          │ 192.168.1.123  │ OpenVPN (for remote chaos)           │
│ hephaestus          │ 192.168.1.124  │ CI/CD runners (Greek god vibes)      │
│ sonarqube           │ 192.168.1.125  │ Code quality (yes, I lint my code)   │
│ core-dns            │ 192.168.1.126  │ Internal DNS (Alpine, 128MB RAM)     │
│ crowdsec            │ 192.168.1.127  │ WAF / Security engine (the bouncer)  │
├─────────────────────┼────────────────┼──────────────────────────────────────┤
│                     │  PRIVATE NET   │  192.168.99.0/24                     │
├─────────────────────┼────────────────┼──────────────────────────────────────┤
│ lxc-postgresql-16   │ 192.168.99.2   │ PostgreSQL in LXC (the elephant)     │
│ lxc-kafka           │ 192.168.99.2   │ Kafka (enterprise cosplay)           │
└─────────────────────┴────────────────┴──────────────────────────────────────┘
```

---

## Architecture (a.k.a. "The Overkill")

```
                    ┌──────────────────────────────────────────────────┐
                    │                   THE INTERNET                    │
                    │              (where the danger lives)             │
                    └───────────────────────┬──────────────────────────┘
                                            │
                                            ▼
                    ┌──────────────────────────────────────────────────┐
                    │                   CLOUDFLARE                      │
                    │    DNS, Firewall, "Please don't DDoS me" layer   │
                    │         Domain: datrollout.dev (nice)             │
                    │              (Managed by Terraform)               │
                    └───────────────────────┬──────────────────────────┘
                                            │
                                            ▼
                    ┌──────────────────────────────────────────────────┐
                    │               UPTIMEROBOT                         │
                    │     "Is it down? Let me text you at 3 AM"        │
                    │              (Also Terraform'd)                   │
                    └───────────────────────┬──────────────────────────┘
                                            │
                                            ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                              PROXMOX VE (pve-master)                        │
│                    (The hypervisor that runs everything)                     │
│                              192.168.1.120                                   │
│                                                                              │
│ ═══════════════════════════ 🏭 PRODUCTION ═══════════════════════════════   │
│                                                                              │
│  ┌─────────────────────────────────────────────────────────────────────┐    │
│  │              🐳 UBUNTU-SERVER VM (192.168.1.121)                     │    │
│  │                    "The Docker Workhorse"                           │    │
│  │                  (Managed by ansible/core)                          │    │
│  │                                                                      │    │
│  │   ══════════════ TRAEFIK v3.6.7 (The Gateway) ══════════════       │    │
│  │   │ :80/:443 → CrowdSec middleware → Services                │      │    │
│  │   │ Let's Encrypt SSL via Cloudflare DNS challenge           │      │    │
│  │   ═══════════════════════════════════════════════════════════       │    │
│  │                              │                                       │    │
│  │                              ▼                                       │    │
│  │   ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌──────────┐              │    │
│  │   │  GitLab  │ │Vaultwarden│ │ Jellyfin │ │Nextcloud │              │    │
│  │   │  CI/CD   │ │ Passwords │ │ "Linux   │ │  Files   │              │    │
│  │   │  + Repos │ │           │ │  ISOs"   │ │          │              │    │
│  │   └──────────┘ └──────────┘ └──────────┘ └──────────┘              │    │
│  │                                                                      │    │
│  │   ┌──────────┐ ┌──────────┐ ┌──────────┐                           │    │
│  │   │qBittorrent│ │Agent DVR │ │ useless- │                           │    │
│  │   │ "Linux   │ │ Cameras  │ │  app.yaml│                           │    │
│  │   │  ISOs"   │ │  🎥      │ │    ???   │                           │    │
│  │   └──────────┘ └──────────┘ └──────────┘                           │    │
│  │                                                                      │    │
│  │   ┌─────────────────────────────────────────────────────────┐      │    │
│  │   │              📊 OBSERVABILITY STACK                      │      │    │
│  │   │  Prometheus │ Grafana │ Loki │ Alloy │ InfluxDB │ cAdvisor    │    │
│  │   │           "Watching containers die in 4K"                │      │    │
│  │   └─────────────────────────────────────────────────────────┘      │    │
│  │                                                                      │    │
│  │   💾 Backups: restic → rclone → cloud (I learned the hard way)    │    │
│  └─────────────────────────────────────────────────────────────────────┘    │
│                                                                             │
│  ┌─────────────────────────────────────────────────────────────────────┐    │
│  │              🔬 SONARQUBE VM (192.168.1.125)                         │    │
│  │                    Code Quality Analysis                            │    │
│  │           "Yes, I run static analysis on my homelab code"           │    │
│  └─────────────────────────────────────────────────────────────────────┘    │
│                                                                             │
│  ┌─────────────────────────────────────────────────────────────────────┐    │
│  │                     📦 LXC CONTAINERS                               │    │
│  │               (Because VMs are too mainstream)                      │    │
│  │                                                                      │    │
│  │   ┌─────────────────┐ ┌─────────────────┐ ┌─────────────────┐      │    │
│  │   │ PostgreSQL 16   │ │ Kafka           │ │ CoreDNS         │      │    │
│  │   │ 192.168.99.2    │ │ 192.168.99.x    │ │ 192.168.1.126   │      │    │
│  │   │ 4GB RAM         │ │ 8GB RAM         │ │ 128MB RAM 😎    │      │    │
│  │   │ (Private Net)   │ │ (Private Net)   │ │ Alpine Linux    │      │    │
│  │   └─────────────────┘ └─────────────────┘ └─────────────────┘      │    │
│  │                                                                      │    │
│  │   ┌─────────────────┐                                               │    │
│  │   │ CrowdSec WAF    │                                               │    │
│  │   │ 192.168.1.127   │ ← "You shall not pass"                        │    │
│  │   │ LAPI + AppSec   │                                               │    │
│  │   └─────────────────┘                                               │    │
│  └─────────────────────────────────────────────────────────────────────┘    │
│                                                                             │
│  ┌─────────────────────────────────────────────────────────────────────┐    │
│  │            🛡️ SECURITY LAYER (The Actually Serious Part)            │    │
│  │                                                                      │    │
│  │   ┌──────────────────────────────────────────────────────────────┐  │    │
│  │   │ TRAEFIK v3.6.7 (192.168.30.50 / :80, :443)                   │  │    │
│  │   │   • Reverse proxy for all services                           │  │    │
│  │   │   • Let's Encrypt SSL via Cloudflare DNS challenge          │  │    │
│  │   │   • Prometheus metrics + access logging                      │  │    │
│  │   │   • CrowdSec bouncer plugin middleware                       │  │    │
│  │   │   • Cloudflare trusted IPs (CF-Connecting-IP header)         │  │    │
│  │   └──────────────────────────────────────────────────────────────┘  │    │
│  │                              │                                       │    │
│  │                              ▼                                       │    │
│  │   ┌──────────────────────────────────────────────────────────────┐  │    │
│  │   │ CROWDSEC (192.168.1.127) - "The Bouncer"                     │  │    │
│  │   │   • LAPI on :8080                                            │  │    │
│  │   │   • AppSec engine on :7422                                   │  │    │
│  │   │   • Detects: XSS, Path Traversal, Brute Force               │  │    │
│  │   │   • Mode: LIVE (blocks bad actors in real-time)              │  │    │
│  │   │   • "You shall not pass" energy                              │  │    │
│  │   └──────────────────────────────────────────────────────────────┘  │    │
│  │                                                                      │    │
│  │   ┌──────────────────────────────────────────────────────────────┐  │    │
│  │   │ COREDNS (192.168.1.126) - Alpine, 128MB RAM                  │  │    │
│  │   │   Internal DNS resolution                                    │  │    │
│  │   └──────────────────────────────────────────────────────────────┘  │    │
│  └─────────────────────────────────────────────────────────────────────┘    │
│                                                                             │
│  ┌─────────────────────────────────────────────────────────────────────┐    │
│  │               🔐 TELEPORT (192.168.1.122)                           │    │
│  │                   Zero-Trust Access                                 │    │
│  │           "SSH but make it enterprise"                              │    │
│  └─────────────────────────────────────────────────────────────────────┘    │
│                                                                             │
│  ┌─────────────────────────────────────────────────────────────────────┐    │
│  │               🔒 VPN-SERVER (192.168.1.123)                         │    │
│  │                      OpenVPN                                        │    │
│  │           "For when you're not at home"                             │    │
│  └─────────────────────────────────────────────────────────────────────┘    │
│                                                                             │
│  ┌─────────────────────────────────────────────────────────────────────┐    │
│  │              🏛️ HEPHAESTUS (192.168.1.124)                          │    │
│  │              "Named after the Greek god of craftsmanship"           │    │
│  │                                                                      │    │
│  │          GitLab Runner │ GitHub Runner │ Maven │ Go │ K8s Tools     │    │
│  └─────────────────────────────────────────────────────────────────────┘    │
│                                                                             │
│  ┌─────────────────────────────────────────────────────────────────────┐    │
│  │                     🕵️ THE SENTRY (Planned)                         │    │
│  │              "Parental Controls via ARP Poisoning"                  │    │
│  │      Because asking nicely doesn't work on tablets at 1 AM          │    │
│  └─────────────────────────────────────────────────────────────────────┘    │
│                                                                             │
│ ═══════════════════════════ 🧪 LAB / DEV ════════════════════════════════   │
│                                                                              │
│  ┌─────────────────────────────────────────────────────────────────────┐    │
│  │                    K3s KUBERNETES CLUSTER                           │    │
│  │        🚧 LAB ENVIRONMENT ONLY - NOT PRODUCTION 🚧                  │    │
│  │            (Migration aborted, now it's a playground)               │    │
│  │                                                                      │    │
│  │  "I tried to migrate to K8s. K8s won. Now it's where I test things │    │
│  │   before they go to the real Docker setup. Or break things on      │    │
│  │   purpose with Chaos Mesh. Mostly the second one."                 │    │
│  │                                                                      │    │
│  │   ArgoCD │ Traefik │ Longhorn │ Sealed Secrets │ Chaos Mesh        │    │
│  │   PostgreSQL │ Redis │ MinIO │ Vaultwarden │ qBittorrent           │    │
│  │                                                                      │    │
│  │   Status: ✨ Learning ✨ Testing ✨ Breaking ✨                       │    │
│  └─────────────────────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## Repository Structure

```
dev-oops/
├── ansible/                    # Configuration Management
│   ├── core/                   # 🏭 THE PRODUCTION STUFF
│   │   ├── inventory.ini      # The network map (192.168.1.x gang)
│   │   ├── hephaestus/        # CI/CD runners (Greek god = extra cool points)
│   │   ├── lxc/               # PostgreSQL 16, Kafka in containers
│   │   │   ├── postgresql/    # The elephant (192.168.99.2)
│   │   │   └── kafka/         # Message queue for enterprise cosplay
│   │   ├── teleport/          # Zero-trust access (fancy SSH for fancy people)
│   │   ├── ubuntu-server/     # THE DOCKER WORKHORSE
│   │   │   ├── apps/          # GitLab, Jellyfin, Nextcloud, qBittorrent...
│   │   │   │   └── useless-app.yaml   # Yes, this exists. No, I won't explain.
│   │   │   ├── basic/         # apt, samba, storage, swap, user management
│   │   │   ├── observation-and-monitoring/  # Grafana, Prometheus, Loki, Alloy
│   │   │   └── system-cron/   # Backups via restic (I learned my lesson)
│   │   └── vpn-server/        # OpenVPN because WireGuard is too easy
│   ├── kubernetes/            # Kubespray configs (deprecated)
│   └── sonarqube/             # Code quality (yes, I lint my YAML. Judge me.)
│
├── kubernetes/                 # 🧪 LAB ENVIRONMENT ONLY
│   ├── argocd/                # GitOps playground
│   │   ├── argocd-app/        # Application definitions
│   │   │   ├── daemon/        # Kube-Prometheus-Stack, MetalLB
│   │   │   ├── stateful/      # PostgreSQL, Redis, MinIO, Longhorn, CHAOS MESH
│   │   │   └── stateless/     # Traefik, Vaultwarden, Sealed Secrets
│   │   └── argocd-crd/        # ArgoCD itself (it's ArgoCD all the way down)
│   └── traefik/               # Ingress controller configs
│   # ⚠️  This is NOT production! Just a place to test K8s concepts
│   #     and break things with Chaos Mesh before giving up and
│   #     going back to Docker like a sensible person.
│
├── tf/                        # Terraform (Infrastructure as Code)
│   ├── cloudflare/            # DNS & Storage for datrollout.dev
│   ├── proxmox/               # VM provisioning
│   ├── openstack/             # Because why not add another cloud?
│   ├── uptimerobot/           # "Is it down?" → "Yes, check Discord"
│   └── terraform-module/      # Reusable modules (I're professionals here)
│
├── disaster-recovery/         # For when things go wrong (often)
│   └── vaultwarden/           # Python backup scripts to MinIO
│       └── Backup/            # Because losing passwords is NOT an option
│
└── plans/                     # Future chaos documentation
    └── use-side-arm-arp-interception.md   # *chef's kiss* (see below)
```

---

## 🛡️ Security Stack (The Actually Professional Part)

Traffic flows through multiple security layers before reaching any service:

```
Internet 🌐
    │
    ▼
┌────────────────────────────────────────────────────────────────────────┐
│                         CLOUDFLARE                                      │
│   • DDoS protection ("Please don't hurt me")                           │
│   • DNS management (datrollout.dev)                                    │
│   • Firewall rules (Terraform managed)                                 │
│   • Proxy mode enabled (hides real IP)                                 │
└────────────────────────────────────────────────────────────────────────┘
    │ CF-Connecting-IP header
    ▼
┌────────────────────────────────────────────────────────────────────────┐
│                     TRAEFIK v3.6.7                                      │
│   • Reverse proxy on 192.168.1.121:80/443                              │
│   • Let's Encrypt SSL via Cloudflare DNS challenge                     │
│   • Routes: gitlab, vaultwarden, nextcloud, jellyfin, teleport...      │
│   • Every request passes through CrowdSec middleware                   │
│   • Prometheus metrics + structured access logs                        │
└────────────────────────────────────────────────────────────────────────┘
    │ crowdsec@file middleware
    ▼
┌────────────────────────────────────────────────────────────────────────┐
│                     CROWDSEC (192.168.1.127)                            │
│   LXC Container - "The Bouncer"                                        │
│                                                                        │
│   LAPI (:8080)           AppSec Engine (:7422)                         │
│   ├─ Decision API        ├─ Real-time request analysis                 │
│   ├─ Ban/Captcha         ├─ HTTP path traversal detection              │
│   └─ IP reputation       ├─ XSS probing detection                      │
│                          └─ Generic brute force detection              │
│                                                                        │
│   Mode: LIVE (blocks in real-time, not just logging)                   │
│   Failure behavior: BLOCK (if CrowdSec is down, deny all)              │
│   "I'd rather break the site than let hackers in"                      │
└────────────────────────────────────────────────────────────────────────┘
    │ ✅ Allowed
    ▼
┌────────────────────────────────────────────────────────────────────────┐
│                      The actual userful services                       │
│   GitLab │ Vaultwarden │ Nextcloud │ Jellyfin │ SonarQube │ etc.       │
└────────────────────────────────────────────────────────────────────────┘
```

### Security Scenarios Protected Against

| Attack Type | Detection | Response |
|-------------|-----------|----------|
| **Path Traversal** | `crowdsecurity/http-path-traversal-probing` | 403 Forbidden |
| **XSS Probing** | `crowdsecurity/http-xss-probing` | 403 Forbidden |
| **Brute Force** | `crowdsecurity/http-generic-bf` | 403 + Temp Ban |
| **DDoS** | Cloudflare | Mitigation |
| **Bot Traffic** | CrowdSec community blocklists | 403 Forbidden |

### The "Trust No One" Philosophy

```yaml
# If CrowdSec AppSec is unreachable:
crowdsecAppsecUnreachableBlock: true  # BLOCK EVERYTHING

# If CrowdSec fails:
crowdsecAppsecFailureBlock: true      # BLOCK EVERYTHING

# Translation: "I'd rather explain downtime than a breach"
```

---

## 🕵️ Parental Controls via Cyberwarfare

> **ADR Status:** Accepted  
> **Codename:** Homelab Sentry  
> **mAF (mom Acceptance Factor):** Pending review

When `Screen Time` isn't enough and you have a Proxmox server with existential anxiety, you build a **Man-in-the-Middle attack framework** for your home network.

### The Plan

```
Normal Network:
iPad 🧒 ──────────────────────────► Router 📡 ──► Internet

After I'm Done:
iPad 🧒 ──► Sentry VM 🕵️ ──► Router 📡 ──► Internet
                │
                └── "Is it 1 AM? DROP PACKET."
                └── "Is it homework time? Block YouTube DNS."
                └── "Alert Dad via Telegram Bot."
```

### Features (Planned)
- **ARP Poisoning:** Whispers to the iPad: *"I am the router now"*
- **Time-based blocking:** No internet after 1 AM (the hard way)
- **DNS Sinkholing:** YouTube resolves to a "Go to bed" page
- **Telegram Bot:** `/allow 1h` when they've been good
- **Graceful Shutdown:** Floods correct ARP packets on exit so WiFi doesn't die when Proxmox reboots

### Risks
- IP conflicts if I mess up broadcasts
- Explaining to my mom why I'm "hacking the children"
- Slight latency increase (4K streaming might suffer)
- The kids might learn networking to fight back

---

## The Stack of Chaos

### Infrastructure Layer
| Tool | Purpose | Status |
|------|---------|--------|
| **Proxmox VE** | Hypervisor | 🟢 Running (pve-master) |
| **Terraform** | Infrastructure as Code | 🟢 Running |
| **Cloudflare** | DNS & Security | 🟢 Running |
| **OpenStack** | ??? | 🟡 It's in the tf folder, I'll figure it out |

### Configuration Management
| Tool | Purpose | Chaos Level |
|------|---------|-------------|
| **Ansible** | Server configuration (🏭 PRODUCTION) | 🔥🔥 Medium (YAML indentation trauma) |
| **ansible/core** | The actual production playbooks | 🔥🔥 Medium (but it works!) |
| **Kubespray** | K8s deployment | 🔥🔥🔥 Deprecated (I gave up) |

### Container Orchestration
| Tool | Purpose | Environment | Chaos Level |
|------|---------|-------------|-------------|
| **Docker** | Container runtime | 🏭 PRODUCTION | 🔥🔥 Medium (I know this one) |
| **Traefik** | Reverse proxy & SSL | 🏭 PRODUCTION | 🔥🔥 Medium (middleware inception) |
| **K3s** | Lightweight Kubernetes | 🧪 LAB ONLY | 🔥🔥🔥🔥 Extreme (it's still Kubernetes) |
| **ArgoCD** | GitOps deployment | 🧪 LAB ONLY | 🔥🔥 Medium (fun to learn) |
| **Longhorn** | Distributed storage | 🧪 LAB ONLY | 🔥🔥🔥 High (distributed = distributed problems) |
| **Chaos Mesh** | Breaking things on purpose | 🧪 LAB ONLY | 🔥🔥🔥🔥🔥 MAXIMUM (by design) |

> **Why K8s is lab-only:** I tried to migrate from Docker to K8s. I really did. But you know what? Docker Compose + Ansible just works™. The K8s cluster now serves as a playground for learning, testing configs, and occasionally running Chaos Mesh to watch pods die for educational purposes.

### Observability (Watching Things Break)
| Tool | Purpose | Chaos Level |
|------|---------|-------------|
| **Prometheus** | Metrics collection | 🔥🔥 Medium |
| **Grafana** | Pretty dashboards | 🔥 Low (the fun part) |
| **Loki** | Log aggregation | 🔥🔥 Medium |
| **Alloy** | Telemetry collector | 🔥🔥 Medium (new hotness) |
| **InfluxDB** | Time-series DB | 🔥🔥 Medium |
| **UptimeRobot** | External monitoring | 🔥 Low (it texts me at 3 AM) |

### Applications (The Actual Useful Stuff)
| App | Purpose | Why |
|-----|---------|-----|
| **GitLab** | Git hosting & CI/CD | Self-hosted GitHub at home |
| **Vaultwarden** | Password manager | Because I can't remember anything |
| **Nextcloud** | File sync | Google Drive but with more RAM usage |
| **Jellyfin** | Media server | "Linux ISOs" streaming |
| **qBittorrent** | Torrent client | For "Linux ISOs" |
| **Agent DVR** | Security cameras | Watching the driveway, professionally |
| **PostgreSQL** | Database | The elephant in the room |
| **Kafka** | Message queue | Because why not? |
| **Redis** | Cache | Speed |
| **MinIO** | Object storage | S3 at home (for backups, mostly) |
| **Teleport** | Zero-trust access | SSH but enterprise-grade |
| **SonarQube** | Code quality | Yes, I lint my homelab code |
| **useless-app** | Unknown | The YAML exists. That's all I know. |

### Security Layer
| Tool | Purpose | Vibe |
|------|---------|------|
| **Traefik v3.6.7** | Reverse proxy + SSL | The front door |
| **CrowdSec** | WAF + Threat detection | The bouncer |
| **CoreDNS** | Internal DNS | 128MB of pure resolution |
| **Cloudflare** | DDoS + DNS + CDN | The bodyguard |
| **Let's Encrypt** | SSL certs | Free HTTPS via DNS challenge |

---

## CI/CD: The Hephaestus System

Named after the **Greek god of fire, metalworking, and craftsmanship**, our CI/CD runner infrastructure auto-provisions:

- 🔨 **GitLab Runner** — for the self-hosted git
- 🐙 **GitHub Runner** — for the cloud repos  
- ☕ **Maven** — Java builds
- 🐹 **Golang** — Go builds
- 🎡 **K8s Tools** — kubectl, helm, the works
- 🐳 **Docker** — containers all the way down

All managed by Ansible because manually installing runners is for mortals.

---

## Lessons Learned (The Hard Way)

### Things I've Broken (So Far)

- [x] Deleted production database (it was just my passwords, no big deal)
- [x] Ran `terraform destroy` on the wrong workspace
- [x] Forgot to backup before "quick fix"
- [x] Locked myself out of my own server
- [x] Filled up the boot disk with logs
- [x] Created an infinite ArgoCD sync loop
- [x] Misconfigured firewall, couldn't SSH in
- [x] Tried to migrate from Docker to K8s
- [x] Gave up on K8s migration (Docker + Ansible supremacy)
- [x] Kept K8s cluster anyway as "learning environment" (cope)
- [x] Installed Chaos Mesh and immediately regretted it
- [ ] Successfully ARP-spoofed my kids (coming soon)
- [ ] Lost data permanently (knock on wood 🪵)

### Lessons Actually Learned
1. **Always backup Vaultwarden** — hence the Python scripts to MinIO
2. **Docker + Ansible is fine** — K8s is cool but production uptime is cooler
3. **K8s is great... for learning** — keep it as a lab, not production
4. **Chaos Mesh is both amazing and terrifying** — USE WITH CAUTION (in lab only)
5. **Name things after Greek gods** — makes debugging feel epic
6. **Document your ARP spoofing plans** — your future self will thank you
7. **LXC for databases, VMs for apps** — this actually works really well

---

## File Highlight Reel

| File | What It Does | Concern Level |
|------|--------------|---------------|
| `useless-app.yaml` | Deploys... something? | 🤷 |
| `use-side-arm-arp-interception.md` | Tactical child network control | 👀 |
| `delete-crd.sh` | Exactly what it sounds like | 💀 |
| `chaos-mesh/argo-app.yaml` | Automated breaking things | 🔥 |
| `backup.sh` (in Vaultwarden) | The most important file | 🙏 |

---

## Getting Started (For the Brave)

```bash
# Step 1: Clone this chaos
git clone https://github.com/ngodat0103/dev-oops.git
cd dev-oops

# Step 2: Terraform your cloud resources
cd tf/cloudflare && terraform init && terraform apply

# Step 3: Ansible your PRODUCTION servers (the real stuff)
cd ../../ansible/core
ansible-playbook -i inventory.ini ubuntu-server/basic/apt.yaml       # Base setup
ansible-playbook -i inventory.ini ubuntu-server/apps/gitlab.yaml     # GitLab
ansible-playbook -i inventory.ini ubuntu-server/apps/traefik.yaml    # Reverse proxy
ansible-playbook -i inventory.ini lxc/postgresql/0-manage-postgresql.yaml  # DB

# Step 4: (Optional) Play with K8s lab environment
cd ../../kubernetes/argocd
# This is just for learning, not production. Go wild. Break things.
kubectl apply -f argocd-crd/

# Step 5: Watch it all in Grafana
# Step 6: Get paged at 3 AM by UptimeRobot
# Step 7: Fix it half-asleep
# Step 8: Write a postmortem you'll never read
# Step 9: Repeat
```

---

## Contributing

This is my personal homelab, so contributions are... unexpected? But if you:

1. Found a security issue → Please tell me (nicely)
2. Have a suggestion → Open an issue
3. Want to judge my YAML → Fair enough
4. Know why `useless-app.yaml` exists → Please enlighten me
5. Have better parental control ideas than ARP poisoning → I'm listening

---

## The Real Architecture

```
                    ┌─────────────────────────────────────┐
                    │           My Mental State           │
                    │                                     │
                    │    ┌─────────┐     ┌─────────┐     │
                    │    │ Anxiety │────►│ Coffee  │     │
                    │    └─────────┘     └────┬────┘     │
                    │         ▲               │          │
                    │         │               ▼          │
                    │    ┌────┴────┐    ┌─────────┐     │
                    │    │ 3 AM    │◄───│ Alerts  │     │
                    │    │ Panic   │    └─────────┘     │
                    │    └─────────┘                     │
                    └─────────────────────────────────────┘
```

---

## License

This project is licensed under the **"Works On My Machine"** license.

You're free to:
- Copy this and break your own stuff
- Learn from my mistakes  
- Laugh at my configuration choices
- Question my parenting techniques
- Wonder why anyone needs Chaos Mesh at home

---

<p align="center">
  <i>Powered by caffeine, spite, and 56 Xeon cores that could heat a small apartment.</i>
</p>
