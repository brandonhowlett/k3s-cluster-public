#!/usr/bin/env bash
set -euo pipefail
trap 'log_error "Script failed at line ${LINENO}: ${BASH_COMMAND}"' ERR

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT_DIR}/lib/loader.sh"

log_info "=== Phase 02: Infrastructure Bootstrap ==="

# -------------------------------------------------------------------
# Globals / environment
# -------------------------------------------------------------------

log_debug "Validating required environment variables"

check_required_env_vars \
  SOPS_OPERATOR_NAME \
  SOPS_OPERATOR_CHART \
  SOPS_OPERATOR_CHART_VERSION \
  SOPS_OPERATOR_REPO \
  CERT_MANAGER_NAME \
  CERT_MANAGER_CHART \
  CERT_MANAGER_CHART_VERSION \
  CERT_MANAGER_CHART_REPO \
  TRAEFIK_NAME \
  TRAEFIK_CHART \
  TRAEFIK_CHART_VERSION \
  TRAEFIK_CHART_REPO \
  CLOUDFLARED_NAME \
  CLOUDFLARED_CHART \
  CLOUDFLARED_CHART_VERSION \
  CLOUDFLARED_CHART_REPO

readonly SOPS_OPERATOR_NAMESPACE="${SOPS_OPERATOR_NAME}"
readonly CERT_MANAGER_NAMESPACE="${CERT_MANAGER_NAME}"
readonly TRAEFIK_NAMESPACE="${TRAEFIK_NAME}"
readonly CLOUDFLARED_NAMESPACE="${CLOUDFLARED_NAME}"

log_debug "Namespaces:"
log_debug "  SOPS_OPERATOR_NAMESPACE=${SOPS_OPERATOR_NAMESPACE}"
log_debug "  CERT_MANAGER_NAMESPACE=${CERT_MANAGER_NAMESPACE}"
log_debug "  TRAEFIK_NAMESPACE=${TRAEFIK_NAMESPACE}"
log_debug "  CLOUDFLARED_NAMESPACE=${CLOUDFLARED_NAMESPACE}"

# Helm repo *names must be stable*
declare -A OPERATOR_REPOS=(
  ["${SOPS_OPERATOR_CHART%%/*}"]="${SOPS_OPERATOR_REPO}"
  ["${CERT_MANAGER_CHART%%/*}"]="${CERT_MANAGER_CHART_REPO}"
  ["${TRAEFIK_CHART%%/*}"]="${TRAEFIK_CHART_REPO}"
  ["${CLOUDFLARED_CHART%%/*}"]="${CLOUDFLARED_CHART_REPO}"
)
readonly OPERATOR_REPOS

declare -A OPERATOR_CHARTS=(
  ["${CLOUDFLARED_NAME}"]="${CLOUDFLARED_CHART}"
)
readonly OPERATOR_CHARTS

declare -A OPERATOR_NAMESPACES=(
  ["${CLOUDFLARED_NAME}"]="${CLOUDFLARED_NAMESPACE}"
)
readonly OPERATOR_NAMESPACES

declare -A OPERATOR_VERSIONS=(
  ["${CLOUDFLARED_NAME}"]="${CLOUDFLARED_CHART_VERSION}"
)
readonly OPERATOR_VERSIONS

# -------------------------------------------------------------------
# Namespaces
# -------------------------------------------------------------------

# apply_namespaces() {
#   local ns_dir f
#   ns_dir="${STATIC_DIR}/namespaces"

#   log_info "Applying static namespace manifests from ${ns_dir}"

#   shopt -s nullglob globstar
#   for f in "${ns_dir}"/**/*.y{a,}ml; do
#     [[ "${f}" == *.sops.yaml ]] && {
#       log_debug "Skipping sops metadata file: ${f}"
#       continue
#     }
#     log_debug "Applying namespace manifest: ${f}"
#     kubectl apply -f "${f}"
#   done
#   shopt -u nullglob globstar
# }

# -------------------------------------------------------------------
# SOPS operator
# -------------------------------------------------------------------

