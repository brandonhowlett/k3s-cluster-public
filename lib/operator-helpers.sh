#!/usr/bin/env bash
set -euo pipefail

apply_operator_manifests() {
  local op="$1"
  local subpath="${2:-}"

  log_debug "apply_operator_manifests op=$op subpath=$subpath"

  if [[ "$subpath" == *".."* ]]; then
    log_error "Unsafe subpath rejected: $subpath"
    return 1
  fi

  [[ -n "$subpath" && "$subpath" != /* ]] && subpath="/$subpath"

  local base="${OPERATORS_DIR}/${op}/k8s${subpath}"

  [[ -d "$base" ]] || {
    log_debug "No manifests found at $base; skipping"
    return 0
  }

  log_info "Applying operator manifests for $op from $base"

  shopt -s nullglob globstar

  for f in "$base"/**/*.yaml "$base"/**/*.yml; do
    [[ "$f" == *.sops.yaml || "$f" == *secret.yaml ]] && continue
    log_info "Applying manifest: $f"
    kubectl apply --server-side -f "$f"
  done

  for enc in "$base"/**/*.sops.yaml; do
    log_info "Applying encrypted manifest: $enc"
    kubectl apply --server-side -f "$enc"
  done

  shopt -u nullglob globstar
}

wait_for_secret() {
  local secret="$1"
  local namespace="${2:-default}"
  local timeout="${3:-120}"

  log_info "Waiting for Secret '$secret' in namespace '$namespace' (timeout=${timeout}s)"

  for ((i=1; i<=timeout; i++)); do
    kubectl get secret "$secret" -n "$namespace" >/dev/null 2>&1 && {
      log_debug "Secret available: $secret"
      return 0
    }
    sleep 1
  done

  log_error "Timeout waiting for Secret '$secret' in namespace '$namespace'"
  return 1
}

wait_for_pvc() {
  local pvc="$1"
  local namespace="${2:-default}"
  local timeout="${3:-120}"

  log_info "Waiting for PVC '$pvc' in namespace '$namespace' (timeout=${timeout}s)"

  for ((i=1; i<=timeout; i++)); do
    kubectl get pvc "$pvc" -n "$namespace" >/dev/null 2>&1 && {
      log_debug "PVC bound: $pvc"
      return 0
    }
    sleep 1
  done

  log_error "Timeout waiting for PVC '$pvc' in namespace '$namespace'"
  return 1
}

wait_for_configmap() {
  local cm="$1"
  local namespace="${2:-default}"
  local timeout="${3:-120}"

  log_info "Waiting for ConfigMap '$cm' in namespace '$namespace' (timeout=${timeout}s)"

  for ((i=1; i<=timeout; i++)); do
    kubectl get configmap "$cm" -n "$namespace" >/dev/null 2>&1 && {
      log_debug "ConfigMap available: $cm"
      return 0
    }
    sleep 1
  done

  log_error "Timeout waiting for ConfigMap '$cm' in namespace '$namespace'"
  return 1
}

# wait_for_helm_deployment() {
#   local release="$1"
#   local namespace="${2:-default}"
#   local timeout="${3:-120}"

#   [[ "$timeout" =~ [ms]$ ]] || timeout="${timeout}s"

#   log_info "Waiting for Helm deployment '$release' in namespace '$namespace' (timeout=$timeout)"

#   kubectl rollout status deployment \
#     -l app.kubernetes.io/instance="$release" \
#     -n "$namespace" \
#     --timeout="$timeout"
# }
