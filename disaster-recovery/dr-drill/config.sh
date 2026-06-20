#!/usr/bin/env bash
# config.sh — central configuration for the PostgreSQL DR drill.
# Sourced by run.sh and every script under scripts/.
# All values can be overridden by exporting them before invoking run.sh.

# ---------------------------------------------------------------------------
# Run identity
# ---------------------------------------------------------------------------
# RUN_ID makes the cluster name unique per run. In GHA pass github.run_id;
# locally it falls back to a UTC timestamp.
: "${RUN_ID:=$(date -u +%Y%m%d%H%M%S)}"

: "${CLUSTER_NAME:=pg-backup-test-${RUN_ID}}"

# ---------------------------------------------------------------------------
# DigitalOcean / DOKS
# ---------------------------------------------------------------------------
: "${REGION:=nyc3}"
: "${NODE_SIZE:=s-4vcpu-8gb}"
: "${NODE_COUNT:=2}"

# DIGITALOCEAN_TOKEN must be exported by the caller (GHA secret or local env).
# doctl auth is assumed to be already initialised by the CI dependency step,
# but we re-init defensively if a token is present (see lib/preflight.sh).

# ---------------------------------------------------------------------------
# Kubernetes / app config
# ---------------------------------------------------------------------------
: "${NAMESPACE:=prod-postgresql}"
: "${RECOVERY_TAG:=postgreql-recovery-sync}"
: "${ARGOCD_CHART_VERSION:=9.5.22}"

# Repo-relative path to the app-of-app helm chart.
# Resolved against REPO_ROOT (computed in run.sh).
: "${APP_OF_APP_CHART:=kubernetes/argocd/app-of-app}"

# ---------------------------------------------------------------------------
# Timeouts (seconds unless noted)
# ---------------------------------------------------------------------------
: "${ARGOCD_ROLLOUT_TIMEOUT:=120s}"
: "${HELM_INSTALL_TIMEOUT:=3m}"
: "${CLUSTER_HEALTHY_ATTEMPTS:=90}"   # x10s sleep => 15 min
: "${CLUSTER_HEALTHY_INTERVAL:=10}"

# ---------------------------------------------------------------------------
# JuiceFS (read-only DR mount)
# ---------------------------------------------------------------------------
: "${JUICEFS_ENABLED:=true}"
: "${JUICEFS_READONLY:=true}"          # injects the `ro` mount option
: "${JUICEFS_NAMESPACE:=juicefs}"
: "${JUICEFS_SECRET_NAME:=cloudflare-r2}"
: "${JUICEFS_VOLUME_NAME:=cloudflare-r2-prod}"
: "${JUICEFS_BUCKET:=https://4c8ad4e9fa8213af3fd284bb97b68b5e.r2.cloudflarestorage.com/juicefs-prod}"
# Assigned with a plain conditional: the JSON braces collide with ${VAR:=...}.
if [ -z "${JUICEFS_ENVS:-}" ]; then
  JUICEFS_ENVS='{"JFS_MOUNT_TIMEOUT": 300}'
fi

# Metadata engine (the restored CNPG cluster holding the juicefs_prod DB).
# The rw service for a CNPG cluster named "postgresql" is "postgresql-rw".
: "${JUICEFS_META_USER:=juicefs}"
: "${JUICEFS_META_HOST:=postgresql-rw.${NAMESPACE}.svc}"
: "${JUICEFS_META_DB:=juicefs_prod}"
# JUICEFS_META_PASSWORD must be exported (the juicefs DB role password from the
# restored cluster). If you'd rather supply the whole URL, set JUICEFS_METAURL.
: "${JUICEFS_METAURL:=postgres://${JUICEFS_META_USER}:${JUICEFS_META_PASSWORD:-}@${JUICEFS_META_HOST}:5432/${JUICEFS_META_DB}?sslmode=disable}"

# Label selector for CSI node/controller readiness.
: "${JUICEFS_CSI_SELECTOR:=app.kubernetes.io/name=juicefs-csi-driver}"

# ---------------------------------------------------------------------------
# Vaultwarden (validated against the read-only JuiceFS mount)
# ---------------------------------------------------------------------------
: "${VAULTWARDEN_NAMESPACE:=vaultwarden}"
: "${VAULTWARDEN_DEPLOYMENT:=vaultwarden}"
: "${VAULTWARDEN_SERVICE:=vaultwarden}"
: "${VAULTWARDEN_DATA_PATH:=/data}"        # JuiceFS-backed data dir in the pod
: "${VAULTWARDEN_LOCAL_PORT:=8080}"
: "${VAULTWARDEN_ROLLOUT_TIMEOUT:=300s}"
# Optional: set VW_ADMIN_TOKEN to additionally assert restored user count.

# ---------------------------------------------------------------------------
# Validation expectations
# ---------------------------------------------------------------------------
# Space-separated list of databases that must exist after recovery.
: "${EXPECTED_DBS:=sonarqube}"

# ---------------------------------------------------------------------------
# Secrets (required for the secrets step). Exported by caller.
# ---------------------------------------------------------------------------
#   R2_ACCESS_KEY
#   R2_SECRET_KEY

# ---------------------------------------------------------------------------
# Behaviour flags
# ---------------------------------------------------------------------------
# Set SKIP_DESTROY=1 to leave the cluster running for inspection after a run.
: "${SKIP_DESTROY:=0}"