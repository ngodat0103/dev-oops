# Proposal: Scheduled Doc-Sync Automation

> *Status:* proposal / high-level idea only. No implementation here — this is the concept to react to before anyone writes a single line of YAML.

## 1. The Problem

The docs drift. They always drift.

Changes land in Terraform, Ansible, and Helm/ArgoCD values whenever the lab evolves — a node gets more RAM, an LXC gets deleted, an app gets toggled on, the cluster gets a version bump. The `readme.md` that *describes* all of this is updated **by hand, irregularly, and only when someone remembers (or gets nagged)**. The result is a readme that quietly lies: it claimed 12 GB when the VM had 8, claimed an LXC existed months after it was deleted, listed a Kubernetes version two releases behind.

Reconciling it is pure recurring toil: open the config, open the readme, diff them in your head, fix six sections, repeat next month. It's the exact kind of mechanical, well-defined chore that should not require a human to initiate.

## 2. The Goal

Docs that stay true to the config **without anyone having to ask**. The human's only remaining job is to glance at a ready-made change and click merge.

Concretely:
- Drift is caught on a regular cadence, not "whenever it gets bad enough to notice."
- The fix is **written automatically**, not just flagged.
- A human still gets the final say (review + merge), but does **zero** detective work.

## 3. Recommended Approach — Scheduled Agentic Doc-Sync

A scheduled job periodically wakes an AI agent (Claude Code, which is already in use here) that has read access to the repo. The agent:

1. Reads the current `readme.md`.
2. Compares each claim against the **live source of truth** (the config files that actually govern the infra — see the map in §4).
3. **Edits `readme.md` directly** to match reality.
4. Opens a **pull request** containing the edits plus a short human-readable summary of *what* drifted and *why* it changed.
5. Does nothing — no PR, no noise — when everything is already in sync.

### Why "auto-write" lands as a PR, not a push to `master`

The user's chosen behavior is *auto-write the fix*. The interpretation here is: the agent does all the writing, but the change arrives as a **PR rather than a direct commit to `master`**. This keeps the protected branch protected, gives a natural review surface, and preserves a one-click "yes this is right" step — which costs the human seconds, versus the minutes-to-never of doing the reconciliation themselves. If fully unattended commits-to-`master` are ever wanted, that's a one-setting change later; starting with a PR is the safe default.

### Why scheduled (not per-PR)

It mirrors the cadence pattern already proven in this repo — the PostgreSQL backup-test workflow runs on a cron (`1st & 15th of the month`) plus a manual trigger. Doc drift is not an emergency; batching it into a periodic sweep is low-noise, cost-bounded (runs a handful of times a month, not on every push), and doesn't block or slow down day-to-day merges.

## 4. Source-of-Truth Map

This is the heart of the whole idea: the agent only stays accurate because it knows **where each fact actually lives**. Readme sections map to config tiers like this:

| Readme section | Source of truth | Tier |
|----------------|-----------------|------|
| Hardware / VM & node sizing (RAM, vCPU, disk, IPs) | `tf/proxmox/main.tf` | Terraform |
| Public/Direct DNS records, MetalLB & Traefik IPs | `tf/cloudflare/dns/main.tf` | Terraform |
| Compute inventory (hosts, IPs, roles) | `ansible/core/inventory.ini` | Ansible |
| Kubernetes version | `ansible/kubernetes/group_vars/all/all.yml` (`kube_version`) | Ansible |
| K8s node ranges / counts | `ansible/kubernetes/kubespray/inventory/local/hosts.ini` | Ansible |
| Enabled vs disabled cluster apps | `kubernetes/argocd/app-of-app/values.yaml` (feature toggles) | K8s / Helm |
| Per-app replicas, storage modes | per-app `values.yaml` under `kubernetes/argocd/argocd-app/**` | K8s / Helm |

Truth is spread across three tiers (Terraform provisions, Ansible configures, Helm/ArgoCD deploys), which is exactly why hand-reconciliation is painful and why a single automated pass over all three is valuable. This map would live alongside the automation so it's easy to extend as the repo grows.

## 5. Workflow Shape (Conceptual)

No code — just the moving parts:

- **Trigger:** a cron schedule (cadence TBD, see open questions) **plus** a manual on-demand trigger for when you want a sync right now.
- **Checkout:** the agent gets the repo at current `master`.
- **Sync step:** the agent runs a tightly-scoped doc-sync task — "reconcile `readme.md` against the source-of-truth map; change nothing else."
- **Output step:** if (and only if) the readme changed, open or update a PR with the diff and a plain-English changelog of what drifted.
- **Credentials:** the agent's API key and a token allowed to open PRs, stored as CI secrets.

## 6. Guardrails

- **Write scope is docs only.** The agent may edit `readme.md` (and optionally other doc files) and nothing else — never config, never code. Enforced by both the prompt and a path check on the resulting diff.
- **Always via PR.** No direct writes to `master`; a human merges.
- **Idempotent / no-op when clean.** A run that finds no drift produces no PR and no notification.
- **Cost-bounded.** Runs on a schedule a few times a month, not on every push.
- **Auditable.** Every change carries a summary explaining the *why*, so the merge decision is informed.

## 7. Trade-offs & Alternatives (brief)

| Alternative | Why not (for now) |
|-------------|-------------------|
| **PR-time gating** — run on every PR, block merge until docs match | Tightest possible sync, but noisy and blocking; turns a doc nit into a merge blocker. Overkill for a single-author lab. |
| **Deterministic marker-block generation** — script regenerates fenced regions of the readme from config, no AI | Rock-solid and cheap for *structured tables*, but can't touch the narrative/prose sections that make this readme readable. |
| **Propose-only** — agent comments suggested edits, never writes | Lower trust required, but leaves the actual editing toil with the human — defeats the "stop asking me" goal. |

**Worth considering as an evolution:** a **hybrid** — deterministic marker-blocks for the hard fact tables (node sizing, enabled apps, DNS) for guaranteed accuracy, plus the agent for the prose and judgement-call sections. Start with the pure-agent approach; graduate to hybrid if the fact tables prove to need bullet-proof precision.

## 8. Open Questions

- **Cadence:** weekly, biweekly (align with the existing 1st/15th cron), or monthly?
- **Scope of docs:** just `readme.md`, or also the per-directory `README.md` files under `tf/`, `ansible/`, `kubernetes/`, `disaster-recovery/`?
- **Runner & model:** which CI runner, which model tier for the agent?
- **Notifications:** silent PR only, or also a ping (e.g. the existing Telegram alert path) when a drift PR is opened?
- **Failure mode:** if the agent is uncertain about a fact, should it skip that section silently or flag it in the PR body for human attention?
