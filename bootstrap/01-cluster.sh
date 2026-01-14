#!/usr/bin/env bash
set -euo pipefail
trap 'log_error "Script failed at line ${LINENO}: ${BASH_COMMAND}"' ERR

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT_DIR}/lib/loader.sh"

log_info "=== Phase 01: Cluster Bootstrap ==="

# -------------------------------------------------------------------
# Global constants / environment variables
# -------------------------------------------------------------------
readonly CALICO_SYSTEM_NAMESPACE="calico-system"
readonly CALICO_OPERATOR_NAMESPACE="tigera-operator"

log_debug "KUBECONFIG_FILE=${KUBECONFIG_FILE}"
log_debug "CALICO_SYSTEM_NAMESPACE=${CALICO_SYSTEM_NAMESPACE}"
log_debug "CALICO_OPERATOR_NAMESPACE=${CALICO_OPERATOR_NAMESPACE}"

# -------------------------------------------------------------------
# Preflight
# -------------------------------------------------------------------
log_debug "Running environment variable preflight checks"

check_required_env_vars \
  K3S_VERSION \
  K3S_REPO \
  HELM_VERSION \
  HELM_REPO \
  CALICO_CRD_REPO \
  CALICO_OPERATOR_NAME \
  CALICO_OPERATOR_VERSION \
  CALICO_OPERATOR_REPO

# -------------------------------------------------------------------
# API readiness helpers (canonicalized)
# -------------------------------------------------------------------
wait_for_local_api() {
  log_info "Waiting for Kubernetes API socket to become available"
  until curl -sk https://127.0.0.1:6443/healthz >/dev/null; do
    sleep 2
  done
}

wait_for_kube_api() {
  local timeout="${1:-120}"
  local start=$SECONDS

  log_info "Waiting for Kubernetes API to respond to kubectl"

  until kubectl get nodes >/dev/null 2>&1; do
    if (( SECONDS - start > timeout )); then
      log_error "Kubernetes API not ready after ${timeout}s"
      systemctl status k3s --no-pager || true
      journalctl -u k3s --no-pager -n 50 || true
      return 1
    fi
    sleep 2
  done

  log_info "Kubernetes API reachable"
}

# -------------------------------------------------------------------
# Bootstrap functions
# -------------------------------------------------------------------
install_k3s() {
  local pinned_version
  pinned_version="v${K3S_VERSION#v}"

  if systemctl is-active --quiet k3s; then
    log_info "k3s already running — skipping installation"
    return
  fi

  export CLUSTER_CIDR="${CLUSTER_CIDR:-10.42.0.0/16}"
  export SERVICE_CIDR="${SERVICE_CIDR:-10.43.0.0/16}"

  log_info "Installing k3s (no CNI, no Traefik, secrets encryption enabled)"
  log_info "Using cluster CIDR: ${CLUSTER_CIDR}"
  log_debug "Using service CIDR: ${SERVICE_CIDR}"

  retry curl -sfL "${K3S_REPO}" | \
    K3S_KUBECONFIG_MODE="644" \
    INSTALL_K3S_VERSION="${pinned_version}" \
    INSTALL_K3S_EXEC="--flannel-backend=none \
      --cluster-cidr=${CLUSTER_CIDR} \
      --service-cidr=${SERVICE_CIDR} \
      --disable=traefik \
      --secrets-encryption" \
    sh -
}

setup_kubeconfig() {
  wait_for_local_api

  mkdir -p "$(dirname "${KUBECONFIG_FILE}")"

  log_info "Installing kubeconfig to ${KUBECONFIG_FILE}"
  sudo cp /etc/rancher/k3s/k3s.yaml "${KUBECONFIG_FILE}"
  sudo chown "${USER}:${USER}" "${KUBECONFIG_FILE}"
  chmod 600 "${KUBECONFIG_FILE}"

  export KUBECONFIG="${KUBECONFIG_FILE}"
  log_debug "KUBECONFIG exported"

  wait_for_kube_api
}

