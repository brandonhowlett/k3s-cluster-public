#!/usr/bin/env bash
set -euo pipefail

# -------------------------------------------------------------------
# Helm Repositories
# -------------------------------------------------------------------
helm_add_repos() {
  local -n repos=$1
  local repo url

  log_info "Registering Helm repositories"

  for repo in "${!repos[@]}"; do
    url="${repos[$repo]}"
    log_debug "Adding/updating Helm repo: $repo → $url"

    if helm repo list -o yaml | grep -qE "^name: $repo$"; then
      log_debug "Helm repo '$repo' already exists; updating"
      helm repo add "$repo" "$url" --force-update >/dev/null
    else
      helm repo add "$repo" "$url" >/dev/null
    fi
  done

  log_debug "Updating Helm repo index"
  helm repo update >/dev/null
}

# -------------------------------------------------------------------
# Helm Argument Construction
# -------------------------------------------------------------------

_helm_base_args() {
  local name="$1"
  local chart="$2"
  local namespace="$3"
  local version="$4"
  local values="${5:-}"

  version="v${version#v}"

  local args=(
    "$name" "$chart"
    --namespace "$namespace"
    --version "$version"
  )

  [[ -n "$values" && -f "$values" ]] && {
    args+=(--values "$values")
  }

  echo "${args[@]}"
}

# -------------------------------------------------------------------
# Helm Release Management
# -------------------------------------------------------------------

helm_install_or_upgrade() {
  local name="$1"
  local chart="$2"
  local namespace="$3"
  local version="$4"
  local values="${5:-}"
  shift 5
  local extra_args=("$@")

  if [[ -z "$namespace" ]]; then
    log_warn "Namespace empty; defaulting to release name: $name"
    namespace="$name"
  fi

  log_info "Installing/upgrading Helm release '$name' in namespace '$namespace'"

  kubectl create namespace "$namespace" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null

  local args
  args=($(_helm_base_args "$name" "$chart" "$namespace" "$version" "$values"))

  log_debug "Helm args: ${args[*]} ${extra_args[*]}"

  log_debug "Constructing Helm args: name=$name chart=$chart namespace=$namespace version=$version"


  helm upgrade --install "${args[@]}" \
    --wait \
    --timeout 5m \
    ${HELM_ATOMIC:+--atomic} \
    "${extra_args[@]}"
}

# -------------------------------------------------------------------
# Helm Template Rendering
# -------------------------------------------------------------------

helm_template() {
  local args
  args=($(_helm_base_args "$@"))

  log_debug "Rendering Helm template: ${args[*]}"
  helm template "${args[@]}"
}

# -------------------------------------------------------------------
# Helm Template + Apply
# -------------------------------------------------------------------

helm_template_apply() {
  log_info "Applying Helm-rendered manifests (server-side)"
  helm_template "$@" | kubectl apply --server-side -f -
}
