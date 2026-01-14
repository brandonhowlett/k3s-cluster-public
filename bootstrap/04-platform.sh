#!/usr/bin/env bash
set -euo pipefail
trap 'log_error "Script failed at line ${LINENO}: ${BASH_COMMAND}"' ERR

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT_DIR}/lib/loader.sh"

log_info "=== Phase 04: Platform Bootstrap ==="
log_debug "ROOT_DIR=${ROOT_DIR}"

# -------------------------------------------------------------------
# Load bootstrap.env
# -------------------------------------------------------------------

BOOTSTRAP_ENV_FILE="${ROOT_DIR}/bootstrap.env"
if [[ -f "$BOOTSTRAP_ENV_FILE" ]]; then
  log_debug "Sourcing bootstrap.env from $BOOTSTRAP_ENV_FILE"
  source "$BOOTSTRAP_ENV_FILE"
else
  log_warn "bootstrap.env not found; proceeding without environment overrides"
fi

# -------------------------------------------------------------------
# Platform Layer Functions
# -------------------------------------------------------------------

resolve_workload_env_vars() {
  log_debug "Resolving environment variables for workload: ${WORKLOAD_NAME}"

  # initialize all optional overrides (required for set -u)
  WORKLOAD_NAMESPACE_OVERRIDE=""
  WORKLOAD_CHART_OVERRIDE=""
  WORKLOAD_CHART_VERSION_OVERRIDE=""
  WORKLOAD_CHART_REPO_OVERRIDE=""

  local envvar base fullvar

  for envvar in $(compgen -v | grep '_NAME$'); do
    [[ "$envvar" == "WORKLOAD_NAME" ]] && continue

    log_debug "Checking env var ${envvar}=${!envvar} against workload name ${WORKLOAD_NAME}"

    if [[ "${!envvar}" == "$WORKLOAD_NAME" ]]; then
      base="${envvar%_NAME}"
      log_info "Matched workload environment prefix: ${base}"

      fullvar="${base}_NAMESPACE"
      WORKLOAD_NAMESPACE_OVERRIDE="${!fullvar:-}"

      fullvar="${base}_CHART"
      WORKLOAD_CHART_OVERRIDE="${!fullvar:-}"

      fullvar="${base}_CHART_VERSION"
      WORKLOAD_CHART_VERSION_OVERRIDE="${!fullvar:-}"

      fullvar="${base}_CHART_REPO"
      WORKLOAD_CHART_REPO_OVERRIDE="${!fullvar:-}"

      log_debug "Resolved overrides:"
      log_debug "  NAMESPACE=${WORKLOAD_NAMESPACE_OVERRIDE:-<none>}"
      log_debug "  CHART=${WORKLOAD_CHART_OVERRIDE:-<none>}"
      log_debug "  VERSION=${WORKLOAD_CHART_VERSION_OVERRIDE:-<none>}"
      log_debug "  REPO=${WORKLOAD_CHART_REPO_OVERRIDE:-<none>}"
      return 0
    fi
  done

  log_debug "No environment overrides matched workload '${WORKLOAD_NAME}'"
}

helm_install_or_upgrade_release() {
  local release="$1"
  local chart="$2"
  local namespace="$3"
  local version="${4:-}"
  local values_file="${5:-}"

  log_info "Installing/upgrading Helm release '${release}' in namespace '${namespace}'"

  local args=(upgrade --install "$release" "$chart" -n "$namespace")
  [[ -n "$version" ]] && args+=(--version "$version")
  [[ -f "$values_file" ]] && args+=(--values "$values_file")

  log_debug "Helm command: helm ${args[*]}"
  helm "${args[@]}"
}