install_helm() {
  local current_version
  local pinned_version
  local download_url

  pinned_version="v${HELM_VERSION#v}"
  current_version="$(helm version --template '{{ .Version }}' 2>/dev/null || true)"

  log_debug "Detected Helm version: ${current_version:-none}"

  if [[ "${current_version}" != "${pinned_version}" ]]; then
    log_info "Installing Helm ${pinned_version} for linux/amd64"

    # Construct URL safely using printf
    download_url="${HELM_REPO//%v/$pinned_version}"
    log_debug "Download URL: ${download_url}"

    # Download and install
    curl -sfL "${download_url}" | tar xz
    sudo mv linux-amd64/helm /usr/local/bin/helm
    sudo chmod +x /usr/local/bin/helm
    rm -rf linux-amd64
  else
    log_info "Helm ${pinned_version} already installed"
  fi
}

setup_calico_namespace() {
  log_info "Ensuring ${CALICO_SYSTEM_NAMESPACE} namespace exists with Pod Security labels"
  kubectl create namespace calico-system --dry-run=client -o yaml | kubectl apply -f -
  kubectl label namespace calico-system pod-security.kubernetes.io/enforce=baseline --overwrite
  kubectl label namespace calico-system pod-security.kubernetes.io/enforce-version=latest --overwrite
}

install_calico_operator() {
  local pinned_version
  pinned_version="v${CALICO_OPERATOR_VERSION#v}"

  log_info "Installing Calico CRDs and operator"

  if ! kubectl get crd installations.operator.tigera.io >/dev/null 2>&1; then
    retry kubectl create -f "${CALICO_CRD_REPO}"
  else
    log_info "All Calico CRDs already installed"
  fi

  if ! kubectl get deployment tigera-operator -n tigera-operator >/dev/null 2>&1; then
    retry kubectl create -f "${CALICO_OPERATOR_REPO//%v/$pinned_version}"
  else
    log_info "tigera-operator deployment already exists — skipping"
  fi

  log_info "Waiting for ${CALICO_OPERATOR_NAME} to become Available"
  kubectl wait \
    -n "${CALICO_OPERATOR_NAMESPACE}" \
    --for=condition=Available deployment \
    -l k8s-app=tigera-operator \
    --timeout=180s || {
      echo "Error: ${CALICO_OPERATOR_NAME} did not become Available"
      kubectl get pods -n "${CALICO_OPERATOR_NAMESPACE}" -o wide
      exit 1
    }
}

apply_calico() {
  local calico_manifest="${BOOTSTRAP_DIR}/k8s/calico.yaml"

  log_info "Applying Calico installation manifests"
  log_debug "Calico manifest path: ${calico_manifest}"

  [[ -f "${calico_manifest}" ]] || {
    log_error "Calico manifest not found at ${calico_manifest}"
    exit 1
  }

  retry kubectl apply -f "${calico_manifest}"

  log_info "Waiting for Calico components to become available"

  wait_for_deployment_rollout "calico-kube-controllers" "${CALICO_SYSTEM_NAMESPACE}"
  wait_for_deployment_rollout "calico-apiserver" "${CALICO_SYSTEM_NAMESPACE}"
  wait_for_deployment_rollout "calico-typha" "${CALICO_SYSTEM_NAMESPACE}"
  wait_for_rollout "daemonset/calico-node" "${CALICO_SYSTEM_NAMESPACE}"
}

verify_cluster() {
  log_info "Cluster nodes:"
  kubectl get nodes -o wide

  log_info "All pods in all namespaces:"
  kubectl get pods -A -o wide
}

# -------------------------------------------------------------------
# Main execution
# -------------------------------------------------------------------
main() {
  install_k3s
  setup_kubeconfig
  install_helm
  setup_calico_namespace
  install_calico_operator
  apply_calico
  verify_cluster
}

main

log_info "=== Phase 01 complete: cluster ready ==="