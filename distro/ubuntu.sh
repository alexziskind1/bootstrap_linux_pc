#!/usr/bin/env bash
#
# distro/ubuntu.sh
# Ubuntu adapter: package-manager layer + Ubuntu-specific edge cases.
# Sourced by common-utils.sh — do not run directly.
#

SSH_SERVICE="ssh"

CLEANUP_PKGS=(
  aisleriot
  gnome-mahjongg
  gnome-mines
  gnome-sudoku
  rhythmbox
  shotwell
  simple-scan
  transmission-gtk
)

export DEBIAN_FRONTEND=noninteractive

# Map canonical (Fedora-style) names to Ubuntu package names
pkg_name() {
  case "$1" in
    gcc-c++)       echo "g++" ;;
    libcurl-devel) echo "libcurl4-openssl-dev" ;;
    lm_sensors)    echo "lm-sensors" ;;
    fuse)          echo "libfuse2" ;;   # AppImage support (libfuse2t64 on 24.04+, aliased)
    *)             echo "$1" ;;
  esac
}

native_pkg_installed() { dpkg -s "$1" &>/dev/null; }
native_install_pkg()   { sudo apt-get install -y "$1"; }
native_remove_pkg()    { sudo apt-get remove -y "$1"; }

# Downloads a GPG signing key and dearmors it into $2. Fails loudly and
# leaves no partial keyring file if either step fails, so callers can
# skip writing the corresponding repo file instead of leaving apt
# pointed at a repo with no valid key.
add_apt_repo_key() {
  local url="$1" keyring_path="$2"
  local tmp_key
  tmp_key="$(mktemp)"

  if ! curl -fsSL "$url" -o "$tmp_key"; then
    err "Failed to download signing key from $url"
    rm -f "$tmp_key"
    return 1
  fi

  if [[ ! -s "$tmp_key" ]]; then
    err "Downloaded signing key from $url is empty."
    rm -f "$tmp_key"
    return 1
  fi

  if ! sudo gpg --dearmor -o "$keyring_path" "$tmp_key"; then
    err "Failed to dearmor signing key into $keyring_path"
    rm -f "$tmp_key"
    sudo rm -f "$keyring_path"
    return 1
  fi

  rm -f "$tmp_key"
  return 0
}

# Adds one apt repo: fetches+dearmors its key via add_apt_repo_key, and
# only writes the sources.list.d entry if that succeeded. On failure,
# warns and leaves the repo (and its packages) skipped rather than
# writing a repo file with no matching key.
add_apt_repo() {
  local name="$1" list_file="$2" key_url="$3" keyring_path="$4" repo_line="$5"

  if [[ -f "$list_file" ]]; then
    ok "$name repository already configured. Skipping."
    return 0
  fi

  log "Adding $name repository..."
  if ! add_apt_repo_key "$key_url" "$keyring_path"; then
    warn "Skipping $name repository setup — $name install will be skipped."
    return 1
  fi

  if ! echo "$repo_line" | sudo tee "$list_file" >/dev/null; then
    err "Failed to write $name repository configuration to $list_file"
    sudo rm -f "$keyring_path"
    return 1
  fi

  ok "$name repository configured."
}

distro_setup_repos() {
  # universe/multiverse are usually on for Desktop, but make sure
  log "Ensuring universe and multiverse repositories are enabled..."
  sudo add-apt-repository -y universe >/dev/null 2>&1 || true
  sudo add-apt-repository -y multiverse >/dev/null 2>&1 || true

  add_apt_repo "Google Chrome" \
    /etc/apt/sources.list.d/google-chrome.list \
    https://dl.google.com/linux/linux_signing_key.pub \
    /usr/share/keyrings/google-chrome.gpg \
    "deb [arch=amd64 signed-by=/usr/share/keyrings/google-chrome.gpg] http://dl.google.com/linux/chrome/deb/ stable main"

  add_apt_repo "VS Code" \
    /etc/apt/sources.list.d/vscode.list \
    https://packages.microsoft.com/keys/microsoft.asc \
    /usr/share/keyrings/microsoft.gpg \
    "deb [arch=amd64,arm64 signed-by=/usr/share/keyrings/microsoft.gpg] https://packages.microsoft.com/repos/code stable main"

  log "Updating apt package lists..."
  sudo apt-get update

  # Ubuntu doesn't preinstall Flatpak; needed for KDiskMark/Mission Center
  install_pkg flatpak
}

distro_install_vulkan_deps() {
  install_pkg libvulkan-dev
  install_pkg glslc
  install_pkg glslang-tools
  install_pkg mesa-vulkan-drivers
}

# uv isn't in Ubuntu's repos; use the official installer (-> ~/.local/bin)
distro_install_uv() {
  if have_cmd uv; then
    ok "uv already installed. Skipping."
    return 0
  fi
  log "Installing uv via official installer..."
  curl -LsSf https://astral.sh/uv/install.sh | sh \
    && ok "uv installed." \
    || warn "uv installation failed. Continuing."
}

# Full ffmpeg is in universe/multiverse — no swap dance needed
distro_install_ffmpeg() {
  install_pkg ffmpeg
}

distro_install_dotnet() {
  if have_cmd dotnet; then
    ok ".NET SDK already installed. Skipping."
    return 0
  fi
  log "Installing .NET SDK..."
  sudo apt-get install -y dotnet-sdk-10.0 \
    || sudo apt-get install -y dotnet-sdk-9.0 \
    || sudo apt-get install -y dotnet-sdk-8.0 \
    && ok ".NET SDK installed." \
    || warn ".NET SDK installation failed. Continuing."
}

distro_install_dev_group() {
  install_pkg build-essential
}

distro_cleanup_extras() {
  # apport = Ubuntu's crash reporter
  if systemctl list-unit-files apport.service &>/dev/null; then
    log "Disabling apport crash reporting..."
    sudo systemctl disable --now apport.service 2>/dev/null \
      && ok "apport disabled." \
      || warn "Could not disable apport."
    if [[ -f /etc/default/apport ]]; then
      sudo sed -i 's/^enabled=1/enabled=0/' /etc/default/apport
    fi
  fi

  # unattended-upgrades pollutes benchmark runs with background CPU/disk/network
  if systemctl list-unit-files unattended-upgrades.service &>/dev/null; then
    log "Disabling unattended-upgrades..."
    sudo systemctl disable --now unattended-upgrades.service 2>/dev/null \
      && ok "unattended-upgrades disabled." \
      || warn "Could not disable unattended-upgrades."
  fi
}

distro_remove_libreoffice() {
  if dpkg -l 'libreoffice*' 2>/dev/null | grep -q '^ii'; then
    log "Removing LibreOffice suite..."
    sudo apt-get remove -y 'libreoffice*' && sudo apt-get autoremove -y \
      && ok "LibreOffice removed." \
      || warn "Failed to remove LibreOffice."
  else
    ok "LibreOffice not installed. Skipping."
  fi
}

distro_open_ssh_firewall() {
  # ufw is inactive by default on Ubuntu Desktop; only add a rule if it's on
  if have_cmd ufw && sudo ufw status | grep -q 'Status: active'; then
    if sudo ufw status | grep -qw '22\|OpenSSH'; then
      ok "Firewall already allows SSH."
    else
      sudo ufw allow ssh \
        && ok "Firewall opened for SSH." \
        || warn "Could not open firewall for SSH."
    fi
  else
    ok "ufw inactive — SSH reachable without firewall changes."
  fi
}