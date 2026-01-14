#!/usr/bin/env bash
set -euo pipefail

apply_layer() {
  local DIR="$1"

  log_debug "apply_layer invoked with DIR=${DIR}"

  if [[ ! -d "$DIR" ]]; then
    log_error "Directory not found: $DIR"
    return 1
  fi

  log_info "Applying Kubernetes manifests from layer: $DIR"

  mapfile -t FILES < <(find "$DIR" -type f -name '*.yaml' | sort)

  log_debug "Found ${#FILES[@]} manifest(s)"

  for f in "${FILES[@]}"; do
    if [[ "$f" =~ \.sops\.yaml$ ]]; then
      log_info "Applying encrypted manifest: $f"
      sops -d "$f" | kubectl apply -f -
    else
      log_info "Applying manifest: $f"
      kubectl apply -f "$f"
    fi
  done

  log_debug "Completed apply_layer for $DIR"
}
