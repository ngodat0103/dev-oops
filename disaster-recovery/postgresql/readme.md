# PostgreSQL Disaster Recovery Plan
> **Stack:** CloudNativePG · Barman Cloud Plugin · Cloudflare R2 · Kubernetes  
> **Last Updated:** April 27, 2026

---

## Table of Contents
1. [Architecture Overview](#1-architecture-overview)
2. [Recovery Objectives](#2-recovery-objectives)
3. [Prerequisites](#3-prerequisites)
4. [Backup Strategy](#4-backup-strategy)
5. [Restore Procedure](#5-restore-procedure)
6. [Known Issues & Workarounds](#6-known-issues--workarounds)
7. [Post-Restore Validation](#7-post-restore-validation)
8. [Re-enable WAL Archiving](#8-re-enable-wal-archiving)
9. [Runbook: Full Cluster Loss](#9-runbook-full-cluster-loss)
10. [Automated Backup Verification (CI)](#10-automated-backup-verification-ci)

---

## 1. Architecture Overview

```
┌─────────────────────────────┐       WAL stream        ┌──────────────────────────┐
│   CloudNativePG Cluster     │ ─────────────────────►  │   Cloudflare R2          │
│                             │                          │                          │
│  Primary (RW)               │   base backup            │  s3://cnpg-postgresql/   │
│  Replica (RO) x1            │ ─────────────────────►  │  └── postgresql/         │
│                             │                          │       ├── base/          │
│  Managed by: ArgoCD         │                          │       └── wals/          │
└─────────────────────────────┘                          └──────────────────────────┘
         │
         ▼
  LoadBalancer Services
  ├── postgresql-externnal-rw  (Primary)
  └── postgresql-externnal-ro  (Replica)
```

**Components:**
- **CloudNativePG operator** manages the PostgreSQL cluster lifecycle, HA failover, and backup scheduling.
- **Barman Cloud plugin** (`barman-cloud.cloudnative-pg.io`) handles WAL archiving and base backups to object storage.
- **Cloudflare R2** stores all base backups and WAL segments. No egress fees.
- **ArgoCD** manages GitOps deployment of the Cluster manifest (sync-wave `"1"`).
- **Kubernetes cluster** (Proxmox, on-prem) — 3 master nodes + 3 worker nodes, tagged `production`. Worker spec: 10 vCPU / 10 GB RAM / 250 GB boot disk.

---

## 2. Recovery Objectives

| Metric | Target |
|--------|--------|
| **RPO** (Recovery Point Objective) | < 5 minutes (WAL archiving interval) |
| **RTO** (Recovery Time Objective) | < 30 minutes for full cluster restore |
| **Backup Retention** | 7 days (configurable via `retentionPolicy`) |
| **Backup Type** | Continuous physical backup + WAL PITR |

---

## 3. Prerequisites

Ensure the following are in place before executing any restore:

```bash
# 1. Verify the ObjectStore resource exists
kubectl get objectstores.barmancloud.cnpg.io -n <namespace>

# 2. Verify the R2 credentials secret exists with correct keys
kubectl get secret cloudflare-r2 -n <namespace> \
  -o jsonpath='{.data}' | jq 'keys'
# Expected: ["ACCESS_KEY", "SECRET_KEY"]

# 3. Verify ArgoCD app is accessible
argocd app get <app-name>

# 4. Confirm the backup folder exists in R2
# Check via Cloudflare R2 dashboard or rclone:
rclone ls r2:cnpg-postgresql/postgresql/base/
```

**Required tools:** `kubectl`, `argocd` CLI, `jq`, Cloudflare R2 dashboard access.

---

## 4. Backup Strategy

### ObjectStore Configuration

```yaml
# yaml-language-server: $schema=https://raw.githubusercontent.com/datreeio/CRDs-catalog/refs/heads/main/barmancloud.cnpg.io/objectstore_v1.json
apiVersion: barmancloud.cnpg.io/v1
kind: ObjectStore
metadata:
  name: cloudflare-r2
spec:
  configuration:
    destinationPath: s3://cnpg-postgresql/
    endpointURL: https://<account-id>.r2.cloudflarestorage.com
    s3Credentials:
      accessKeyId:
        name: cloudflare-r2
        key: ACCESS_KEY
      secretAccessKey:
        name: cloudflare-r2
        key: SECRET_KEY
    wal:
      compression: gzip
```

### Scheduled Base Backups

Base backups are triggered via the `ScheduledBackup` resource:

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: ScheduledBackup
metadata:
  name: postgresql-daily
spec:
  schedule: "0 2 * * *"   # daily at 2AM UTC
  backupOwnerReference: self
  cluster:
    name: postgresql
```

### WAL Archiving

Continuous WAL archiving is enabled via `spec.plugins` in the `Cluster` manifest:

```yaml
plugins:
  - name: barman-cloud.cloudnative-pg.io
    isWALArchiver: true
    parameters:
      barmanObjectName: cloudflare-r2
```

### R2 Folder Structure

```
s3://cnpg-postgresql/
└── postgresql/            ← serverName (matches cluster name)
    ├── base/
    │   └── <backup-id>/   ← base backup snapshots
    └── wals/
        └── 0000000*/      ← WAL segments (compressed with gzip)
```

---

## 5. Restore Procedure

### ⚠️ IMPORTANT — Read Before Restoring

The Barman Cloud plugin runs a pre-flight check (`barman-cloud-check-wal-archive`) that **requires the WAL destination folder to be empty** before it allows a restore to proceed. Since the existing `postgresql/` folder in R2 already contains data, this check will fail with:

```
ERROR: WAL archive check failed for server postgresql: Expected empty archive
```

**Workaround:** Temporarily disable `spec.plugins` (WAL archiver) during the restore. Re-enable it after the cluster is healthy. See [Known Issues](#6-known-issues--workarounds) for full explanation.

---

### Step 1 — Prepare the Recovery Manifest

Ensure `spec.plugins` is **commented out** and `spec.bootstrap.recovery` is configured:

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: postgresql
  annotations:
    argocd.argoproj.io/sync-wave: "1"
spec:
  imageName: ghcr.io/cloudnative-pg/postgresql:16.9

  enableSuperuserAccess: true
  superuserSecret:
    name: postgres-admin

  # ⚠️ STEP 1: Keep plugins COMMENTED OUT during restore
  # plugins:
  #   - name: barman-cloud.cloudnative-pg.io
  #     isWALArchiver: true
  #     parameters:
  #       barmanObjectName: cloudflare-r2

  bootstrap:
    recovery:
      source: origin

  externalClusters:
    - name: origin
      plugin:
        name: barman-cloud.cloudnative-pg.io
        parameters:
          barmanObjectName: cloudflare-r2
          serverName: postgresql     # must match folder name in R2

  instances: 2
  storage:
    size: 30Gi
    storageClass: openebs-hostpath
```

> For **Point-in-Time Recovery (PITR)**, add `recoveryTarget` under `bootstrap.recovery`:
> ```yaml
> bootstrap:
>   recovery:
>     source: origin
>     recoveryTarget:
>       targetTime: "2026-04-10T18:00:00Z"   # ISO 8601 UTC
> ```

### Step 2 — Apply via ArgoCD

```bash
# Sync ArgoCD app with the recovery manifest
argocd app sync <app-name> --force

# Or apply directly
kubectl apply -f cluster.yaml -n <namespace>
```

### Step 3 — Monitor Restore Progress

```bash
# Watch cluster status
kubectl get cluster -n <namespace> postgresql -w

# Follow restore pod logs
kubectl logs -n <namespace> postgresql-1-full-recovery \
  -c plugin-barman-cloud -f

# Check events for errors
kubectl describe cluster -n <namespace> postgresql | tail -30
```

The cluster will cycle through these phases:
```
Setting up primary → Joining replica → Cluster in healthy state ✅
```

---

## 6. Known Issues & Workarounds

### Issue: `Expected empty archive` error during restore

**Error:**
```
ERROR: WAL archive check failed for server postgresql: Expected empty archive
exit status 1
```

**Root Cause:**  
When `spec.plugins` (WAL archiver) and `externalClusters` both point to `s3://cnpg-postgresql/postgresql/`, Barman's pre-flight check sees existing WAL data and refuses to start — it's a safety guard to prevent overwriting a live cluster's WAL stream.

**Workaround (used in this repo):**  
Comment out `spec.plugins` during restore. Re-enable after the cluster reaches healthy state.

**Long-term Fix:**  
Use separate `serverName` values for the WAL write destination vs. the recovery source, so they map to different R2 subfolders:

```yaml
# Writing new WAL → new empty folder
spec.plugins → serverName: postgresql-v2

# Reading backup for recovery → existing folder  
externalClusters → serverName: postgresql
```

---

## 7. Post-Restore Validation

Run these checks after the cluster reaches `Cluster in healthy state`:

```bash
# 1. Check cluster status and instance count
kubectl get cluster -n <namespace> postgresql

# 2. Verify primary and replica pods are Running
kubectl get pods -n <namespace> -l cnpg.io/cluster=postgresql

# 3. Connect and validate data integrity
kubectl exec -it -n <namespace> postgresql-1 -- psql -U postgres -c "\l"
kubectl exec -it -n <namespace> postgresql-1 -- psql -U postgres -c "SELECT count(*) FROM pg_stat_replication;"

# 4. Verify replication lag is near zero
kubectl exec -it -n <namespace> postgresql-1 -- psql -U postgres \
  -c "SELECT application_name, replay_lag FROM pg_stat_replication;"

# 5. Check application connectivity via LoadBalancer
kubectl get svc -n <namespace> | grep postgresql-externnal
```

---

## 8. Re-enable WAL Archiving

Once the cluster is validated as healthy, uncomment `spec.plugins` and re-apply:

```yaml
plugins:
  - name: barman-cloud.cloudnative-pg.io
    isWALArchiver: true
    parameters:
      barmanObjectName: cloudflare-r2
```

```bash
kubectl apply -f cluster.yaml -n <namespace>

# Verify WAL archiving resumed
kubectl get cluster -n <namespace> postgresql \
  -o jsonpath='{.status.conditions}' | jq '.[] | select(.type=="ContinuousArchiving")'
# Expected: "status": "True"
```

---

## 9. Runbook: Full Cluster Loss

> Use this when all PostgreSQL pods are gone or the PVC data is lost.

| Step | Action | Command |
|------|--------|---------|
| 1 | Delete the broken cluster | `kubectl delete cluster -n <namespace> postgresql` |
| 2 | Verify PVCs are deleted | `kubectl get pvc -n <namespace>` |
| 3 | Comment out `spec.plugins` in manifest | Edit `cluster.yaml` |
| 4 | Apply recovery manifest | `kubectl apply -f cluster.yaml` |
| 5 | Monitor restore | `kubectl get cluster -n <namespace> postgresql -w` |
| 6 | Validate data | See [Section 7](#7-post-restore-validation) |
| 7 | Re-enable WAL archiving | Uncomment `spec.plugins`, re-apply |
| 8 | Confirm backup resumes | Check `ContinuousArchiving` condition |
| 9 | Commit clean manifest to Git | `git commit -m "chore: re-enable WAL archiving post-recovery"` |

---

## 10. Automated Backup Verification (CI)

**Workflow file:** `.github/workflows/postgresql-backup-test.yml`  
**Runs on:** GitHub-hosted `ubuntu-latest` (the `hephaestus` self-hosted runner was decommissioned April 27, 2026)

An automated end-to-end backup verification runs on a schedule to prove that the R2 backup is actually restorable without human intervention.

### Schedule

| Trigger | When |
|---------|------|
| Scheduled | 1st and 15th of every month at **03:00 UTC** |
| Manual | `workflow_dispatch` (configurable region, node size, node count) |

### What It Does

```
Provision ephemeral DOKS cluster
        │
        ▼
Deploy ArgoCD + app-of-app (postgresql only)
        │
        ▼
Sync cert-manager → create namespace & secrets (R2 creds, postgres-admin)
        │
        ▼
Override prod-postgresql revision → git tag: postgresql-first-recovery-test
        │
        ▼
Sync PostgreSQL app (ArgoCD) → wait for "Cluster in healthy state"
        │
        ▼
Validate restored data
  ├── connectivity check (SELECT 1)
  ├── list databases (\l)
  ├── assert expected databases exist (sonarqube)
  └── count user tables per database
        │
        ▼
Destroy (always runs)
  ├── 1. Scale all node pools → 0
  ├── 2. Delete DOKS cluster
  ├── 3. Delete block storage volumes  (tagged k8s:<cluster-id> by CSI driver)
  └── 4. Delete load balancers         (by IP + tag fallback)
```

### Required GitHub Secrets

| Secret | Description |
|--------|-------------|
| `DIGITALOCEAN_TOKEN` | DigitalOcean API token (DOKS + volumes + LBs) |
| `R2_ACCESS_KEY` | Cloudflare R2 access key |
| `R2_SECRET_KEY` | Cloudflare R2 secret key |

Configure these under **Settings → Environments → test-backup**.

### Destroy Order

The teardown step runs with `if: always()` to guarantee cleanup even on failure. Resources are removed in this order to avoid dependency conflicts:

1. **Scale node pools to 0** — gracefully evicts all pods before cluster deletion
2. **Delete DOKS cluster** — removes control plane and all nodes
3. **Delete block storage volumes** — the CSI driver tags each PVC-backed volume with `k8s:<cluster-id>`; `doctl` filters by this tag
4. **Delete load balancers** — matched first by the external IPs collected from `kubectl get svc` (before the cluster was deleted), then by `k8s:<cluster-id>` tag as a fallback

### Triggering Manually

```bash
gh workflow run postgresql-backup-test.yml \
  --field region=nyc3 \
  --field node_size=s-4vcpu-8gb \
  --field node_count=2
```