bootstrap_platform_workloads() {
  local app_dir values_file chart_file
  local EFFECTIVE_CHART EFFECTIVE_NAMESPACE EFFECTIVE_VERSION EFFECTIVE_REPO

  for app_dir in "${ROOT_DIR}/helm/platform/"*; do
    [[ -d "$app_dir" ]] || continue
    log_info "Processing platform directory: ${app_dir}"

    load_workload_metadata "$app_dir" || {
      log_warn "No workload.yaml found in ${app_dir}, skipping"
      continue
    }

    validate_workload_kind || {
      log_error "Invalid workload kind in ${app_dir}, skipping"
      continue
    }

    log_debug "Loaded workload metadata:"
    log_debug "  Name=${WORKLOAD_NAME}"
    log_debug "  Kind=${WORKLOAD_KIND}"
    log_debug "  Namespace=${WORKLOAD_NAMESPACE}"
    log_debug "  Rollout enabled=${WORKLOAD_ROLLOUT_ENABLED}"
    log_debug "  Rollout timeout=${WORKLOAD_TIMEOUT}"

    resolve_workload_env_vars

    values_file="${app_dir}/values.yaml"
    chart_file="${app_dir}/Chart.yaml"

    EFFECTIVE_NAMESPACE="${WORKLOAD_NAMESPACE_OVERRIDE:-$WORKLOAD_NAMESPACE}"
    EFFECTIVE_CHART="${WORKLOAD_CHART_OVERRIDE:-$app_dir}"
    EFFECTIVE_VERSION="${WORKLOAD_CHART_VERSION_OVERRIDE:-}"
    EFFECTIVE_REPO="${WORKLOAD_CHART_REPO_OVERRIDE:-}"

    log_info "Effective configuration for '${WORKLOAD_NAME}':"
    log_info "  Namespace=${EFFECTIVE_NAMESPACE}"
    log_info "  Chart=${EFFECTIVE_CHART}"
    log_info "  Version=${EFFECTIVE_VERSION:-<none>}"
    log_info "  Values=${values_file:-<none>}"
    log_info "  Repo=${EFFECTIVE_REPO:-<none>}"

    log_debug "Ensuring namespace exists: ${EFFECTIVE_NAMESPACE}"
    kubectl create namespace "${EFFECTIVE_NAMESPACE}" \
      --dry-run=client -o yaml | kubectl apply -f -

    if [[ -n "$EFFECTIVE_REPO" ]]; then
      local REPO_NAME="${EFFECTIVE_CHART%%/*}"   # Extract prefix from chart
      declare -A TEMP_REPOS=([$REPO_NAME]="$EFFECTIVE_REPO")
      log_info "Registering Helm repo '${REPO_NAME}' for '${WORKLOAD_NAME}'"
      helm_add_repos TEMP_REPOS
    fi

    if [[ -n "$WORKLOAD_CHART_OVERRIDE" || -f "$chart_file" ]]; then
      log_info "Deploying Helm workload '${WORKLOAD_NAME}'"
      helm_install_or_upgrade_release \
        "$WORKLOAD_NAME" \
        "$EFFECTIVE_CHART" \
        "$EFFECTIVE_NAMESPACE" \
        "$EFFECTIVE_VERSION" \
        "$values_file"
    else
      log_debug "No Helm chart detected for '${WORKLOAD_NAME}'"
    fi

    if [[ -d "$app_dir/k8s" ]]; then
      log_info "Applying raw Kubernetes manifests for '${WORKLOAD_NAME}'"
      shopt -s nullglob globstar
      for f in "$app_dir/k8s/"**/*.y{a,}ml; do
        [[ "$f" == *.sops.yaml ]] && continue
        log_debug "Applying manifest: ${f}"
        kubectl apply -f "$f"
      done
      shopt -u nullglob globstar
    fi

    if [[ "$WORKLOAD_KIND" != "none" ]]; then
      log_info "Waiting for workload readiness: ${WORKLOAD_NAME}"
      wait_for_workload
    fi

    log_info "Workload '${WORKLOAD_NAME}' is ready"
  done
}

# -------------------------------------------------------------------
# Main
# -------------------------------------------------------------------

main() {
  log_info "Running platform preflight checks"
  check_required_cmds kubectl helm yq

  log_info "Bootstrapping platform workloads"
  bootstrap_platform_workloads
}

main
log_info "=== Phase 04 complete: platform components ready ==="
