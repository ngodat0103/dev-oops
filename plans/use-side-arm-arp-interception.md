## ADR-001: Network Traffic Interception & Access Control Strategy

**Status:** Accepted
**Date:** February 10, 2026
**Project:** Homelab Sentry ("The Over-Engineered Nanny")

### 1. Context

The objective is to implement time-based internet access restrictions (e.g., "1 AM Curfew") for specific client devices (iPad, Android) on a shared residential LAN.

**Constraints:**

* **Hardware:** Proxmox VE environment (x86_64).
* **Network:** Standard consumer router; no enterprise VLAN/Radius support.
* **Target Devices:** Unmanaged mobile devices (iOS/Android) with no ability to install root CAs.
* **User Experience:** Prioritize effective blocking for HTTPS apps (YouTube, TikTok) while attempting to display a blocking page via captive portal triggers.
* **Risk:** System failure must not result in a permanent network outage (requires "fail-open" or graceful recovery).

### 2. Decision

A custom **Go-based Man-in-the-Middle (MITM) Controller** will be implemented, running in an LXC container or VM.

The architecture relies on a **Hybrid Interception Strategy**:

1. **Layer 2 (The Hook): ARP Spoofing**
* Uses `github.com/mdlayher/arp` or `google/gopacket` to broadcast unsolicited ARP Replies.
* The Sentry VM claims to be the Gateway (Router) to the Target Device.
* The Sentry VM claims to be the Target Device to the Gateway.
* **Safety Mechanism:** A "Watchdog" goroutine captures `SIGINT/SIGTERM` signals to broadcast correct ARP mappings (healing the network) before process exit.


2. **Layer 4 (The Filter): SNI Peeking**
* No attempt at full TLS termination (decrypting traffic) due to HSTS and Certificate Pinning.
* Inspects the **TLS Client Hello** packet to read the **SNI (Server Name Indication)** extension.
* **Logic:**
* If SNI matches a blocked domain (e.g., `youtube.com`) during curfew: **DROP PACKET**.
* If SNI is allowed: **FORWARD** packet to real Gateway.




3. **Layer 7 (The Notification): Captive Portal Spoofing**
* Spoofs OS connectivity checks to trigger a UI popup.
* **DNS:** Intercepts queries for `captive.apple.com` and `connectivitycheck.gstatic.com`, resolving them to the Sentry VM IP.
* **HTTP:** A lightweight Go HTTP server on Port 80 returns a `302 Redirect` to a local "Bedtime" page for these specific check URLs.



### 3. Consequences

**Positive:**

* **Zero-Touch Client Config:** No need to install profiles or manually configure proxies on the target devices.
* **App-Level Blocking:** SNI inspection effectively blocks modern apps that ignore system proxies.
* **Psychological Impact:** The Captive Portal trick forces a UI popup on network reconnect.

**Negative:**

* **Performance Overhead:** All traffic for the target device must pass through the Sentry VM, adding latency.
* **Fragility:** MAC Randomization on target devices can break the ARP targeting unless disabled for the home SSID.

### 4. Component Diagram (C4 Level 2)

### 5. Action Items

1. **Develop `arp_spoofer.go`:** Implement the "Poison" and "Heal" loop.
2. **Develop `sni_inspector.go`:** Use `gopacket/layers` to parse TLS headers.
3. **Develop `portal_server.go`:** HTTP server for `generate_204` and `hotspot-detect` redirects.
4. **Ops:** Configure Proxmox bridge to allow Promiscuous Mode.

---
