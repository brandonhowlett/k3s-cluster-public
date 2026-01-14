#!/usr/bin/env bash
set -euo pipefail

get_installed_yq_info() {
  # Returns: "source:version", where source=apt|binary|none
  if dpkg -s yq >/dev/null 2>&1; then
    local ver
    ver="$(yq --version 2>/dev/null | head -n1 || echo "unknown")"
    echo "apt:${ver}"
  elif [[ -x "/usr/local/bin/yq" ]]; then
    local ver
    ver="$(/usr/local/bin/yq --version 2>/dev/null | head -n1 || echo "unknown")"
    echo "binary:${ver}"
  else
    echo "none:0"
  fi
}

install_yq() {
  local info source ver latest_ver

  info="$(get_installed_yq_info)"
  source="${info%%:*}"
  ver="${info##*:}"

  # Fetch the latest release version from GitHub
  latest_ver="$(curl -sSL https://api.github.com/repos/mikefarah/yq/releases/latest \
                 | yq -r '.tag_name' 2>/dev/null | sed 's/^v//')"

  case "$source" in
    apt)
      log_warn "yq installed via apt (${ver})"
      read -rp "Do you want to uninstall apt yq and use the official binary? [y/N] " yn
      if [[ "$yn" =~ ^[Yy]$ ]]; then
        sudo apt-get remove -y yq
        log_info "apt yq removed"
        install_yq_binary "$latest_ver"
      else
        log_info "Keeping apt yq (${ver})"
      fi
      ;;
    binary)
      log_info "yq binary detected: ${ver}"
      if [[ -n "$latest_ver" && "$ver" != "$latest_ver" ]]; then
        log_warn "yq binary is outdated (installed: ${ver}, latest: ${latest_ver}), updating..."
        install_yq_binary "$latest_ver"
      else
        log_debug "yq binary is up-to-date (${ver})"
      fi
      ;;
    none)
      log_info "yq not found, installing binary"
      install_yq_binary "$latest_ver"
      ;;
    *)
      log_error "Unknown yq installation state: $source"
      ;;
  esac
}

install_yq_binary() {
  local version="${1:-latest}"
  local url="/usr/local/bin/yq"
  local download_url

  if [[ "$version" == "latest" ]]; then
    download_url="https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64"
  else
    download_url="https://github.com/mikefarah/yq/releases/download/v${version}/yq_linux_amd64"
  fi

  log_info "Installing yq binary from ${download_url}"
  sudo wget -q "${download_url}" -O "$url"
  sudo chmod +x "$url"
  log_info "yq installed to ${url}: $($url --version 2>&1 | head -n1)"
}
