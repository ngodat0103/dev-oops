# Lessons Learned — Upgrading Homelab K8s with Kubespray

A postmortem of the ArgoCD / Traefik / MetalLB conflicts hit during the Kubespray
cluster upgrade. Written to avoid repeating the same whack-a-mole next time.

---

## Incident Record

| Field | Value |
|---|---|
| **Affected service (monitored)** | Nextcloud |
| **Checked URL** | `https://nextcloud.datrollout.dev/index.php/login` |
| **Root cause (monitor)** | Connection Timeout |
| **Underlying root cause** | Kubespray addon ownership conflict (see below) — ArgoCD, Traefik, and MetalLB duplicated/fighting, breaking ingress + GitOps reconciliation |
| **Also impacted** | qBittorrent + Jellyfin (PVCs cascade-deleted via ArgoCD finalizer; recovered). PostgreSQL/CNPG narrowly unaffected. |
| **Started** | 2026-06-21 17:32:00 |
| **Resolved** | 2026-06-21 18:50:20 |
| **Duration** | 1h 18m |
| **Monitor location** | Ashburn, USA — IP 178.156.185.231 |

**Blast radius:** This wasn't just Nextcloud. The upgrade-induced conflicts hit core
platform components — **ArgoCD** (the GitOps control plane itself, CrashLooping from
duplicate Kubespray-managed pods), **Traefik** (ingress, which is why Nextcloud
returned connection timeouts externally), and **MetalLB** (LoadBalancer IP assignment,
speakers stuck `Pending` on host-port collisions). With ingress and the LB layer
degraded, externally-monitored services like Nextcloud went dark even though their own
pods may have been healthy.

This is the practical cost of the config drift: ~1h18m of downtime on family-facing
services (Nextcloud, Vaultwarden, etc.) caused by a single stale `=true` flag set at
first bootstrap and never flipped.

---

## ⚠️ Data-Loss Near-Miss: The ArgoCD Finalizer Cascade

This is the scariest part of the whole incident and deserves its own section.

### What happened

To force-restart the broken ArgoCD, I had to delete the ArgoCD `Application` CRs. But
those Applications carried this finalizer:

```yaml
finalizers:
  - resources-finalizer.argocd.argoproj.io
```

That finalizer tells ArgoCD: *"before you let this Application be deleted, cascade-delete
everything it manages."* So deleting the App CRs didn't just remove the Application
objects — it triggered ArgoCD (the **Kubespray-deployed** one, which still had control)
to **delete all the child resources, including the PVCs.**

Result: PVCs for stateful apps were wiped. **qBittorrent** and **Jellyfin** both lost
their PVCs.

### Why it wasn't a total disaster

The underlying **PVs survived** because their reclaim policy was `Retain`, not `Delete`.
So the data was still on disk — the PVs just dropped into `Released` state, orphaned,
because their `claimRef` still pointed at the now-deleted PVCs.

**PostgreSQL (CNPG) escaped entirely** — a lucky break. Its Application had auto-sync
fully disabled (`automated.enabled: false`, `prune: false`, `selfHeal: false`), and CNPG
manages its own PVCs through the operator rather than as direct ArgoCD-pruned children.
Worth confirming *why* it survived rather than trusting luck next time.

### How I fixed it (PV → PVC rebind)

When a PV with `Retain` policy loses its PVC, it goes to `Released` and refuses to bind
to a new PVC because the stale `claimRef` still references the old (deleted) claim's UID.
The fix is to clear that reference, then recreate the PVC so it binds back to the
existing PV (with the data intact):

```bash
# 1. Confirm the PV is Released and note its name
kubectl get pv

# 2. Clear the stale claimRef so the PV becomes Available again
kubectl patch pv <pv-name> --type merge -p '{"spec":{"claimRef": null}}'

# 3. Recreate the PVC, pinning it to the exact PV via volumeName so it
#    rebinds to the existing data instead of provisioning a fresh volume
#    (PVC spec must match the PV: same storageClass, accessModes, capacity)
kubectl apply -f <pvc-with-volumeName-set>.yaml

# 4. Verify the PVC is Bound to the right PV
kubectl get pvc -n <namespace>
```

After rebinding, qBittorrent and Jellyfin came back with their original data.

### Lessons

- **`resources-finalizer.argocd.argoproj.io` = cascade delete.** Deleting an Application
  carrying this finalizer deletes ALL its managed resources, PVCs included. This is
  independent of `prune`/`selfHeal` settings — the finalizer fires on Application
  deletion regardless.
- **To delete an Application WITHOUT nuking its resources**, strip the finalizer first:
  ```bash
  kubectl patch app <name> -n argocd --type merge -p '{"metadata":{"finalizers":null}}'
  kubectl delete app <name> -n argocd
  ```
  Or use a non-cascading delete. NEVER blindly `kubectl delete app` when the finalizer
  is present and the app manages stateful workloads.
