#!/usr/bin/env bash
# scripts/99-destroy.sh — tear down the DOKS cluster and orphaned DO resources.
# Safe to run repeatedly; every step is best-effort and idempotent.
set -uo pipefail   # NOTE: no -e here — cleanup must continue past failures.

destroy_cluster() {
  log_step "Destroy: looking up cluster $CLUSTER_NAME"
  local cluster_id
  cluster_id=$(doctl kubernetes cluster get "$CLUSTER_NAME" \
    --format ID --no-header 2>/dev/null || echo "")

  if [ -z "$cluster_id" ]; then
    log_warn "cluster '$CLUSTER_NAME' not found — nothing to clean up"
    return 0
  fi
  log_info "cluster ID: $cluster_id"

  # Collect LoadBalancer IPs while kubectl still works — needed after deletion.
  local lb_ips
  lb_ips=$(kubectl get svc -A \
    -o jsonpath='{.items[?(@.spec.type=="LoadBalancer")].status.loadBalancer.ingress[0].ip}' \
    2>/dev/null || echo "")

  _scale_down_node_pools
  _delete_cluster
  _delete_volumes "$cluster_id"
  _delete_load_balancers "$cluster_id" "$lb_ips"

  log_ok "Destroy complete"
}

_scale_down_node_pools() {
  log_step "Scaling node pools to 0"
  local pool_ids pool_id
  pool_ids=$(doctl kubernetes cluster node-pool list "$CLUSTER_NAME" \
    --format ID --no-header 2>/dev/null || echo "")
  for pool_id in $pool_ids; do
    log_info "scaling pool $pool_id -> 0"
    doctl kubernetes cluster node-pool update "$CLUSTER_NAME" "$pool_id" --count 0 || true
  done
  [ -n "$pool_ids" ] && sleep 30 || true
}

_delete_cluster() {
  log_step "Deleting DOKS cluster"
  doctl kubernetes cluster delete "$CLUSTER_NAME" --force --dangerous || true
}

_delete_volumes() {
  # DOKS CSI tags every provisioned volume with k8s:<cluster-id>.
  local cluster_id="$1"
  log_step "Cleaning up Block Storage volumes"
  local vol_ids vol_id
  vol_ids=$(doctl compute volume list -o json \
    | jq -r --arg tag "k8s:$cluster_id" \
      '.[] | select(.tags? and (.tags[] == $tag)) | .id' 2>/dev/null || echo "")
  if [ -z "$vol_ids" ]; then
    log_info "no volumes found for cluster $cluster_id"
    return 0
  fi
  for vol_id in $vol_ids; do
    log_info "deleting volume $vol_id"
    doctl compute volume delete "$vol_id" --force || true
  done
}

_delete_load_balancers() {
  local cluster_id="$1" lb_ips="$2"
  log_step "Cleaning up Load Balancers"

  # Primary: match by IPs collected before the cluster was deleted.
  local lb_ip lb_id
  for lb_ip in $lb_ips; do
    lb_id=$(doctl compute load-balancer list -o json \
      | jq -r --arg ip "$lb_ip" '.[] | select(.ip == $ip) | .id')
    if [ -n "$lb_id" ]; then
      log_info "deleting LB $lb_id (IP: $lb_ip)"
      doctl compute load-balancer delete "$lb_id" --force || true
    fi
  done

  # Fallback: catch any LB still tagged with the cluster ID.
  local tagged_ids
  tagged_ids=$(doctl compute load-balancer list -o json \
    | jq -r --arg tag "k8s:$cluster_id" \
      '.[] | select(.tags? and (.tags[] == $tag)) | .id' 2>/dev/null || echo "")
  for lb_id in $tagged_ids; do
    log_info "deleting tagged LB $lb_id"
    doctl compute load-balancer delete "$lb_id" --force 2>/dev/null || true
  done
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  source "$HERE/config.sh"; source "$HERE/lib/log.sh"; source "$HERE/lib/preflight.sh"
  require_cmd doctl kubectl jq
  ensure_doctl_auth
  destroy_cluster
fi