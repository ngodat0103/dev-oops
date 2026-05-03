# Home Lab Infrastructure

> *"Move fast and break things"* -- Mark Zuckerberg
> *"I moved fast. Things are broken."* -- Me, at 3 AM

Private infrastructure repository managing a single-node Proxmox environment that somehow runs production services, a Kubernetes cluster held together by optimism, and more YAML than any human should write in one lifetime.

**Domain:** `datrollout.dev`

---

## Table of Contents

- [Architecture Overview](#architecture-overview)
- [Hardware](#hardware)
- [Network Topology](#network-topology)
- [Compute Inventory](#compute-inventory)
- [Platform Tooling](#platform-tooling)
- [Deployed Services](#deployed-services)
- [The Kubernetes Situation](#the-kubernetes-situation)
- [Storage Architecture](#storage-architecture)
- [Security](#security)
- [Observability](#observability)
- [Backup and Disaster Recovery](#backup-and-disaster-recovery)
- [CI/CD](#cicd)
- [Repository Structure](#repository-structure)
- [Getting Started](#getting-started)

---

## Architecture Overview

The infrastructure follows a hybrid model in active transition: services are being migrated from Docker on ubuntu-server to Kubernetes, starting with internal tools. Kubernetes is no longer just a lab — it is increasingly the primary runtime, while Docker remains the fallback for anything not yet migrated.

```
                         Internet
                            |
                      "please be gentle"
                            |
                            v
                  +-------------------+
                  |    Cloudflare     |
                  | DNS / WAF / Proxy |
                  |  "the bodyguard"  |
                  +---------+---------+
                            |
                            v
+---------------------------------------------------------------+
|                   Proxmox VE (pve-master)                     |
|                     192.168.1.120                              |
|              One node to rule them all.                        |
|                                                                |
|  PRODUCTION (the stuff that must not go down)                  |
|  +---------------------------+  +---------------------------+  |
|  | ubuntu-server  .1.121     |  | sonarqube      .1.125     |  |
|  | Traefik, Docker services  |  | "yes I lint my homelab"   |  |
|  | Monitoring stack          |  |                           |  |
|  | (the workhorse)           |  |                           |  |
|  +---------------------------+  +---------------------------+  |
|  +---------------------------+  +---------------------------+  |
|  | vpn-server     .1.123     |  | teleport       .1.122     |  |
|  | OpenVPN + OTP             |  | Zero-Trust Access         |  |
|  +---------------------------+  +---------------------------+  |
|                                                                |
|  Production LXC                                                |
|  +---------------------------+  +---------------------------+  |
|  | postgresql-16  .99.2      |  | crowdsec       .1.127     |  |
|  | The elephant in the room  |  | "you shall not pass"      |  |
|  +---------------------------+  +---------------------------+  |
|                                                                |
|  Kubernetes Cluster (PRODUCTION — migration in progress)      |
|  +----------------------------------------------------------+ |
|  | Masters: .1.180-.182 (x3)  Workers: .1.190-.193 (x4)     | |
|  | 10 vCPU / 10 GB RAM / 250 GB disk per worker (production) | |
|  | ArgoCD, Traefik, MetalLB, OpenEBS, CloudNative-PG,       | |
|  | Velero, kube-prometheus-stack, Loki, Alloy,              | |
|  | qBittorrent, Jellyfin, Agent DVR, Vaultwarden, Nextcloud | |
||  |                                                            | |
|  | "One day this will replace everything above.               | |
|  |  That day has started. And it's tagged production."       | |
|  +----------------------------------------------------------+ |
+---------------------------------------------------------------+
```

Traffic flow for public-facing services:

```
Client -> Cloudflare (proxy/WAF) -> Traefik (reverse proxy) -> CrowdSec (middleware) -> Service
                                                                     |
                                                              "papers, please"
```

---

## Hardware

One server. Everything runs on one server. Yes, the "cluster" too. No, it's not HA. Yes, I know.

| Component      | Specification                          | Notes                              |
|----------------|----------------------------------------|------------------------------------|
| CPU            | 2x Intel Xeon E5-2680 v4 (56 threads) | Slightly aged but still kicking    |
| Memory         | 62 GB DDR4                             | Enough for K8s. Barely.            |
| Boot/VM disk   | 1.8 TB NVMe                            | The fast one. VMs live here.       |
| Data (HDD)     | 465 GB + 931 GB SATA                   | Spinning rust from a previous era  |
| Hypervisor     | Proxmox VE                             | The backbone of this operation     |
| Electricity    | Yes                                    | I don't talk about this           |

---

## Network Topology

| Network              | Subnet             | Purpose                              |
|----------------------|---------------------|--------------------------------------|
| LAN                  | 192.168.1.0/24     | Primary network for all VMs and LXCs |
| Private              | 192.168.99.0/24    | Isolated network for stateful services -- cannot be reached from the outside, which is the whole point |
| Docker internal      | 192.168.30.0/24    | Bridge network for Docker containers on ubuntu-server |
| MetalLB pool         | 192.168.1.230-240  | Kubernetes LoadBalancer IP range     |

DNS is managed via Cloudflare and Terraform.
**Public DNS (proxied CNAME via Cloudflare):**

| Record                          | Type  | Proxied | Target        |
|---------------------------------|-------|---------|---------------|
| gitlab.datrollout.dev           | CNAME | Yes     | DDNS endpoint |
| bitwarden.datrollout.dev        | CNAME | Yes     | DDNS endpoint |
| sonarqube.datrollout.dev        | CNAME | Yes     | DDNS endpoint |
| loki.datrollout.dev             | CNAME | Yes     | DDNS endpoint |
| prometheus.datrollout.dev       | CNAME | Yes     | DDNS endpoint |
| grafana.datrollout.dev          | CNAME | Yes     | DDNS endpoint |

**Direct-to-Traefik DNS (unproxied A records pointing to K8s Traefik at `192.168.1.232`):**

| Record                          | Type | Proxied | Target          |
|---------------------------------|------|---------|-----------------|
| nextcloud.datrollout.dev        | A    | No      | 192.168.1.232   |
| jellyfin.datrollout.dev         | A    | No      | 192.168.1.232   |
| core-harbor.datrollout.dev      | A    | No      | 192.168.1.232   |
| kafka-ui.datrollout.dev         | A    | No      | 192.168.1.232   |
| pgadmin4.datrollout.dev         | A    | No      | 192.168.1.232   |
| argocd.datrollout.dev           | A    | No      | 192.168.1.232   |
| qbittorrent.datrollout.dev      | A    | No      | 192.168.1.232   |

Direct records resolve to the Kubernetes Traefik ingress (via MetalLB). Media-heavy services such as Nextcloud and Jellyfin stay DNS-only to avoid Cloudflare media bandwidth limits and are protected at Traefik with CrowdSec.

---

## Compute Inventory

### Virtual Machines

| Host           | IP             | OS           | vCPU | RAM   | Role                                 |
|----------------|----------------|--------------|------|-------|--------------------------------------|
| pve-master     | 192.168.1.120  | Proxmox VE   | --   | --    | Hypervisor (the boss)                |
| ubuntu-server  | 192.168.1.121  | Ubuntu 22.04 | 4    | 16 GB | Docker host, Traefik, monitoring (the workhorse) |
| teleport       | 192.168.1.122  | --           | --   | --    | Zero-trust access proxy              |
| vpn-server     | 192.168.1.123  | Debian 13    | 1    | 2 GB  | OpenVPN with OTP (for remote chaos)  |
| sonarqube      | 192.168.1.125  | Ubuntu 22.04 | 4    | 8 GB  | SonarQube -- yes, I run static analysis on my homelab code |

### LXC Containers

| Host                    | IP             | OS           | vCPU | RAM  | Role                      |
|-------------------------|----------------|--------------|------|------|---------------------------|
| postgresql-16           | 192.168.99.2   | Ubuntu 22.04 | 1    | 2 GB | PostgreSQL 16 (production)|
| crowdsec-detection      | 192.168.1.127  | Ubuntu 22.04 | 1    | 1 GB | CrowdSec LAPI + AppSec   |

### Kubernetes Cluster (Production)

Deployed via Kubespray and managed by ArgoCD app-of-apps. The repository currently includes a local Kubespray inventory under `ansible/kubernetes/kubespray/inventory/local/hosts.ini`; actual production node sizing/count may differ from this local inventory snapshot. See [The Kubernetes Situation](#the-kubernetes-situation) for migration status.

| Role    | Count | IP Range            | vCPU | RAM   | Disk   |
|---------|-------|---------------------|------|-------|--------|
| Master  | 3     | 192.168.1.180-182   | 2    | 4 GB  | 50 GB  |
| Worker  | 4     | 192.168.1.190-193   | 10   | 10 GB | 250 GB |

---

## Platform Tooling

### Terraform

All infrastructure provisioning is managed through Terraform with reusable modules from a separate [terraform-module](https://github.com/ngodat0103/terraform-module) repository. Because copy-pasting HCL blocks is for people who haven't been hurt enough yet.

| Configuration           | Provider                  | Purpose                                       |
|-------------------------|---------------------------|-----------------------------------------------|
| `tf/proxmox`            | bpg/proxmox 0.92.0       | VMs, LXCs, networks, cloud-init images        |
| `tf/cloudflare/dns`     | cloudflare/cloudflare ~5  | DNS records, WAF firewall rules               |
| `tf/cloudflare/storage` | cloudflare/cloudflare     | R2 object storage (Velero backend)            |
| `tf/uptimerobot`        | vexxhost/uptimerobot      | External uptime monitoring (the 3 AM alarm)   |

### Ansible

Server configuration and application deployment for all non-Kubernetes workloads. The production stuff. The things that actually matter.

| Playbook Area                | Purpose                                               |
|------------------------------|-------------------------------------------------------|
| `ansible/core/ubuntu-server` | Docker host setup, app deployment, monitoring, cron   |
| `ansible/core/teleport`      | Teleport access proxy installation                    |
| `ansible/core/vpn-server`    | OpenVPN server with OTP                               |
| `ansible/core/lxc`           | PostgreSQL and Kafka configuration                    |
| `ansible/sonarqube`          | SonarQube installation                                |
| `ansible/kubernetes`          | Kubespray inventory and cluster configuration         |

### ArgoCD (Kubernetes)

GitOps deployment uses an app-of-apps chart at `kubernetes/argocd/app-of-app`. Feature toggles in `values.yaml` are the source of truth for what is active.

**Enabled apps right now (`values.yaml`):**
- `metallb`, `traefik`, `openebs`, `postgresql`, `velero`, `kubePrometheusStack`
- `customManifest`, `loki`, `alloy`, `pgadmin4`, `sonarqube`
- `juicefs`, `vaultwarden`, `nextcloud`, `certManager`, `nfsCsiDriver`
- `qbittorrent`, `jellyfin`, `agentDvr`

**Disabled right now:**
- `mongoOperator`, `kafkaOperator`, `harbor`, `redis`

---

## Deployed Services

### Production (Docker on ubuntu-server)

Services still on Docker. GitLab migration is pending / possibly aborted due to complexity.

| Service       | Purpose                  | Exposed Domain              | Status        |
|---------------|--------------------------|-----------------------------|---------------|
| GitLab        | Source control and CI/CD | gitlab.datrollout.dev       | Docker (migration pending/aborted) |
| Vaultwarden   | Password management      | bitwarden.datrollout.dev    | **Migrated → K8s** |
| Nextcloud     | File synchronization     | nextcloud.datrollout.dev    | **Migrated → K8s** |
| Jellyfin      | Media server             | jellyfin.datrollout.dev     | **Migrated → K8s** |
| qBittorrent   | Torrent client           | qbittorrent.datrollout.dev  | **Migrated → K8s** |
| Agent DVR     | Camera/NVR               | `http://<metallb-ip>:8090`  | **Migrated → K8s** |

Agent DVR currently uses a direct Kubernetes `LoadBalancer` service (not Traefik ingress) and exposes:
- Web UI: `8090/TCP`
- TURN: `3478/TCP`, `3478/UDP`
- TURN relay: `50000-50100/UDP`

### Production (Standalone)

| Service       | Host             | Purpose                           |
|---------------|------------------|-----------------------------------|
| PostgreSQL 16 | 192.168.99.2     | Primary relational database       |
| CrowdSec      | 192.168.1.127    | Web application firewall / IDS    |
| SonarQube     | 192.168.1.125    | Static code analysis              |
| Teleport      | 192.168.1.122    | Zero-trust infrastructure access  |
| OpenVPN       | 192.168.1.123    | Remote VPN access with OTP        |

### Kubernetes Cluster (Production GitOps)

The cluster runtime is production-oriented, with staged migration from Docker workloads. Current app-of-app managed services:

| Application Group       | Active Components |
|-------------------------|-------------------|
| Ingress / L4 networking | Traefik, MetalLB |
| Platform / storage      | OpenEBS, JuiceFS, NFS CSI Driver, Velero |
| Observability           | kube-prometheus-stack, Loki, Alloy |
| Data / app platform     | CloudNative-PG, cert-manager, pgadmin4 |
| User services           | Vaultwarden, Nextcloud, SonarQube, qBittorrent, Jellyfin, Agent DVR |
| Misc                    | custom-manifest |

ArgoCD and chart versions evolve over time; use `kubernetes/argocd/app-of-app/templates/*.yaml` and app-specific values files as the canonical source for current revisions.

CloudNative-PG manages databases for: `nextcloud`, `gitlabhq_production`, `vaultwarden`.

---

## The Kubernetes Situation

The migration has started. Here is the honest state of affairs.

The Kubernetes cluster started as a **dev and exploration environment** and has been promoted to `production`. Production ran on Docker + Ansible on ubuntu-server because it worked and I slept at night. That model is now actively being dismantled.

Every service on the Docker side requires writing Ansible playbooks, Docker Compose files, systemd units, Traefik labels, Prometheus scrape configs, backup cron jobs, and update procedures — **per service, by hand, every single time**. It's the YAML equivalent of digging a ditch with a spoon. Kubernetes solves this: define it once, let ArgoCD sync it, let the platform handle scheduling, networking, storage, secrets, and rollbacks. The app-of-apps pattern already proves the point — enabling a full service stack is a boolean flip in `values.yaml`.

**Migration strategy: internal tools first.**

Internal-facing services (no public exposure, no user-facing SLA) are migrated first to build confidence in the cluster before touching anything critical.

| Wave | Services | Status |
|------|----------|--------|
| 1 — Internal tools | qBittorrent, Jellyfin, Agent DVR | **Done** |
| 2 — Self-hosted productivity | Nextcloud, Vaultwarden | **Done** |
| 3 — Critical infrastructure | GitLab | Pending / Aborted |

**Storage approach for migrated services:**
- Config / state (selected apps) → JuiceFS backed by Cloudflare R2
- Media / large data → static NFS PV/PVC on `ubuntu-server` exports
- Database state → OpenEBS local PV (CloudNative-PG)
- Ephemeral cache/temp → `emptyDir` where appropriate

**The plan:**

1. ~~Keep exploring and stabilizing the K8s environment~~ — done, it runs workloads
2. ~~Prove it can run workloads reliably~~ — qBittorrent and Jellyfin are live
3. ~~Continue migrating internal tools wave by wave~~ — Nextcloud and Vaultwarden are live
4. When budget allows, build a proper multi-node cluster with dedicated hardware
5. Eventually decommission ubuntu-server as a Docker host entirely

The cluster now runs production workloads.

---

## Storage Architecture

Three storage tiers are in use — cloud object storage for durable config/state, local NFS for bulk media, and ephemeral node-local storage for throwaway cache.

### Overall Storage Topology

```mermaid
flowchart TD
    subgraph cloud [Cloud]
        R2["Cloudflare R2\n(Object Storage)"]
    end

    subgraph ubuntu_server ["ubuntu-server (192.168.1.121)"]
        data1["/mnt/data1\n465 GB HDD"]
        data2["/mnt/data2\n931 GB HDD"]
        nfs_export["NFS Export\n/mnt"]
        data1 --> nfs_export
        data2 --> nfs_export
    end

    subgraph k8s ["Kubernetes Cluster"]
        subgraph storage_layer ["Storage Layer"]
            juicefs["JuiceFS CSI Driver\njuicefs-sc-cloudflare-r2"]
            nfs_csi["NFS CSI Driver\nnfs-csi-driver-nfs"]
            openebs["OpenEBS\nlocalpv-provisioner"]
            emptydir["emptyDir\n(ephemeral)"]
        end

        subgraph workloads ["Workloads"]
            jellyfin["Jellyfin"]
            qbittorrent["qBittorrent"]
            vaultwarden["Vaultwarden"]
            nextcloud["Nextcloud"]
            redis_ui["Redis UI"]
            cnpg["CloudNative-PG"]
            agentdvr["Agent DVR"]
        end
    end

    R2 <-->|"S3 API"| juicefs
    nfs_export -->|"NFS mount"| nfs_csi

    juicefs -->|"config PVC"| jellyfin
    juicefs -->|"config PVC"| qbittorrent
    juicefs -->|"config PVC"| vaultwarden
    juicefs -->|"config PVC"| nextcloud
    juicefs -->|"config PVC"| redis_ui

    nfs_csi -->|"media PVC\n(read-only subPath)"| jellyfin
    nfs_csi -->|"downloads PVC\n(read-write)"| qbittorrent

    openebs -->|"data PVC"| cnpg
    nfs_csi -->|"data PVC + Commands subPath"| agentdvr
    emptydir -->|"cache volume"| jellyfin
```

### Per-Workload Storage Mapping

```mermaid
flowchart LR
    subgraph jellyfin_vol ["Jellyfin Volumes"]
        jcfg["/config\nJuiceFS PVC\njellyfin-config-pvc"]
        jcache["/cache\nemptyDir"]
        jdata1["/data1\nNFS subPath\ndata2/jellyfin\nread-only"]
        jdata2["/data2\nNFS subPath\ndata1/NFS/jellyfin\nread-only"]
    end

    subgraph qbt_vol ["qBittorrent Volumes"]
        qcfg["/config\nJuiceFS PVC\nqbittorrent-config-pvc"]
        qdata1["/mnt/data1\nNFS PV\nqbittorrent-data1-pv"]
        qdata2["/mnt/data2\nNFS PV\nqbittorrent-data2-pv"]
    end

    subgraph nfs_disks ["NFS (192.168.1.121:/mnt)"]
        disk1["data1/\n465 GB HDD"]
        disk2["data2/\n931 GB HDD"]
    end

    subgraph juicefs_backend ["JuiceFS → Cloudflare R2"]
        r2["R2 Bucket\njuicefs-prod"]
    end

    jcfg --> r2
    qcfg --> r2

    jdata1 -->|"subPath: data2/jellyfin"| disk2
    jdata2 -->|"subPath: data1/NFS/jellyfin"| disk1
    qdata1 --> disk1
    qdata2 --> disk2
```

### Storage Tier Summary

| Tier | Technology | Backend | Use Case | Durability |
|------|-----------|---------|----------|------------|
| Cloud-backed config | JuiceFS CSI | Cloudflare R2 | App config, state | Survives node/disk loss |
| Local NFS | NFS CSI Driver | ubuntu-server `/mnt` | Media files, torrent downloads | Single-host (NAS) |
| Ephemeral | `emptyDir` | Node disk | Transcoding cache | Lost on pod restart |
| Local block | OpenEBS localpv | Worker node disk | PostgreSQL data | Single-node |

---

## Security

Traffic goes through multiple layers before it reaches anything useful. I'd rather explain downtime than a breach.

### Edge Protection (Cloudflare)

- All public traffic is proxied through Cloudflare
- Geo-blocking: only traffic originating from Vietnam is permitted (sorry, rest of the world)
- UptimeRobot health check IPs are explicitly whitelisted
- Vaultwarden `/admin` endpoint is blocked at the edge, because even I don't trust myself with that URL exposed

### Reverse Proxy (Traefik v3)

- TLS termination via Let's Encrypt using Cloudflare DNS-01 challenge
- All requests pass through CrowdSec bouncer middleware -- every single one
- Real client IPs extracted from `CF-Connecting-IP` header
- Prometheus metrics and structured access logging enabled

### Kubernetes Internal Ingress Policy

Internal-only applications in the Kubernetes lab stay behind Traefik and are restricted with an IP allowlist middleware.

- Internal-only apps: `sonarqube`, `juicefs`, `grafana`, `alertmanager`, `pgadmin4`, `chaos-mesh`
- Harbor follows the same policy when enabled
- Required ingress annotations for internal apps:
  - `traefik.ingress.kubernetes.io/router.entrypoints: "websecure"`
  - `traefik.ingress.kubernetes.io/router.middlewares: "traefik-allow-local-ip-only@kubernetescrd"`
- Allowed LAN/VPN CIDRs are managed in:
  - `kubernetes/argocd/argocd-app/stateless/traefik/middlewares/allow-local-ip-only.yaml`
- Public apps must not use the local-only middleware

### Intrusion Detection (CrowdSec)

- LAPI running on port 8080, AppSec engine on port 7422
- Detection scenarios: HTTP path traversal, XSS probing, generic brute force
- Operating mode: live (real-time blocking, not just logging and hoping)
- Failure behavior: **block all traffic** if CrowdSec becomes unreachable

```yaml
crowdsecAppsecUnreachableBlock: true
crowdsecAppsecFailureBlock: true
# Translation: "I'd rather the site be down than compromised"
```

### Access Management

| Tool       | Purpose                                        |
|------------|------------------------------------------------|
| Teleport   | Zero-trust access to SSH and internal services |
| OpenVPN    | Remote network access with OTP                 |

### Secret Management

| Method          | Scope                                  |
|-----------------|----------------------------------------|
| Ansible Vault   | Infrastructure credentials             |
| Kubernetes Secrets / Helm values | In-cluster app secrets and runtime configuration |

---

## Observability

Everything emits metrics or logs. If it doesn't, it gets added until it does.

### Metrics (Prometheus + Grafana)

`kube-prometheus-stack` is the backbone. It scrapes nodes, pods, Traefik, CloudNative-PG, ArgoCD, and other workloads exposing `/metrics`.

| Component              | Scrape Target                    | Notes                                    |
|------------------------|----------------------------------|------------------------------------------|
| Node metrics           | `node-exporter` on every worker  | CPU, memory, disk, network               |
| Kubernetes API         | kube-state-metrics               | Deployments, pods, PVCs, events          |
| Traefik                | Traefik `/metrics`               | Request rates, latency, error codes      |
| CloudNative-PG         | CNPG exporter per pod            | Replication lag, WAL archiving status    |
| ArgoCD                 | ArgoCD metrics service           | Sync status, health state                |
| Loki / Alloy           | Loki + Alloy pipeline metrics    | Log ingestion and backend health         |

Grafana is exposed internally at `grafana.datrollout.dev` via Traefik.

### Logs (Loki + Alloy)

Grafana Alloy runs as a DaemonSet and ships all pod logs to Loki. Loki is deployed in-cluster and accessible through Grafana's Explore panel.

### Alerting

Alertmanager is deployed alongside Prometheus. Alerts are routed to a Telegram bot for anything that warrants a notification at 3 AM.

---

## Backup and Disaster Recovery

### PostgreSQL

PostgreSQL (CloudNative-PG) is the most critical stateful service. The entire backup strategy is built around continuous WAL archiving to Cloudflare R2 via the Barman Cloud plugin.

| What | How | Where |
|------|-----|-------|
| Base backups | `ScheduledBackup` CRD, daily at 02:00 UTC | `s3://cnpg-postgresql/postgresql/base/` |
| WAL archiving | Continuous via Barman Cloud plugin | `s3://cnpg-postgresql/postgresql/wals/` |
| Retention | 7 days | Configurable via `retentionPolicy` |
| RPO | < 5 minutes | WAL archiving interval |
| RTO | < 30 minutes | Full cluster restore from R2 |

Full restore procedure, known issues, and PITR instructions: [`disaster-recovery/postgresql/readme.md`](disaster-recovery/postgresql/readme.md)

### Vaultwarden

Vaultwarden data is backed up via a scheduled script. Restore scripts and instructions are in [`disaster-recovery/vaultwarden/`](disaster-recovery/vaultwarden/).

---

## CI/CD

### GitHub Actions

| Workflow | Trigger | Purpose |
|----------|---------|---------|
| `postgresql-backup-test.yml` | Cron: 1st & 15th at 03:00 UTC + manual | End-to-end PostgreSQL backup verification on an ephemeral DOKS cluster |

**PostgreSQL Backup Verification** (`postgresql-backup-test.yml`):

Spins up a throwaway DigitalOcean Kubernetes cluster, deploys the full PostgreSQL stack via ArgoCD at the pinned recovery tag, waits for the CloudNative-PG cluster to reach healthy state, then validates that expected databases and tables are present. The destroy step deletes the cluster first, then cleans up orphaned block storage volumes (by `k8s:<cluster-id>` CSI tag) and load balancers (by IP + tag).

This runs automatically twice a month. If it fails, the backup is broken.

### GitLab CI

~~Application-level CI pipelines ran on the self-hosted GitLab/GitHub runner on `hephaestus` (192.168.1.124).~~ The `hephaestus` VM was decommissioned on April 27, 2026. CI now runs exclusively on GitHub-hosted runners (`ubuntu-latest`). SonarQube analysis continues to run on the standalone SonarQube VM (192.168.1.125).

---

## Repository Structure

```
.
├── .github/
│   └── workflows/
│       └── postgresql-backup-test.yml # Automated backup verification (runs 1st & 15th)
│
├── ansible/
│   ├── core/                          # Production server configuration (the real stuff)
│   │   ├── inventory.ini              # Ansible inventory (all hosts)
│   │   ├── ubuntu-server/             # Docker host: apps, basic setup, monitoring, cron
│   │   ├── teleport/                  # Zero-trust access proxy
│   │   ├── vpn-server/                # OpenVPN configuration
│   │   └── lxc/                       # LXC workloads (PostgreSQL, Kafka)
│   ├── kubernetes/                    # Kubespray inventory and configuration
│   ├── sonarqube/                     # SonarQube installation playbook
│   └── proxmox/                       # Proxmox host configuration
│
├── kubernetes/                        # Kubernetes cluster workloads
│   ├── argocd/
│   │   ├── argocd-crd/                # ArgoCD installation (Helm)
│   │   ├── app-of-app/                # App-of-apps Helm chart (values.yaml toggles)
│   │   └── argocd-app/                # Per-application ArgoCD manifests and values
│   │       ├── daemon/                # Cluster daemons (MetalLB and related manifests)
│   │       ├── stateful/              # Stateful apps (postgresql, qbittorrent, jellyfin, agent-dvr, ...)
│   │       └── stateless/             # Stateless apps (traefik, vaultwarden, metric-server, ...)
│   └── charts/                        # Custom Helm charts (Kafka operator, Mongo operator)
│
├── tf/
│   ├── proxmox/                       # VM/LXC provisioning, network, cloud-init
│   ├── cloudflare/
│   │   ├── dns/                       # DNS records and WAF firewall rules
│   │   └── storage/                   # R2 bucket for Velero
│   ├── uptimerobot/                   # External uptime monitors
│   └── terraform-module/              # Shared Terraform modules (submodule)
│
├── disaster-recovery/
│   ├── postgresql/                    # PostgreSQL DR plan, restore procedure, CI docs
│   └── vaultwarden/                   # Vaultwarden backup and restore scripts
│
└── plans/                             # Architecture decision records and future plans
```
---

*Powered by caffeine, spite, and 56 Xeon threads that could heat a small apartment.*