create_sops_operator_age_secret() {
  local age_key_file
  age_key_file="${AGE_DIR}/key.txt"

  log_info "Ensuring SOPS operator namespace exists"
  kubectl create namespace "${SOPS_OPERATOR_NAMESPACE}" \
    --dry-run=client -o yaml | kubectl apply -f -

  if [[ ! -f "${age_key_file}" ]]; then
    log_error "Missing age key file: ${age_key_file}"
    exit 1
  fi

  log_info "Creating/updating age-key secret for SOPS operator"
  kubectl create secret generic age-key \
    --from-file=key.txt="${age_key_file}" \
    -n "${SOPS_OPERATOR_NAMESPACE}" \
    --dry-run=client -o yaml | kubectl apply -f -
}

install_sops_operator() {
  log_info "Installing SOPS operator via Helm"

  helm_install_or_upgrade \
    "${SOPS_OPERATOR_NAME}" \
    "${SOPS_OPERATOR_CHART}" \
    "${SOPS_OPERATOR_NAMESPACE}" \
    "${SOPS_OPERATOR_CHART_VERSION}" \
    "${OPERATORS_DIR}/${SOPS_OPERATOR_NAME}/values.yaml"

  log_info "Waiting for SOPS operator rollout"
  kubectl rollout status deployment \
    -n "${SOPS_OPERATOR_NAMESPACE}" \
    -l app.kubernetes.io/instance="${SOPS_OPERATOR_NAME}" \
    --timeout=120s
}

# -------------------------------------------------------------------
# cert-manager
# -------------------------------------------------------------------

install_cert_manager() {
  log_info "Installing cert-manager"

  kubectl create namespace "${CERT_MANAGER_NAMESPACE}" \
    --dry-run=client -o yaml | kubectl apply -f -

  helm_install_or_upgrade \
    "${CERT_MANAGER_NAME}" \
    "${CERT_MANAGER_CHART}" \
    "${CERT_MANAGER_NAMESPACE}" \
    "${CERT_MANAGER_CHART_VERSION}" \
    "${OPERATORS_DIR}/${CERT_MANAGER_NAME}/values.yaml"

  log_info "Waiting for cert-manager CRDs"
  until kubectl get crd certificates.cert-manager.io >/dev/null 2>&1; do
    sleep 3
  done

  local deploy
  for deploy in cert-manager cert-manager-webhook cert-manager-cainjector; do
    log_info "Waiting for deployment: ${deploy}"
    kubectl rollout status deployment/"${deploy}" \
      -n "${CERT_MANAGER_NAMESPACE}" \
      --timeout=120s
  done
}

# -------------------------------------------------------------------
# Issuers / secrets
# -------------------------------------------------------------------

apply_sops_secrets() {
  local sops_secret_file
  sops_secret_file="${STATIC_DIR}/issuers/k8s/10-secret.sops.yaml"

  log_info "Applying SOPS-encrypted issuer secrets"
  kubectl apply --server-side -f "${sops_secret_file}"

  log_debug "Extracting secret names from decrypted manifest"
  local secrets
  mapfile -t secrets < <(
    sops -d "${sops_secret_file}" |
      kubectl apply --dry-run=client -f - \
        -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}'
  )

  local secret
  for secret in "${secrets[@]}"; do
    log_info "Waiting for Secret to exist: ${secret}"
    wait_for_secret "${secret}" "${CERT_MANAGER_NAMESPACE}"
  done
}

apply_cluster_issuers() {
  local cluster_issuers_file
  cluster_issuers_file="${STATIC_DIR}/issuers/k8s/50-clusterIssuers.yaml"

  log_info "Applying ClusterIssuers"
  kubectl apply --server-side -f "${cluster_issuers_file}"

  log_debug "Extracting ClusterIssuer names"
  local issuers
  mapfile -t issuers < <(
    kubectl apply --dry-run=client -f "${cluster_issuers_file}" \
      -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}'
  )

  local issuer
  for issuer in "${issuers[@]}"; do
    log_info "Waiting for ClusterIssuer Ready: ${issuer}"
    kubectl wait "clusterissuer/${issuer}" \
      --for=condition=Ready --timeout=120s
  done
}

# -------------------------------------------------------------------
# Traefik
# -------------------------------------------------------------------

