# PostgreSQL Latency Benchmark Report
**Homelab Investigation — Kubernetes Cluster**
**Date:** 2026-05-09
**Cluster:** Self-hosted Kubernetes (kubeadm) — HCMC Homelab

---

## Overview

This report documents a latency investigation conducted on a self-hosted Kubernetes cluster running PostgreSQL. The initial suspicion was that the database was performing poorly based on pgAdmin4 query runtime metrics. After systematic benchmarking at each layer of the stack, the conclusion is that **PostgreSQL is healthy** and the perceived latency was entirely due to pgAdmin4's web application overhead.

---

## Environment

| Component | Details |
|-----------|---------|
| Kubernetes version | kubeadm-provisioned cluster |
| CNI | Calico |
| Service proxy | kube-proxy (iptables mode) |
| Nodes | 3 master nodes + 4+ worker nodes |
| PostgreSQL service | `postgresql-rw.prod-postgresql` (ClusterIP) |
| PostgreSQL pod IP | `10.233.99.147:5432` |
| pgAdmin4 | Deployed in-cluster, accessed via Traefik ingress |

---

## The Problem

pgAdmin4 consistently reported `SELECT 1` taking **~80ms**, which suggested severe database or network latency. The initial hypothesis was that either:

1. **kube-proxy** was adding routing overhead to service traffic
2. **Calico CNI** had networking issues (supported by 19–30 restarts per node on `calico-node` pods)
3. **PostgreSQL itself** was slow

---

## Methodology

Testing was performed in three layers to isolate where latency was actually occurring:

### Layer 1 — pgAdmin4 (GUI Tool)

```
Browser → Traefik Ingress → pgAdmin4 Web Server → PostgreSQL → reverse path
```

**Command equivalent:** Run `SELECT 1` in the pgAdmin4 query tool.

### Layer 2 — psql via Direct Pod IP (Bypasses kube-proxy)

```bash
kubectl run pg-test --rm -it --restart=Never \
  --image=bitnami/postgresql \
  --env="PGPASSWORD=yourpassword" \
  -- psql -h 10.233.99.147 -U postgres -c "\timing on" -c "SELECT 1;"
```

This connects directly to the pod IP, bypassing kube-proxy and Calico service routing entirely. It measures pure TCP + PostgreSQL execution time from inside the cluster.

### Layer 3 — psql via Kubernetes Service (Through kube-proxy)

```bash
kubectl run pg-test --rm -it --restart=Never \
  --image=bitnami/postgresql \
  --env="PGPASSWORD=yourpassword" \
  -- psql -h postgresql-rw.prod-postgresql -U postgres -c "\timing on" -c "SELECT 1;"
```

This connects via the ClusterIP service, going through kube-proxy iptables rules. Comparing this against Layer 2 reveals whether kube-proxy adds overhead.

---

## Results

| Layer | Method | Measured Latency | Network Path |
|-------|--------|-----------------|--------------|
| pgAdmin4 | GUI query tool | **~80 ms** | Browser → Ingress → pgAdmin server → PostgreSQL |
| psql (pod IP) | `psql -h 10.233.99.147` with `\timing` | **1.634 ms** | Pod → Pod IP (direct, no kube-proxy) |
| psql (service) | `psql -h postgresql-rw.prod-postgresql` with `\timing` | **1.527 ms** | Pod → ClusterIP → kube-proxy → Pod |

---

## Analysis

### PostgreSQL Performance

With `SELECT 1` returning in **~1.5ms** from inside the cluster, PostgreSQL is performing well within normal ranges. For reference, `SELECT 1` on a healthy PostgreSQL instance should complete in under 5ms on a local network. The measured values are excellent.

It is worth noting that `\timing` in `psql` measures **wall-clock time as seen by the client**, which includes:
- TCP round-trip latency (client → server → client)
- PostgreSQL query parsing, planning, and execution time
- Result transfer back to the client

For server-side-only timing (excluding network), `EXPLAIN ANALYZE` can be used:

