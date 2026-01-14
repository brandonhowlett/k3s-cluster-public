#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT_DIR}/lib/loader.sh"

# Default log level
LOG_LEVEL="${LOG_LEVEL_INFO}"

# Parse CLI args for log level
for arg in "$@"; do
  case "${arg}" in
    --log=DEBUG) LOG_LEVEL="${LOG_LEVEL_DEBUG}" ;;
    --log=INFO)  LOG_LEVEL="${LOG_LEVEL_INFO}" ;;
    --log=WARN)  LOG_LEVEL="${LOG_LEVEL_WARN}" ;;
    --log=ERROR) LOG_LEVEL="${LOG_LEVEL_ERROR}" ;;
    *)
      log_error "Unknown argument: ${arg}"
      exit 1
      ;;
  esac
done

export LOG_LEVEL

log_info "=== Kubernetes Homelab Bootstrap Wrapper ==="
log_debug "ROOT_DIR=${ROOT_DIR} LOG_LEVEL=${LOG_LEVEL}"

# ----------------------------------------------------------------------
# Phase runner
# ----------------------------------------------------------------------
run_phase() {
    local phase_script="$1"
    local phase_name="$2"

    log_info "Running Phase ${phase_name}: $(basename "$phase_script")"
    log_debug "Phase script path: $phase_script"

    if [[ ! -x "$phase_script" ]]; then
        log_error "Phase script not found or not executable: $phase_script"
        exit 1
    fi

    "$phase_script"

    log_info "=== Phase ${phase_name} complete ==="
}

# ----------------------------------------------------------------------
# Phase 00: Host Tooling
# ----------------------------------------------------------------------
run_phase "${BOOTSTRAP_DIR}/00-host.sh" "00"

if ! command -v kubectl >/dev/null 2>&1; then
    log_warn "kubectl not found yet. Will verify after k3s installation."
else
    log_info "kubectl already available: $(kubectl version --client -o json | jq -r '.clientVersion.gitVersion')"
fi

# ----------------------------------------------------------------------
# Phase 01: Cluster Setup (k3s)
# ----------------------------------------------------------------------
run_phase "${BOOTSTRAP_DIR}/01-cluster.sh" "01"

if ! command -v kubectl >/dev/null 2>&1; then
    if [[ -x /usr/local/bin/k3s ]]; then
        sudo ln -sf /usr/local/bin/k3s /usr/local/bin/kubectl
        log_info "Created kubectl symlink to k3s binary."
    else
        log_error "k3s not installed or missing at /usr/local/bin/k3s."
        exit 1
    fi
fi

log_info "kubectl is now available: $(kubectl version --client -o json | jq -r '.clientVersion.gitVersion')"

# ----------------------------------------------------------------------
# Phase 02: Infrastructure
# ----------------------------------------------------------------------
run_phase "${BOOTSTRAP_DIR}/02-infra.sh" "02"

# ----------------------------------------------------------------------
# Phase 03: Smoke Tests (currently commented out)
# ----------------------------------------------------------------------
# shopt -s nullglob
# SMOKE_SCRIPTS=("${BOOTSTRAP_DIR}"/03-smoke*.sh)
# shopt -u nullglob
# if [[ ${#SMOKE_SCRIPTS[@]} -eq 0 ]]; then
#     log_error "No 03-smoke*.sh scripts found"
#     exit 1
# fi
# for script in "${SMOKE_SCRIPTS[@]}"; do
#     run_phase "$script" "03"
# done
# log_info "=== Phase 03 complete: all smoke tests passed ==="

# ----------------------------------------------------------------------
# Phase 04+: Post-smoke stages
# ----------------------------------------------------------------------
shopt -s nullglob
POST_SCRIPTS=("$BOOTSTRAP_DIR"/04-*.sh)
shopt -u nullglob

if (( ${#POST_SCRIPTS[@]} > 0 )); then
    for script in "${POST_SCRIPTS[@]}"; do
        run_phase "$script" "04"
    done
else
    log_warn "No 04-*.sh scripts found to run"
fi

log_info "=== Kubernetes Homelab Bootstrap Complete ==="