prepare_traefik_static_resources() {
  local values_file
  values_file="${OPERATORS_DIR}/${TRAEFIK_NAME}/values.yaml"

  log_info "Preparing Traefik static resources"
  kubectl create namespace "${TRAEFIK_NAMESPACE}" \
    --dry-run=client -o yaml | kubectl apply -f -

  log_info "Ensuring traefik-plugins-pvc exists"
  kubectl get pvc traefik-plugins-pvc -n "${TRAEFIK_NAMESPACE}" >/dev/null 2>&1 || \
    helm_template_apply \
      "${TRAEFIK_NAME}" \
      "${OPERATORS_DIR}/${TRAEFIK_NAME}" \
      "${TRAEFIK_NAMESPACE}" \
      "${TRAEFIK_CHART_VERSION}" \
      "${values_file}" \
      --show-only templates/plugins-pvc.yaml

  wait_for_pvc traefik-plugins-pvc "${TRAEFIK_NAMESPACE}"

  log_info "Ensuring traefik-dynamic-config ConfigMap exists"
  kubectl get configmap traefik-dynamic-config -n "${TRAEFIK_NAMESPACE}" >/dev/null 2>&1 || \
    helm_template_apply \
      "${TRAEFIK_NAME}" \
      "${OPERATORS_DIR}/${TRAEFIK_NAME}" \
      "${TRAEFIK_NAMESPACE}" \
      "${TRAEFIK_CHART_VERSION}" \
      "${values_file}" \
      --show-only templates/dynamic-configmap.yaml

  wait_for_configmap traefik-dynamic-config "${TRAEFIK_NAMESPACE}"

  log_debug "Applying Traefik pre-CRD manifests"
  apply_operator_manifests "${TRAEFIK_NAME}" /pre-crd
}

install_traefik() {
  log_info "Installing Traefik via Helm"

  helm_install_or_upgrade \
    "${TRAEFIK_NAME}" \
    "${TRAEFIK_CHART}" \
    "${TRAEFIK_NAMESPACE}" \
    "${TRAEFIK_CHART_VERSION}" \
    "${OPERATORS_DIR}/${TRAEFIK_NAME}/values.yaml"

  wait_for_deployment "${TRAEFIK_NAME}" "${TRAEFIK_NAMESPACE}"

  log_debug "Applying Traefik post-CRD manifests"
  apply_operator_manifests "${TRAEFIK_NAME}" /post-crd

  log_info "Waiting for Traefik internal TLS secret"
  wait_for_secret traefik-internal-tls "${TRAEFIK_NAMESPACE}"
}

# -------------------------------------------------------------------
# Remaining operators
# -------------------------------------------------------------------

install_remaining_operators() {
  local op
  for op in "${!OPERATOR_CHARTS[@]}"; do
    log_info "Installing operator: ${op}"

    kubectl create namespace "${op}" \
      --dry-run=client -o yaml | kubectl apply -f -

    helm_install_or_upgrade \
      "${op}" \
      "${OPERATOR_CHARTS[${op}]}" \
      "${OPERATOR_NAMESPACES[${op}]}" \
      "${OPERATOR_VERSIONS[${op}]}" \
      "${OPERATORS_DIR}/${op}/values.yaml"

    apply_operator_manifests "${op}"
    # wait_for_deployment "app.kubernetes.io/instance=${op}" "${OPERATOR_NAMESPACES[${op}]}"
  done
}

# -------------------------------------------------------------------
# Verification
# -------------------------------------------------------------------

verify_infrastructure() {
  log_info "Verifying infrastructure state"
  kubectl get pods -A
  kubectl get ingressclasses
  kubectl get crds | grep -E 'traefik|cert-manager|sops' || true
}

# -------------------------------------------------------------------
# Main
# -------------------------------------------------------------------

main() {
  log_info "Running preflight checks"
  check_required_cmds kubectl helm sops

  log_info "Adding Helm repositories"
  helm_add_repos OPERATOR_REPOS

  # apply_namespaces

  create_sops_operator_age_secret
  install_sops_operator
  install_cert_manager
  apply_sops_secrets
  apply_cluster_issuers
  prepare_traefik_static_resources
  install_traefik
  install_remaining_operators
  verify_infrastructure
}

main

log_info "=== Phase 02 complete: infrastructure + operators ready ==="
