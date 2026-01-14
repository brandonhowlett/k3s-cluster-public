#!/usr/bin/env bash
set -euo pipefail
trap 'log_error "Script failed at line ${LINENO}: ${BASH_COMMAND}"' ERR

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT_DIR}/lib/loader.sh"

# -------------------------------------------------------------------
# Global constants / environment variables
# -------------------------------------------------------------------
check_required_env_vars \
  SOPS_VERSION \
  SOPS_REPO

PACKAGES=(age jq curl make) # yq sops

# -------------------------------------------------------------------
# Preflight
# -------------------------------------------------------------------
preflight_host() {
  log_info "=== Preflight ==="

  # Required tools
  # check_required_cmds sudo curl jq make age sops

  # Root / sudo check
  if [[ $EUID -ne 0 ]]; then
      log_warn "Not running as root. Some operations may fail (swap disable, package install)."
  fi

  # Swap disabled
  if swapon --noheadings | grep -q .; then
      log_warn "Swap is enabled. It will be disabled in bootstrap."
  fi

  log_info "=== Preflight: PASS ==="
}

# -------------------------------------------------------------------
# Helpers
# -------------------------------------------------------------------
is_installed() {
  dpkg -s "${1}" >/dev/null 2>&1
}

check_tool_or_install() {
  local tool="$1"
  local install_cmd="$2"

  if ! command -v "$tool" >/dev/null 2>&1; then
    log_info "$tool not found; installing..."
    eval "$install_cmd"
    if ! command -v "$tool" >/dev/null 2>&1; then
      log_error "$tool failed to install"
      exit 1
    fi
    log_info "$tool installed successfully: $($tool --version 2>&1 | head -n1)"
  else
    log_debug "$tool already installed: $($tool --version 2>&1 | head -n1)"
  fi
}

# -------------------------------------------------------------------
# Host tooling
# -------------------------------------------------------------------
disable_swap() {
  log_info "Disabling swap"
  sudo swapoff -a
  sudo sed -i '/ swap / s/^/#/' /etc/fstab
  log_debug "Swap disabled and fstab updated"
}

install_apt_packages() {
  local pkg
  local to_install=()

  log_debug "Checking required host packages: ${PACKAGES[*]}"

  for pkg in "${PACKAGES[@]}"; do
    if ! is_installed "${pkg}"; then
      log_debug "Package missing: ${pkg}"
      to_install+=("${pkg}")
    else
      log_debug "Package already installed: ${pkg}"
    fi
  done

  if [[ ${#to_install[@]} -gt 0 ]]; then
    log_info "Installing missing packages: ${to_install[*]}"
    sudo apt-get update
    sudo apt-get install -y "${to_install[@]}"
    log_info "Package installation complete"
  else
    log_info "All required host packages already installed"
  fi
}

install_sops() {
  local pinned_version download_url
  pinned_version="${SOPS_VERSION}"

  if ! command -v sops >/dev/null 2>&1; then
    log_info "Installing sops"
    download_url="${SOPS_REPO//%v/$pinned_version}"
    log_debug "Download URL: ${download_url}"

    sudo curl -L "${download_url}" -o /usr/local/bin/sops
    sudo chmod +x /usr/local/bin/sops
    log_debug "sops installed to /usr/local/bin/sops"
  else
    log_info "sops already installed"
  fi

  if ! command -v sops >/dev/null; then
    log_error "sops failed to install, aborting"
    exit 1
  fi
}

install_yq() {
  local url="/usr/local/bin/yq"
  local download_url="https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64"

  check_tool_or_install yq "sudo wget -q ${download_url} -O ${url} && sudo chmod +x ${url}"
}

# -------------------------------------------------------------------
# Age key management
# -------------------------------------------------------------------
setup_age_keys() {
  local keys_file key_file pub_file

  log_info "Ensuring age keypair exists"
  mkdir -p "${AGE_DIR}"

  keys_file="${AGE_DIR}/keys.txt"
  key_file="${AGE_DIR}/key.txt"
  pub_file="${AGE_DIR}/pub.txt"

  if [[ ! -f "${keys_file}" ]]; then
    log_info "No existing age keys found; generating new keypair"
    age-keygen -o "${keys_file}"
    chmod 600 "${keys_file}"
    log_debug "Generated age keys.txt"
  else
    log_info "Reusing existing age keys.txt"
  fi

  if [[ ! -f "${key_file}" || ! -f "${pub_file}" ]]; then
    log_info "Deriving key.txt and pub.txt from keys.txt"
    sed '/^#/d' "${keys_file}" > "${key_file}"
    grep '^# public key:' "${keys_file}" | awk '{print $4}' > "${pub_file}"
    chmod 600 "${key_file}"
    chmod 644 "${pub_file}"
    log_debug "Derived age key.txt and pub.txt"
  else
    log_debug "Derived age key files already exist"
  fi
}

# -------------------------------------------------------------------
# Repo configuration
# -------------------------------------------------------------------
write_repo_sops_yaml() {
  local sops_yaml pub_key
  sops_yaml="${ROOT_DIR}/.sops.yaml"
  pub_key="$(cat "${AGE_DIR}/pub.txt")"

  log_info "Writing repository-level .sops.yaml"
  log_debug "Using age public key: ${pub_key}"

  cat > "${sops_yaml}" <<EOF
creation_rules:
  - path_regex: .*secrets?\\.yaml$
    encrypted_regex: '^(data|stringData)$'
    key_groups:
      - age:
          - ${pub_key}
EOF

  log_debug ".sops.yaml written to ${sops_yaml}"
}

# -------------------------------------------------------------------
# Main
# -------------------------------------------------------------------
main() {
  log_info "=== Phase 00: Host Tooling Bootstrap ==="
  log_debug "ROOT_DIR resolved to ${ROOT_DIR}"

  preflight_host

  install_apt_packages
  install_yq
  install_sops

  log_debug "Verifying installed tool versions"
  log_debug "sops: $(sops --version 2>&1)"
  log_debug "age: $(age --version 2>&1)"
  log_debug "yq: $(yq --version 2>&1)"

  setup_age_keys
  write_repo_sops_yaml

  log_info "=== Phase 00 complete: tooling + repo config ready ==="
}

# -------------------------------------------------------------------
# Entrypoint
# -------------------------------------------------------------------
main "$@"
