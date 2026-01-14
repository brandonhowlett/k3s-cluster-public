#!/usr/bin/env bash
set -uo pipefail
trap 'log "ERROR: Script failed at line $LINENO: $BASH_COMMAND"' ERR

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT_DIR}/lib/loader.sh"

# -------------------------------------------------------------------
# Global exit code
# -------------------------------------------------------------------
EXIT_CODE=0

# -------------------------------------------------------------------
# Helper to check resources without exiting
# -------------------------------------------------------------------
check_resource() {
    local type="$1"
    local namespace="${2:-}"
    shift 2
    local items=("$@")
    local ns_arg=()
    
    [[ -n "$namespace" ]] && ns_arg=(-n "$namespace")

    if [[ ${#items[@]} -eq 0 ]]; then
        if kubectl get "$type" "${ns_arg[@]}" >/dev/null 2>&1; then
            log "PASS: $type exists in ${namespace:-all namespaces}"
        else
            log "FAIL: No $type found in ${namespace:-all namespaces}"
            EXIT_CODE=1
        fi
        return
    fi

    for item in "${items[@]}"; do
        if kubectl get "$type" "$item" "${ns_arg[@]}" >/dev/null 2>&1; then
            log "PASS: $type/$item exists in ${namespace:-all namespaces}"
        else
            log "FAIL: $type/$item missing in ${namespace:-all namespaces}"
            EXIT_CODE=1
        fi
    done
}

# -------------------------------------------------------------------
# Secrets
# -------------------------------------------------------------------
log "=== Checking Secrets ==="
check_resource secret cert-manager smarthome-root-ca cloudflare-api-token
check_resource secret traefik traefik-internal-tls

# -------------------------------------------------------------------
# ClusterIssuers
# -------------------------------------------------------------------
log "=== Checking ClusterIssuers ==="
check_resource clusterissuer "" clusterissuer-lan-smarthome clusterissuer-cloudflare

# -------------------------------------------------------------------
# Certificates
# -------------------------------------------------------------------
log "=== Checking Certificates ==="
CERTS=(traefik-internal) # Add more if needed
check_resource certificate traefik "${CERTS[@]}"

# -------------------------------------------------------------------
# ConfigMaps
# -------------------------------------------------------------------
log "=== Checking ConfigMaps ==="
check_resource configmap traefik traefik-dynamic-config

# -------------------------------------------------------------------
# PVCs
# -------------------------------------------------------------------
log "=== Checking PVCs ==="
check_resource pvc traefik traefik-plugins-pvc

# -------------------------------------------------------------------
# Services
# -------------------------------------------------------------------
log "=== Checking Services ==="
check_resource svc traefik traefik
check_resource svc cloudflared cloudflared

# -------------------------------------------------------------------
# Pods
# -------------------------------------------------------------------
log "=== Checking Pods ==="
kubectl get pods -A -o custom-columns=NAMESPACE:.metadata.namespace,NAME:.metadata.name,STATUS:.status.phase,READY:.status.containerStatuses[*].ready || EXIT_CODE=1

# -------------------------------------------------------------------
# CRDs
# -------------------------------------------------------------------
log "=== Checking CRDs ==="
kubectl get crds | grep -E 'traefik|cert-manager|sops' || { log "WARN: Some CRDs missing"; EXIT_CODE=1; }

# -------------------------------------------------------------------
# IngressClasses
# -------------------------------------------------------------------
log "=== Checking IngressClasses ==="
kubectl get ingressclasses || { log "WARN: No IngressClasses found"; EXIT_CODE=1; }

log "=== Cluster verification complete ==="
exit $EXIT_CODE