- **`Retain` reclaim policy is what saved the data.** Every stateful PV should use
  `Retain`, not `Delete`. This single setting was the difference between "annoying
  rebind" and "permanent data loss."
- **Whoever holds the ArgoCD control plane holds the delete button.** Because the
  *Kubespray* ArgoCD was the live one, IT executed the cascade. Another reason to have
  exactly one ArgoCD, owned by me.

---

## TL;DR — The One Root Cause

**Kubespray's built-in addons fought every service I manage myself via Helm/GitOps.**

I run ArgoCD, Traefik, and MetalLB through my own Helm scripts (GitOps). But Kubespray
*also* ships these as addons, and they were all left `_enabled: true` in my
`group_vars`. Every time the playbook ran, Kubespray re-applied its own copy of each
addon using **static manifests + `kubectl apply` (client-side apply)**, which collided
head-on with my Helm-managed installs.

The fix in every case was the same:
1. Set the addon's `_enabled: false` in `group_vars/k8s_cluster/addons.yml`
2. Delete the resources Kubespray created
3. Re-install / let Helm own it cleanly

---

## What This Actually Was: Configuration Drift

This wasn't a "wrong config" bug — it was **ownership drift**.

The config was *correct for the world that existed at first deployment*. On day 1,
letting Kubespray bootstrap ArgoCD / Traefik / MetalLB with `=true` was the right
call: something had to stand up these components before my GitOps stack existed to
take them over. The flags matched reality at that moment.

The drift is that **my intent moved but the declared config didn't.** I mentally
migrated ownership to Helm/GitOps, but `addons.yml` still declared Kubespray as the
owner. Two sources of truth now disagreed about who owns those resources — and the
disagreement stayed *dormant* until the next `cluster.yml` run forced both owners to
act at once. That's the signature of drift: a silent gap that only bites at the next
reconcile.

The trap is that the **bootstrap → handoff transition has no enforced cleanup step.**
Nothing reminds you to flip the flags once GitOps is live, so the bootstrap flags
become vestigial config — and vestigial config is exactly what bites months later
once you've forgotten it's there.

> **Bootstrap flags are temporary scaffolding, not permanent config.**
> Kubespray addon flags (`argocd_enabled`, `metallb_enabled`, etc.) exist to bootstrap
> a bare cluster before GitOps is online. The moment a component migrates to
> Helm/GitOps ownership, its bootstrap flag MUST be flipped to `false` in the same
> change. Leaving it `true` creates a dormant second owner that stays invisible until
> the next reconcile — at which point both owners fight.

### How to make this structurally impossible (not memory-dependent)

- **Handoff checklist in the repo** — when a component is GitOps-ified, the PR template
  forces a "disable the corresponding Kubespray addon" step.
- **CI lint (strongest)** — a check that greps `addons.yml` for any `_enabled: true`
  overlapping a component I manage via Helm, and fails the pipeline. This turns
  "remember to flip the flag" into "the pipeline won't let me forget."

---

## The Screw-Ups (in order)

### 1. Left Kubespray addons enabled while self-managing via Helm

`argocd_enabled: true` was sitting in my own `group_vars/k8s_cluster/addons.yml`.
I'd forgotten it was there. Kubespray was reinstalling ArgoCD on every run and
clobbering my Helm install.

**Symptom:**
```
Error: UPGRADE FAILED: conflict occurred while applying object ...
conflict with "kubectl-client-side-apply" using v1: .data.ssh_known_hosts ...
```

**Lesson:** If I manage a component via Helm/GitOps, the matching Kubespray addon
MUST be disabled. The two ownership models cannot coexist on the same resources.

---

### 2. Misunderstood field manager ownership (SSA vs CSA)

The "conflict with kubectl-client-side-apply" error confused me. The cause:
Kubespray installs via `kubectl apply` (client-side apply), which writes
`kubectl-client-side-apply` as the field manager. My Helm upgrade then tried to claim
the same fields via server-side apply → Kubernetes refuses, because a different
manager already owns them.

**Lesson:** Field-manager conflicts = two different tools claiming ownership of the
same fields. `--force-conflicts` can force a takeover, but it does NOT stop the other
tool from re-applying later.

---

### 3. Didn't understand how Ansible loads `group_vars`

I was confused about which `group_vars` actually applies — mine, or the one inside
`kubespray/inventory/sample/`.

**The rules:**
- `group_vars` is resolved **relative to the inventory file** (and the playbook dir).
- The `group_vars` inside `kubespray/inventory/sample/` is just a **reference** —
  it is NEVER loaded unless I point `-i` directly at that sample inventory.
