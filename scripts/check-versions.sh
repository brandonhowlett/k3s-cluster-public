#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT_DIR}/lib/loader.sh"

# =============================================================================
# CONFIG
# =============================================================================

readonly BACKUP_RETENTION=3

log_debug "ROOT_DIR=${ROOT_DIR}"

# =============================================================================
# HELPERS
# =============================================================================

prune_old_backups() {
    local base="$1"
    local keep="$2"
    local backups=()

    log_debug "Pruning backups for base=${base}, keep=${keep}"

    mapfile -t backups < <(ls -1t "${base}.bak."* 2>/dev/null || true)

    if (( ${#backups[@]} <= keep )); then
        log_debug "No old backups to prune (count=${#backups[@]})"
        return 0
    fi

    for old in "${backups[@]:keep}"; do
        rm -f -- "$old"
        log_info "Pruned old backup: $(basename "$old")"
    done
}

sanitize() {
    tr -d '\n' <<<"$1" | xargs
}

update_env_var() {
    local key="$1"
    local value
    value="$(sanitize "$2")"

    log_debug "Updating ${key}=${value}"

    if grep -q "^${key}=" "$BOOTSTRAP_ENV"; then
        log_debug "Key ${key} exists; updating in-place"
        awk -v k="$key" -v v="$value" '
            BEGIN { FS=OFS="=" }
            $1 == k { $2="'"'"'" v "'"'"'" }
            { print }
        ' "$BOOTSTRAP_ENV" > "${BOOTSTRAP_ENV}.tmp"
        mv "${BOOTSTRAP_ENV}.tmp" "$BOOTSTRAP_ENV"
    else
        log_debug "Key ${key} does not exist; appending"
        echo "${key}='${value}'" >> "$BOOTSTRAP_ENV"
    fi
}

get_latest_github_release() {
    local repo="$1"
    log_debug "Querying GitHub latest release for ${repo}"

    curl -fsSL "https://api.github.com/repos/$repo/releases/latest" \
        | jq -r '.tag_name // empty'
}

get_helm_deployed_chart_version() {
    local release="$1"
    log_debug "Resolving deployed Helm chart version for release=${release}"

    helm list -A -o json \
        | jq -r ".[] | select(.name==\"$release\") | .chart" \
        | awk -F'-' '{print $NF}' \
        | sed 's/^v//' \
        || echo "unknown"
}

get_helm_latest_chart_version() {
    local chart_ref="$1"
    log_debug "Resolving latest Helm chart version for ${chart_ref}"

    helm search repo "$chart_ref" --versions -o json \
        | jq -r '.[0].version // "unknown"' \
        | sed 's/^v//'
}

check_github_version() {
    local label="$1"
    local repo="$2"
    local pinned_var="$3"
    local latest_var="$4"

    local latest pinned
    pinned="${!pinned_var:-}"

    log_debug "Checking ${label}: repo=${repo}, pinned_var=${pinned_var}"

    latest="$(get_latest_github_release "$repo")"

    if [[ -n "$latest" ]]; then
        update_env_var "$latest_var" "${latest#v}"
        log_info "${label}: Pinned=\"${pinned}\" Latest=\"${latest#v}\""
    else
        update_env_var "$latest_var" "unknown"
        log_warn "Unable to resolve latest ${label} version"
    fi
}

# =============================================================================
# MAIN
# =============================================================================

main() {
    log_info "Starting version check"

    if [[ ! -f "$BOOTSTRAP_ENV" ]]; then
        log_error "bootstrap.env not found at ${BOOTSTRAP_ENV}"
        exit 1
    fi

    local backup_file
    backup_file="${BOOTSTRAP_ENV}.bak.$(date +%s)"

    cp "$BOOTSTRAP_ENV" "$backup_file"
    log_info "Backup created: $(basename "$backup_file")"

    prune_old_backups "$BOOTSTRAP_ENV" "$BACKUP_RETENTION"

    # shellcheck disable=SC1090
    source "$BOOTSTRAP_ENV"
    log_debug "Loaded b.env"

    # -------------------------------------------------------------------------
    # PHASE 1: HOST TOOLING
    # -------------------------------------------------------------------------

    log_info "Phase 1: Host tooling"

    check_github_version \
        "SOPS" \
        "getsops/sops" \
        "SOPS_VERSION" \
        "SOPS_VERSION_LATEST"

    check_github_version \
        "K3s" \
        "k3s-io/k3s" \
        "K3S_VERSION" \
        "K3S_VERSION_LATEST"

    check_github_version \
        "Helm" \
        "helm/helm" \
        "HELM_VERSION" \
        "HELM_VERSION_LATEST"

    # -------------------------------------------------------------------------
    # PHASE 2: INFRASTRUCTURE
    # -------------------------------------------------------------------------

    log_info "Phase 2: Infrastructure"

    check_github_version \
        "Calico operator" \
        "projectcalico/calico" \
        "CALICO_OPERATOR_VERSION" \
        "CALICO_OPERATOR_VERSION_LATEST"

    # -------------------------------------------------------------------------
    # PHASE 3: OPERATORS
    # -------------------------------------------------------------------------

    log_info "Phase 3: Operator charts"

    local chart_var base name_var pinned_var
    local release chart_ref pinned deployed latest

    for chart_var in $(compgen -v | grep '_CHART$'); do
        base="${chart_var%_CHART}"

        [[ "$base" =~ ^(CERT_MANAGER|TRAEFIK|SOPS_OPERATOR|CLOUDFLARED)$ ]] || continue

        name_var="${base}_NAME"
        pinned_var="${base}_CHART_VERSION"

        release="${!name_var:-}"
        chart_ref="${!chart_var:-}"
        pinned="${!pinned_var:-}"

        if [[ -z "$release" || -z "$chart_ref" ]]; then
            log_warn "Skipping ${base} (missing NAME or CHART)"
            continue
        fi

        log_debug "Checking chart=${chart_ref}, release=${release}"

        deployed="$(get_helm_deployed_chart_version "$release")"
        latest="$(get_helm_latest_chart_version "$chart_ref")"

        update_env_var "${base}_CHART_VERSION_LATEST" "$latest"
        log_info "${release}: Pinned=\"${pinned}\" Deployed=\"${deployed}\" Latest=\"${latest}\""
    done

    log_info "Version check complete"
    log_info "Updated: ${BOOTSTRAP_ENV}"
}

# =============================================================================
# ENTRYPOINT
# =============================================================================

main "$@"
