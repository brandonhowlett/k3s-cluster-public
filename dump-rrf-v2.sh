#!/usr/bin/env bash
set -euo pipefail

RRF_VERSION="1.1"
SCRIPT_NAME="dump-rrf.sh"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GIT_ROOT="$(git -C "$ROOT_DIR" rev-parse --show-toplevel 2>/dev/null || echo "$ROOT_DIR")"

MAX_BYTES=12000

################################################################################
# Role determination (authoritative)
################################################################################
determine_role() {
  local path="$1"

  case "$path" in
    .gitignore)
      echo "vcs-config"
      ;;
    .sops.yaml)
      echo "sops-config"
      ;;
    *.env|*.env.bak)
      echo "config-env"
      ;;
    bootstrap/*.sh)
      case "$path" in
        *host*) echo "bootstrap-host" ;;
        *cluster*) echo "bootstrap-cluster" ;;
        *infra*) echo "bootstrap-infra" ;;
        *smoke*) echo "bootstrap-smoke" ;;
        *) echo "bootstrap-script" ;;
      esac
      ;;
    lib/*.sh)
      echo "bootstrap-library"
      ;;
    helm/**/values.yaml)
      echo "helm-values"
      ;;
    helm/**/Chart.yaml)
      echo "helm-chart"
      ;;
    helm/**/k8s/*.yaml)
      echo "k8s-manifest"
      ;;
    scripts/*.sh)
      echo "utility-script"
      ;;
    Makefile)
      echo "tooling"
      ;;
    pki/*)
      echo "pki-artifact"
      ;;
    *)
      echo "unknown"
      ;;
  esac
}

################################################################################
# Criticality determination
################################################################################
determine_criticality() {
  local role="$1"
  local path="$2"

  case "$role" in
    bootstrap-host|bootstrap-cluster|bootstrap-infra)
      echo "critical"
      ;;
    sops-config|k8s-secret|embedded-secret)
      echo "critical"
      ;;
    config-env)
      [[ "$path" == *.bak ]] && echo "low" || echo "medium"
      ;;
    helm-values)
      echo "medium"
      ;;
    tooling|utility-script)
      echo "low"
      ;;
    *)
      echo "unknown"
      ;;
  esac
}

################################################################################
# Content safety checks
################################################################################
contains_private_key() {
  grep -q "BEGIN OPENSSH PRIVATE KEY" "$1" 2>/dev/null
}

################################################################################
# Emit helpers
################################################################################
emit_json() {
  jq -nc "$1"
}

################################################################################
# Header
################################################################################
emit_json '{
  type: "rrf_header",
  version: "'"$RRF_VERSION"'",
  generated_at: (now | todate),
  generator: {
    name: "'"$SCRIPT_NAME"'",
    revision: "'"$(git -C "$GIT_ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)"'"
  }
}'

################################################################################
# Walk files
################################################################################
git -C "$GIT_ROOT" ls-files | while read -r file; do
  full="$GIT_ROOT/$file"

  role="$(determine_role "$file")"

  # Embedded secret override
  if [[ -f "$full" ]] && contains_private_key "$full"; then
    role="embedded-secret"
  fi

  criticality="$(determine_criticality "$role" "$file")"
  bytes="$(wc -c <"$full")"
  sha1="$(sha1sum "$full" | awk '{print $1}')"

  truncated=false
  content=null

  if [[ "$criticality" != "critical" && "$bytes" -le "$MAX_BYTES" ]]; then
    content="$(jq -Rs . <"$full")"
  else
    truncated=true
  fi

  emit_json "{
    type: \"file\",
    path: \"$file\",
    role: \"$role\",
    criticality: \"$criticality\",
    bytes: $bytes,
    sha1: \"$sha1\",
    truncated: $truncated,
    content: $content
  }"
done
