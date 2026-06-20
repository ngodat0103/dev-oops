#!/usr/bin/env bash
# =============================================================================
# minikube-dr-start.sh
# Spins up a 3-node minikube cluster that mirrors DOKS DR target:
#   - 1 control-plane node
#   - 2 worker nodes
#   - 4 vCPU / 8GB RAM per node  (matches DO s-4vcpu-8gb droplet)
#   - Kubernetes v1.35.x          (matches current DOKS stable)
#   - Docker driver on Linux      (FUSE/privileged works — JuiceFS CSI ready)
#
# Prerequisites:
#   - minikube >= v1.38.1
#   - docker (running, current user in docker group)
#   - kubectl
#   - ~30GB free disk (3 nodes × ~10GB base image)
#   - Host RAM: 24GB+ recommended (3 nodes × 8GB + host overhead)
#
# Usage:
#   chmod +x minikube-dr-start.sh
#   ./minikube-dr-start.sh          # start
#   ./minikube-dr-start.sh stop     # stop (keeps state)
#   ./minikube-dr-start.sh delete   # full teardown
# =============================================================================

set -euo pipefail

# ── Config ────────────────────────────────────────────────────────────────────
PROFILE="homelab-dr"
K8S_VERSION="v1.35.5"          # pin to current DOKS stable
NODES=3                         # 1 control-plane + 2 workers
CPUS=4                          # per node — matches DO s-4vcpu-8gb
MEMORY=8192                     # MB per node — matches DO s-4vcpu-8gb
DISK=30g                        # per node
DRIVER="docker"
CNI="calico"                    # DOKS uses Cilium but Calico is close enough
                                # and more predictable on minikube multi-node
CONTAINER_RUNTIME="containerd"  # matches DOKS worker nodes

# ── Colors ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

info()    { echo -e "${CYAN}[info]${RESET}  $*"; }
success() { echo -e "${GREEN}[ok]${RESET}    $*"; }
warn()    { echo -e "${YELLOW}[warn]${RESET}  $*"; }
die()     { echo -e "${RED}[error]${RESET} $*" >&2; exit 1; }

