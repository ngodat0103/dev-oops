# JuiceFS + Cloudflare R2 — High Write Diagnosis Report

> **Homelab | Kubernetes | JuiceFS CSI Driver**

---

## Summary

Investigated high `object.put` (Class A) operations on Cloudflare R2 backend used by JuiceFS.
Root cause identified as **Jellyfin writing SQLite WAL flushes and playback metadata** through a JuiceFS mount pod
during active movie playback. Left unresolved, this would exhaust the **1M Class A ops/month free tier**
and incur charges at **$4.50/million ops**.

---

## Diagnosis Methodology

### 1. Identified Active Mount Pods

```bash
kubectl get pods -n kube-system | grep juicefs
```

### 2. Real-Time Stats per Mount Pod

```bash
juicefs stats /jfs/<pv_volumeHandle> --schema o --interval 1
```

Key columns monitored:

| Column | Meaning |
|---|---|
| `object.put` | Upload bandwidth to R2 (Class A ops) |
| `buf` | Write buffer — non-zero means active writes buffered |
| `fuse.ops` | App-level filesystem operations/sec |
| `meta.ops` | Metadata operations/sec |

### 3. Correlated with Cloudflare R2 Dashboard

Spike of **~40 Class A ops** observed at **19:37 GMT+7** on the R2 dashboard, exactly matching
the moment Jellyfin playback started during the investigation session.

---

## Root Cause: Jellyfin SQLite WAL on JuiceFS

Jellyfin stores its database (`library.db`) and playback session state in `/config`.
When `/config` is backed by a JuiceFS PVC, every SQLite WAL flush (every ~10s during playback)
generates a separate `object.put` to R2.

**Observed pattern from `juicefs stats`:**

```
# Before playback — clean
object.put = 0, 0, 0, 0 ...

# During Jellyfin playback (Taylor Swift Eras Tour Movie)
object.put = 28K, 40K, 92K, 136K, 32K, 20K, 1.2K, 188B, 291B ...
             ^^^^  ^^^  ^^^^                    ^^^^^^^^^^^^^^^^
             block flushes                       repeated WAL syncs
buf grows: 0 → 8MB → 62MB → 75MB (stable, continuously flushing)
cpu spikes: 1% → 47-48%
mem grows: 155MB → 275MB
```

### Estimated Class A ops generated

| Scenario | ops/hour | ops/month (2 movies/day) |
|---|---|---|
| Idle | ~5 | ~3,600 |
| Playback without fix | ~600 | **~864,000** ← near free tier limit |
| Playback with `upload-delay=3h` | ~15 | ~21,600 ✅ |

---

## Fix Applied

Added `upload-delay=3h` to JuiceFS mount options in the Jellyfin CSI StorageClass.
This batches all small writes (SQLite WAL, metadata) and flushes to R2 only after a 3-hour delay,
covering the typical duration of a long movie session.

```yaml
# StorageClass or PVC mountOptions
mountOptions:
  - upload-delay=3h
```

### Effect

- SQLite WAL writes are buffered locally in the mount pod's write buffer (`buf`)
- Only flushed to R2 as a single batched `object.put` after the delay
- Reduces Class A ops from ~600/hr → ~15/hr during active playback (~97.5% reduction)

---


## Environment

| Component | Details |
|---|---|
| Kubernetes | kubeadm cluster |
| JuiceFS CSI | community edition |
| Object Storage | Cloudflare R2 (Standard) |
| Affected App | Jellyfin media server |
| Fix | `upload-delay=3h` mount option |
# JuiceFS + Cloudflare R2 — High Write Diagnosis Report

> **Homelab | Kubernetes | JuiceFS CSI Driver**

---

## Summary

Investigated high `object.put` (Class A) operations on Cloudflare R2 backend used by JuiceFS.
Root cause identified as **Jellyfin writing SQLite WAL flushes and playback metadata** through a JuiceFS mount pod
during active movie playback. Left unresolved, this would exhaust the **1M Class A ops/month free tier**
and incur charges at **$4.50/million ops**.

---

## Diagnosis Methodology

### 1. Identified Active Mount Pods

```bash
kubectl get pods -n kube-system | grep juicefs
```

### 2. Real-Time Stats per Mount Pod

```bash
juicefs stats /jfs/<pv_volumeHandle> --schema o --interval 1
```

Key columns monitored:

| Column | Meaning |
|---|---|
| `object.put` | Upload bandwidth to R2 (Class A ops) |
| `buf` | Write buffer — non-zero means active writes buffered |
| `fuse.ops` | App-level filesystem operations/sec |
| `meta.ops` | Metadata operations/sec |

### 3. Correlated with Cloudflare R2 Dashboard

Spike of **~40 Class A ops** observed at **19:37 GMT+7** on the R2 dashboard, exactly matching
the moment Jellyfin playback started during the investigation session.

---

## Root Cause: Jellyfin SQLite WAL on JuiceFS

Jellyfin stores its database (`library.db`) and playback session state in `/config`.
When `/config` is backed by a JuiceFS PVC, every SQLite WAL flush (every ~10s during playback)
generates a separate `object.put` to R2.

**Observed pattern from `juicefs stats`:**

```
# Before playback — clean
object.put = 0, 0, 0, 0 ...

# During Jellyfin playback (Taylor Swift Eras Tour Movie)
object.put = 28K, 40K, 92K, 136K, 32K, 20K, 1.2K, 188B, 291B ...
             ^^^^  ^^^  ^^^^                    ^^^^^^^^^^^^^^^^
             block flushes                       repeated WAL syncs
buf grows: 0 → 8MB → 62MB → 75MB (stable, continuously flushing)
cpu spikes: 1% → 47-48%
mem grows: 155MB → 275MB
```

### Estimated Class A ops generated

| Scenario | ops/hour | ops/month (2 movies/day) |
|---|---|---|
| Idle | ~5 | ~3,600 |
| Playback without fix | ~600 | **~864,000** ← near free tier limit |
| Playback with `upload-delay=3h` | ~15 | ~21,600 ✅ |

---

## Fix Applied

Added `upload-delay=3h` to JuiceFS mount options in the Jellyfin CSI StorageClass.
This batches all small writes (SQLite WAL, metadata) and flushes to R2 only after a 3-hour delay,
covering the typical duration of a long movie session.

```yaml
# StorageClass or PVC mountOptions
mountOptions:
  - upload-delay=3h
```

### Effect

- SQLite WAL writes are buffered locally in the mount pod's write buffer (`buf`)
- Only flushed to R2 as a single batched `object.put` after the delay
- Reduces Class A ops from ~600/hr → ~15/hr during active playback (~97.5% reduction)

---


## Environment

| Component | Details |
|---|---|
| Kubernetes | kubeadm cluster |
| JuiceFS CSI | community edition |
| Object Storage | Cloudflare R2 (Standard) |
| Affected App | Jellyfin media server |
| Fix | `upload-delay=3h` mount option |
