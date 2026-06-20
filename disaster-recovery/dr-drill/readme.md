# PostgreSQL DR Drill

Automated disaster-recovery test for the homelab PostgreSQL (CNPG) cluster.
Provisions a throwaway DOKS cluster, restores PostgreSQL from R2 WAL archives
via ArgoCD + CNPG bootstrap, validates the restored data, then tears everything
down.

All logic lives in bash so it runs **identically locally and in CI**. GitHub
Actions only installs the CLIs and calls `run.sh`.

## Layout

```
dr-drill/
├── config.sh                 # all env vars + defaults (override by exporting)
├── run.sh                    # orchestrator; guaranteed cleanup via EXIT trap
├── lib/
│   ├── log.sh                # logging helpers
│   └── preflight.sh          # CLI/env checks, doctl auth
├── scripts/
│   ├── 00-create-cluster.sh   # provision DOKS + kubeconfig
│   ├── 01-install-argocd.sh   # helm install ArgoCD, wait ready
│   ├── 02-install-apps.sh     # juicefs secret (pre-install), app-of-app,
│   │                          #   cert-manager, secrets, juicefs sync
│   ├── 03-recover-postgres.sh # set recovery tag, sync, wait healthy
│   ├── 04-validate.sh         # verify restored databases/tables
│   ├── 05-validate-vaultwarden.sh # deploy + validate VW on read-only JuiceFS
│   └── 99-destroy.sh          # cluster + orphaned DO volumes/LBs
├── juicefs-application.yaml   # patched ArgoCD Application (conditional `ro`)
└── .github/workflows/dr-drill.yml
```

Each `scripts/*.sh` is independently runnable (`./scripts/05-validate-vaultwarden.sh`)
**and** sourceable by `run.sh`. The functions don't execute on source — only
when the file is run directly (the `BASH_SOURCE` guard at the bottom).

## Drill flow (run.sh)

```
create_cluster → install_argocd
create_juicefs_secret      # BEFORE install: StorageClass references it
install_app_of_app         # juicefs.enabled=true, juicefs.readOnly=true
sync_cert_manager → create_secrets
recover_postgres → validate_data
sync_juicefs               # AFTER postgres: mount pod needs the metaurl DB
sync_vaultwarden → validate_vaultwarden
(EXIT trap) → destroy
```

## Usage

```bash
# full drill
export DIGITALOCEAN_TOKEN=... R2_ACCESS_KEY=... R2_SECRET_KEY=...
export JUICEFS_META_PASSWORD=...          # juicefs DB role pw in the restored cluster
export VW_ADMIN_TOKEN=...                  # optional: enables user-count assertion
./run.sh

# keep the cluster up for inspection (skips teardown)
./run.sh --skip-destroy

# clean up a leaked run later
CLUSTER_NAME=pg-backup-test-123 ./run.sh destroy
```

## JuiceFS read-only protection

The drill mounts JuiceFS **read-only** (`ro` injected into StorageClass
`mountOptions`). This does two things at once:

1. Writes to the prod R2 prefix are rejected — no split-brain corruption.
2. Background GC / trash cleanup is disabled — the DR mount can never delete
   production objects.

`05-validate-vaultwarden.sh` proves this by exec-ing into the Vaultwarden pod
and asserting a write into the data dir fails with `Read-only file system`.

**Apply the patched Application:** replace your existing JuiceFS Application
template with `juicefs-application.yaml` (it adds the conditional `ro` block
gated on `.Values.juicefs.readOnly`). For normal homelab/prod sync, leave
`juicefs.readOnly` unset/false so the mount stays writable.

## Notes

- `run.sh` registers an `EXIT INT TERM` trap, so the cluster is destroyed even
  on failure or Ctrl-C — the equivalent of GHA's `if: always()`.
- `99-destroy.sh` deliberately omits `set -e`: cleanup must continue past
  individual failures.
- The PG app revision override targets `--source-position 1` (the Git source).
  Position 2 is the Helm chart source and requires a SemVer constraint, not a
  Git tag.
- Required CLIs: `doctl`, `kubectl`, `helm`, `argocd`, `jq`, `curl`.
```