# ── Helpers ───────────────────────────────────────────────────────────────────
check_deps() {
    local missing=()
    for cmd in minikube docker kubectl; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done
    [[ ${#missing[@]} -eq 0 ]] || die "Missing dependencies: ${missing[*]}"

    # Warn if host RAM looks tight
    local host_ram_mb
    host_ram_mb=$(awk '/MemTotal/ { printf "%d", $2/1024 }' /proc/meminfo 2>/dev/null || echo 0)
    local needed_mb=$(( NODES * MEMORY + 4096 ))   # +4GB for host overhead
    if [[ host_ram_mb -gt 0 && host_ram_mb -lt needed_mb ]]; then
        warn "Host RAM: ${host_ram_mb}MB — cluster needs ~${needed_mb}MB."
        warn "Consider reducing MEMORY or NODES if this machine can't handle it."
        read -r -p "Continue anyway? [y/N] " ans
        [[ "${ans,,}" == "y" ]] || exit 0
    fi

    # Docker must be running
    docker info &>/dev/null || die "Docker is not running."

    # Check /dev/fuse exists — required for JuiceFS CSI
    [[ -e /dev/fuse ]] || warn "/dev/fuse not found. JuiceFS CSI mount pods may fail."
}

label_workers() {
    info "Labelling worker nodes..."
    # minikube names workers as <profile>-m02, <profile>-m03, etc.
    for i in $(seq 2 "$NODES"); do
        local node
        node=$(printf "%s-m%02d" "$PROFILE" "$i")
        # Wait until the node is registered
        local retries=0
        until kubectl get node "$node" &>/dev/null; do
            (( retries++ ))
            [[ retries -lt 30 ]] || die "Node $node never appeared."
            sleep 5
        done
        # minikube leaves workers without a role label — add one to match DOKS
        kubectl label node "$node" \
            node-role.kubernetes.io/worker=worker \
            --overwrite
        success "Labelled $node as worker"
    done
}

taint_control_plane() {
    # DOKS control plane is managed and not schedulable for user workloads.
    # Replicate that so scheduling tests are realistic.
    local cp_node="$PROFILE"
    info "Tainting control-plane node ($cp_node) — no user workloads..."
    kubectl taint node "$cp_node" \
        node-role.kubernetes.io/control-plane=:NoSchedule \
        --overwrite 2>/dev/null || true
}

verify_cluster() {
    info "Verifying cluster..."
    echo ""
    kubectl get nodes -o wide
    echo ""
    kubectl get pods -A --field-selector=status.phase!=Running 2>/dev/null | head -20 || true
}

fuse_preflight() {
    info "Checking FUSE availability on all nodes (required for JuiceFS CSI)..."
    for i in $(seq 1 "$NODES"); do
        local node
        if [[ $i -eq 1 ]]; then
            node="$PROFILE"
        else
            node=$(printf "%s-m%02d" "$PROFILE" "$i")
        fi
        if minikube ssh -p "$PROFILE" -n "$node" -- ls /dev/fuse &>/dev/null; then
            success "  $node: /dev/fuse OK"
        else
            warn "  $node: /dev/fuse missing — JuiceFS mount pods will fail on this node"
        fi
    done
}

# ── Subcommands ───────────────────────────────────────────────────────────────
cmd_start() {
    check_deps

    echo -e "\n${BOLD}╔══════════════════════════════════════════════════════╗${RESET}"
    echo -e "${BOLD}║     minikube DR cluster — homelab-dr                 ║${RESET}"
    echo -e "${BOLD}║     1 control-plane + 2 workers                      ║${RESET}"
    echo -e "${BOLD}║     ${CPUS} vCPU / ${MEMORY}MB RAM per node (DO s-4vcpu-8gb)   ║${RESET}"
    echo -e "${BOLD}╚══════════════════════════════════════════════════════╝${RESET}\n"

    if minikube status -p "$PROFILE" &>/dev/null; then
        warn "Profile '$PROFILE' already exists."
        read -r -p "Delete and recreate? [y/N] " ans
        if [[ "${ans,,}" == "y" ]]; then
            minikube delete -p "$PROFILE"
        else
            info "Starting existing profile..."
            minikube start -p "$PROFILE"
            verify_cluster
            return
        fi
    fi

    info "Starting cluster (this takes 3–5 minutes)..."

    minikube start \
        --profile="$PROFILE" \
        --nodes="$NODES" \
        --kubernetes-version="$K8S_VERSION" \
        --driver="$DRIVER" \
        --container-runtime="$CONTAINER_RUNTIME" \
        --cpus="$CPUS" \
        --memory="$MEMORY" \
        --disk-size="$DISK" \
        --cni="$CNI" \
        --extra-config=kubelet.max-pods=110 \
        --extra-config=apiserver.enable-admission-plugins=NamespaceLifecycle,LimitRanger,ServiceAccount,DefaultStorageClass,DefaultTolerationSeconds,MutatingAdmissionWebhook,ValidatingAdmissionWebhook,ResourceQuota \
        --feature-gates="GracefulNodeShutdown=true" \
        --embed-certs

    success "Cluster started"

    label_workers
    taint_control_plane
    fuse_preflight

    echo ""
    success "Cluster is ready. Context: $(kubectl config current-context)"
    echo ""
    verify_cluster

    echo ""
    echo -e "${BOLD}Next steps:${RESET}"
    echo "  # Install JuiceFS CSI"
    echo "  helm repo add juicefs https://juicedata.github.io/charts/"
    echo "  helm install juicefs-csi-driver juicefs/juicefs-csi-driver -n kube-system \\"
    echo "    --set kubeletDir=/var/lib/kubelet"
    echo ""
    echo "  # Install CNPG operator"
    echo "  helm install cnpg cloudnative-pg/cloudnative-pg -n cnpg-system --create-namespace"
    echo ""
    echo "  # Stop cluster (preserves state)"
    echo "  minikube stop -p $PROFILE"
    echo ""
    echo "  # Full teardown"
    echo "  $0 delete"
}

cmd_stop() {
    info "Stopping cluster '$PROFILE' (state preserved)..."
    minikube stop -p "$PROFILE"
    success "Stopped. Run '$0' to resume."
}

cmd_delete() {
    warn "This will permanently delete the '$PROFILE' cluster and all its data."
    read -r -p "Are you sure? [y/N] " ans
    [[ "${ans,,}" == "y" ]] || { info "Aborted."; exit 0; }
    minikube delete -p "$PROFILE"
    success "Cluster deleted."
}

cmd_status() {
    minikube status -p "$PROFILE" || true
    echo ""
    kubectl get nodes -o wide 2>/dev/null || true
}

# ── Entrypoint ────────────────────────────────────────────────────────────────
case "${1:-start}" in
    start)  cmd_start  ;;
    stop)   cmd_stop   ;;
    delete) cmd_delete ;;
    status) cmd_status ;;
    *)
        echo "Usage: $0 [start|stop|delete|status]"
        exit 1
        ;;
esac