```sql
EXPLAIN ANALYZE SELECT 1;
-- Planning Time: ~0.05 ms
-- Execution Time: ~0.02 ms
```

### kube-proxy Overhead

The difference between direct pod IP (1.634ms) and service ClusterIP (1.527ms) is negligible — effectively **0ms overhead** from kube-proxy for this workload. kube-proxy is **not a contributing factor** to latency in this environment.

### pgAdmin4 Overhead Breakdown

The 80ms pgAdmin4 figure is composed of multiple layers of overhead unrelated to PostgreSQL:

| Component | Estimated Contribution |
|-----------|----------------------|
| PostgreSQL execution | ~1.5 ms |
| pgAdmin Python/Flask backend (JSON serialization) | ~5–15 ms |
| HTTP round-trip (browser ↔ Traefik ↔ pgAdmin pod) | ~20–40 ms |
| Browser JavaScript rendering (result grid, dashboard) | ~20–30 ms |
| **Total** | **~80 ms** |

pgAdmin4 also runs background polling queries for its dashboard graphs, adding further noise to any timing measurements taken through its interface.

### Calico Node Restarts

While not the root cause of this investigation, the `calico-node` pods show 19–30 restarts each over 86 days. This warrants separate investigation as it may indicate:

- Node-level memory pressure (OOM causing pod eviction)
- BGP peer flapping causing brief route convergence delays
- Underlying node instability

These restarts did not affect the benchmark results during testing but could cause intermittent connectivity issues under production load.

---

## Conclusions

1. **PostgreSQL is healthy** — ~1.5ms query latency is excellent for intra-cluster communication.
2. **kube-proxy is not a bottleneck** — Service routing adds no measurable overhead compared to direct pod IP access.
3. **pgAdmin4 is unsuitable for performance benchmarking** — Its reported "Total query runtime" includes web application overhead that inflates the real DB time by 40–50x.
4. **Calico restarts** are a separate concern to investigate but are not causing database latency.

---

## Recommendations

### For Future Benchmarking

Always measure PostgreSQL performance from **inside the cluster** using `psql` with `\timing`, not through GUI tools:

```bash
# Spin up a persistent debug pod
kubectl run netshoot --image=nicolaka/netshoot -- sleep infinity

# Test TCP connect latency to PostgreSQL
kubectl exec -it netshoot -- hping3 -S -p 5432 -c 10 10.233.99.147

# Test actual query latency
kubectl run pg-test --rm -it --restart=Never \
  --image=bitnami/postgresql \
  --env="PGPASSWORD=yourpassword" \
  -- psql -h postgresql-rw.prod-postgresql -U postgres \
     -c "\timing on" -c "SELECT 1;"

# Clean up
kubectl delete pod netshoot
```

### For pgAdmin4

Disable aggressive dashboard polling to reduce background query noise:
> **File → Preferences → Dashboards → Graphs → Refresh rate** → set to `10` seconds

### For Calico Restarts

Investigate node memory pressure and BGP stability:

```bash
# Check node conditions
kubectl describe nodes | grep -A5 Conditions

# Check Calico BGP status
kubectl exec -it -n kube-system <calico-node-pod> -- birdcl show protocols

# Check for OOM events
kubectl -n kube-system logs <calico-node-pod> --previous | grep -iE "oom|killed|error"
```

---

## Debugging Principle Learned

> **Always measure at the closest possible layer to the component under investigation.**

Every tool in the chain between the user and the database (browser, web server, ingress, etc.) adds overhead that can mask the actual system performance. A GUI reporting 80ms does not mean the database is slow — it means the entire path from the GUI to the database and back takes 80ms.

| ❌ Misleading | ✅ Ground Truth |
|--------------|----------------|
| pgAdmin4 "Total query runtime" | `psql \timing` from inside cluster |
| Latency measured from outside cluster | `hping3`/`nc` from a pod on the same network |
| Application-reported DB time | `EXPLAIN ANALYZE` on the server |