- Inside `group_vars/<group>/`, Ansible loads **all files**, regardless of filename.
- Loading is **one level deep only — NOT recursive**. Nested subdirectories are
  silently ignored (no error).

**Lesson:** Only the `group_vars` next to my actual inventory (`production.ini`)
matters. Filename inside the group dir is irrelevant; directory depth is not.

---
### 4. Same trap with MetalLB (host port collision)

MetalLB speakers stuck `Pending`:
```
0/6 nodes are available: 1 node(s) didn't have free ports for the requested pod ports ...
```

Two MetalLB installs in two namespaces:
```
metallb-system   ← Kubespray's (running, holding hostPort 7472 + 7946)
metallb          ← mine (Helm, Pending — ports already taken)
```

DaemonSet speakers use `hostPort`, so only ONE MetalLB can bind those ports per node.
Kubespray got there first.

**Lesson:** `hostPort` is a node-level singleton. Duplicate DaemonSets using the same
hostPort guarantee `Pending` pods. Delete the Kubespray namespace
(`kubectl delete namespace metallb-system`) to free the ports.

---

### 5. Played whack-a-mole instead of auditing upfront

I hit the exact same problem three times (ArgoCD → Traefik → MetalLB) because I fixed
them one at a time instead of auditing all enabled addons first.

**Lesson:** Audit ALL Kubespray-managed addons in one pass before upgrading:
```bash
grep "_enabled: true" group_vars/k8s_cluster/addons.yml
```
Disable everything I manage myself, all at once.

---

## Pre-Upgrade Checklist (do this next time)

- [ ] Audit enabled addons: `grep "_enabled: true" group_vars/k8s_cluster/addons.yml`
- [ ] Set `_enabled: false` for every component I manage via Helm/GitOps
      (ArgoCD, Traefik, MetalLB, ingress, cert-manager, etc.)
- [ ] Confirm `group_vars` is next to the real inventory (`production.ini`), not the
      kubespray sample inventory
- [ ] For version bumps: set `kube_version` and verify against
      `kubespray/roles/kubespray_defaults/defaults/main/main.yml`
- [ ] Upgrade **one minor version at a time** (e.g. 1.30 → 1.31 → 1.32, never skip)
- [ ] Use `upgrade-cluster.yml`, NOT `cluster.yml`, for existing-cluster upgrades
- [ ] After upgrade, verify no duplicate workloads:
      `kubectl get all -A | grep -E 'argocd|traefik|metallb'`
- [ ] When GitOps-ifying a NEW component later: flip its Kubespray bootstrap flag to
      `false` in the SAME change (treat it as part of the handoff, not a follow-up)
- [ ] Before upgrading: warn family / pick a low-traffic window (last upgrade caused
      1h18m downtime on Nextcloud + other family-facing services)
- [ ] Keep ingress + LB layer (Traefik, MetalLB) as the FIRST thing to verify after an
      upgrade — they're the blast-radius multiplier that takes everything else down
- [ ] Confirm ALL stateful PVs use `Retain` reclaim policy (this is what saved the data
      this time): `kubectl get pv -o custom-columns=NAME:.metadata.name,POLICY:.spec.persistentVolumeReclaimPolicy`
- [ ] NEVER `kubectl delete app` on an ArgoCD Application with the
      `resources-finalizer.argocd.argoproj.io` finalizer if it manages stateful
      workloads — strip the finalizer first, or it cascade-deletes the PVCs

---

## Key Mental Models to Keep

| Concept | Takeaway |
|---|---|
| **Config drift** | Bootstrap flags are scaffolding. When intent moves to GitOps, flip the flag in the same change or it becomes a dormant second owner. |
| **Ownership** | Pick ONE deployer per component — Kubespray OR Helm, never both. |
| **Field managers** | SSA vs `kubectl-client-side-apply` conflicts = two owners on shared fields. |
| **`--force-conflicts`** | Resolves shared-field ownership only. Doesn't stop duplicate deployers. |
| **`group_vars` loading** | Relative to inventory; all files in the group dir; one level deep; not recursive. |
| **`hostPort`** | Node-level singleton. Duplicate DaemonSets = `Pending`. |
| **ArgoCD finalizer** | `resources-finalizer.argocd.argoproj.io` cascade-deletes ALL managed resources (incl. PVCs) on Application delete. Strip it first for stateful apps. |
| **PV reclaim policy** | `Retain` = data survives PVC deletion (rebind via clearing `claimRef`). `Delete` = gone forever. Use `Retain` for all stateful PVs. |
| **Pod `Completed`** | Long-running process exited 0 — almost always wrong for a daemon. |
| **K8s upgrades** | One minor version at a time, `upgrade-cluster.yml`. |