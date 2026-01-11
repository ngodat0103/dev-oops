### 1. Architecture Decision Record (ADR)

**Title:** Homelab Sentry: Side-Arm Traffic Inspection via ARP Spoofing
**Status:** Accepted
**Date:** January 11, 2026
**Context:** Proxmox Homelab Environment (Arch Linux)

#### Context

The user requires a system to inspect, block, or redirect network traffic for specific devices (e.g., children's tablets, IoT devices) based on MAC addresses and time schedules.

* **Constraint 1 (Stability):** The solution must **not** act as the primary physical gateway/router. If the Proxmox server restarts or the code crashes, the home internet must remain functional for other users (Fail-Open preferred, or Quick-Recovery).
* **Constraint 2 (Hardware):** No new hardware purchases. Must use existing TP-Link router and Proxmox server.

#### Decision

We will implement a **"Side-Arm" (Man-in-the-Middle)** architecture using **ARP Cache Poisoning** (Unicast).

* **Mechanism:** A Go-based agent running on an Arch Linux VM will "claim" the IP of the router to the target device, and the IP of the target device to the router.
* **Traffic Flow:** `Target Device` -> `Sentry VM (Go)` -> `Real Router` -> `Internet`.
* **Safety Protocol:** The system will strictly use **Unicast ARP packets** (targeting specific MACs) to avoid flooding the network or affecting non-target devices.
* **Recovery:** The agent will implement a "Graceful Shutdown" signal that floods the network with correct ARP mappings upon exit to instantly restore normal routing.

#### Consequences

* **Positive:** Zero physical rewiring required. High granularity (per-device control). "Fail-Safe" (network self-heals in ~60s if the agent dies).
* **Negative:** Adds a network hop (slight latency increase). High CPU usage on the VM if the target consumes high bandwidth (e.g., 4K streaming).
* **Risks:** Potential for IP conflicts if the code accidentally broadcasts ARP packets.

---

### 2. High-Level Architecture

The system operates on the "Triangle" principle. Instead of traffic flowing in a straight line, we force it to detour through your Sentry VM.

**The Three Components:**

1. **The Spoofer (Go Routine):**
* Continuously whispers to the **Target**: *"I am the Router."*
* Continuously whispers to the **Router**: *"I am the Target."*


2. **The Forwarder (Packet Engine):**
* Receives the stolen packets.
* **Policy Check:** Is it 1 AM? Does the packet contain forbidden keywords?
* **Action:** If Allowed -> Rewrite MAC destination -> Send to Real Router. If Blocked -> Drop.


3. **The Controller (Telegram Bot):**
* Listens for alerts from the Forwarder.
* Accepts commands (e.g., `/allow 1h`) to update the Policy Engine dynamically.



---

### 3. Implementation Plan (Step-by-Step)

#### Phase 1: Reconnaissance (Discovery)

*Goal: Identify the actors on your network.*

1. **Map the Network:** Run `sudo arp-scan --localnet` or `ip neighbor` on your Arch VM.
2. **Lock Targets:** Record the MAC addresses of:
* **The Victim:** (e.g., The iPad) `AA:BB:CC:DD:EE:FF`
* **The Gateway:** (The TP-Link) `11:22:33:44:55:66`
* **The Sentry:** (Your VM) `DE:AD:BE:EF:00:01`


3. **Environment Check:** Ensure `sysctl net.ipv4.ip_forward` is set to `0` (Disabled). *We want our Go code to handle forwarding, not the Linux Kernel, to ensure we can block packets logicially.*

#### Phase 2: The "Sentry" Core (Go Development)

*Goal: Build the packet interceptor.*

1. **Setup Project:** Initialize a new Go module `go mod init homelab-sentry`.
2. **Dependencies:** `go get github.com/google/gopacket`.
3. **Develop Spoofer:** Implement the `spoofLoop` function (from the code provided earlier). **Crucial:** Verify it uses `DstMAC` (Unicast) and NOT Broadcast.
4. **Develop Forwarder:** Implement the packet reading loop. Initially, just forward *everything* to verify connectivity works.
* *Test:* Run the Sentry -> Check if Target can browse the web.



#### Phase 3: The Logic Engine (DLP & Rules)

*Goal: Add intelligence to the forwarding.*

1. **Time Policy:** Add a check `if time.Now().Hour() >= 1` inside the packet loop.
2. **DNS Sinkholing (Optional):** Detect UDP traffic on Port 53. If blocked, replace the DNS Response IP with your Sentry IP (to show a block page).
3. **Payload Inspection (DLP):** Convert the Application Layer payload to string and check for keywords (Note: Only works on HTTP/Unencrypted traffic).

#### Phase 4: Operations & Safety

*Goal: Ensure WAF (Wife Acceptance Factor).*

1. **Watchdog:** Implement the `signal.Notify` (Ctrl+C) handler to run the `cleanUp()` function.
2. **Deployment:** Create a `systemd` service file for your app so it starts automatically with the VM.
* *Draft Service File:*
```ini
[Unit]
Description=Homelab Sentry DLP
After=network.target

[Service]
ExecStart=/usr/local/bin/homelab-sentry
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target

```