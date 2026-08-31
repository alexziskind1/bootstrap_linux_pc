#!/usr/bin/env bash
#
# distro/arch.sh
# Arch Linux adapter: package-manager layer + Arch-specific edge cases.
# Sourced by common-utils.sh — do not run directly.
#

SSH_SERVICE="sshd"

CLEANUP_PKGS=(
  gnome-tour
  gnome-maps
  gnome-weather
  gnome-contacts
  simple-scan
  rhythmbox
  mediawriter
  gnome-clocks
  gnome-calendar
  totem
)

# Canonical package names are the Arch/AUR names
pkg_name() {
  case "$1" in
    gcc-c++)       echo "gcc" ;;
    libcurl-devel) echo "libcurl-gnutls" ;;
    lm_sensors)    echo "lm_sensors" ;;
    fuse)          echo "fuse2" ;;   # AppImage support
    vlc)           echo "vlc" ;;
    obs-studio)    echo "obs-studio" ;;
    cmake)         echo "cmake" ;;
    python3)       echo "python" ;;
    python3-pip)   echo "python-pip" ;;
    nodejs)        echo "nodejs" ;;
    gh)            echo "github-cli" ;;
    btop)          echo "btop" ;;
    fio)           echo "fio" ;;
    iperf3)        echo "iperf3" ;;
    htop)          echo "htop" ;;
    git-lfs)       echo "git-lfs" ;;
    cpu-x)         echo "cpu-x" ;;
    gnome-tweaks)  echo "gnome-tweaks" ;;
    code)          echo "visual-studio-code-bin" ;;  # from AUR
    google-chrome-stable) echo "google-chrome" ;;  # from AUR
    dotnet-sdk-10.0) echo "dotnet-sdk" ;;
    dotnet-sdk-9.0)  echo "dotnet-sdk" ;;
    dotnet-sdk-8.0)  echo "dotnet-sdk" ;;
    *)             echo "$1" ;;
  esac
}

native_pkg_installed() { pacman -Q "$1" &>/dev/null; }
native_install_pkg()   { sudo pacman -S --noconfirm "$1"; }
native_remove_pkg()    { sudo pacman -Rns --noconfirm "$1"; }

# Install AUR helper (yay) if not present
ensure_yay() {
  if have_cmd yay; then
    ok "yay already installed. Skipping."
    return 0
  fi
  log "Installing yay (AUR helper)..."
  local tmpdir
  tmpdir="$(mktemp -d)"
  if git clone https://aur.archlinux.org/yay.git "$tmpdir/yay" \
      && (cd "$tmpdir/yay" && makepkg -si --noconfirm); then
    ok "yay installed."
  else
    warn "yay installation failed. AUR packages will not be available."
  fi
  rm -rf "$tmpdir"
}

distro_setup_repos() {
  # Enable multilib for 32-bit libraries (needed for some apps)
  if ! grep -q '^\[multilib\]' /etc/pacman.conf; then
    log "Enabling multilib repository..."
    sudo sed -i '/^#\[multilib\]/,/^#Include = \/etc\/pacman.d\/mirrorlist/ s/^#//' /etc/pacman.conf
    sudo pacman -Sy
  else
    ok "multilib repository already enabled. Skipping."
  fi

  # Ensure AUR helper is available
  ensure_yay

  # Add Google Chrome repository (via AUR)
  if ! native_pkg_installed google-chrome; then
    log "Google Chrome will be installed from AUR via yay."
  else
    ok "Google Chrome already installed. Skipping repo setup."
  fi

  # Add VS Code repository (via AUR)
  if ! native_pkg_installed visual-studio-code-bin; then
    log "VS Code will be installed from AUR via yay."
  else
    ok "VS Code already installed. Skipping repo setup."
  fi

  # Update system
  log "Updating pacman package databases..."
  sudo pacman -Sy
}

distro_install_vulkan_deps() {
  install_pkg vulkan-headers
  install_pkg vulkan-icd-loader
  install_pkg glslc
  install_pkg glslang
  install_pkg mesa
  install_pkg lib32-mesa
}

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

# Arch has full ffmpeg in extra repo
distro_install_ffmpeg() {
  install_pkg ffmpeg
}

distro_install_dotnet() {
  if have_cmd dotnet; then
    ok ".NET SDK already installed. Skipping."
    return 0
  fi
  log "Installing .NET SDK..."
  if native_pkg_installed dotnet-sdk; then
    ok "dotnet-sdk already installed via pacman."
  else
    # Try AUR for specific version or use official installer
    if have_cmd yay; then
      yay -S --noconfirm dotnet-sdk \
        && ok ".NET SDK installed." \
        || warn ".NET SDK installation failed. Continuing."
    else
      # Fallback to Microsoft's official installer
      log "Installing .NET SDK via official installer..."
      curl -sSL https://dot.net/v1/dotnet-install.sh | bash /dev/stdin --channel 10.0 \
        && ok ".NET SDK installed." \
        || warn ".NET SDK installation failed. Continuing."
    fi
  fi
}

distro_install_dev_group() {
  # base-devel is the equivalent of build-essential / development-tools
  if native_pkg_installed base-devel; then
    ok "base-devel group already installed. Skipping."
  else
    log "Installing base-devel group..."
    sudo pacman -S --noconfirm --needed base-devel \
      && ok "base-devel group installed." \
      || warn "Could not install base-devel group."
  fi
}

distro_cleanup_extras() {
  # Disable systemd-coredump to avoid polluting benchmarks
  if systemctl list-unit-files systemd-coredump.socket &>/dev/null; then
    log "Disabling systemd-coredump..."
    sudo systemctl disable --now systemd-coredump.socket systemd-coredump@.service 2>/dev/null \
      && ok "systemd-coredump disabled." \
      || warn "Could not disable systemd-coredump."
  fi

  # Disable pkgfile-update timer (background database updates)
  if systemctl list-unit-files pkgfile-update.timer &>/dev/null; then
    log "Disabling pkgfile-update.timer..."
    sudo systemctl disable --now pkgfile-update.timer 2>/dev/null \
      && ok "pkgfile-update.timer disabled." \
      || warn "Could not disable pkgfile-update.timer."
  fi

  # Disable man-db timer (background man page index updates)
  if systemctl list-unit-files man-db.timer &>/dev/null; then
    log "Disabling man-db.timer..."
    sudo systemctl disable --now man-db.timer 2>/dev/null \
      && ok "man-db.timer disabled." \
      || warn "Could not disable man-db.timer."
  fi
}

distro_remove_libreoffice() {
  if pacman -Qs '^libreoffice' &>/dev/null; then
    log "Removing LibreOffice suite..."
    sudo pacman -Rns --noconfirm $(pacman -Qsq '^libreoffice') \
      && ok "LibreOffice removed." \
      || warn "Failed to remove LibreOffice."
  else
    ok "LibreOffice not installed. Skipping."
  fi
}

distro_open_ssh_firewall() {
  # Arch doesn't enable a firewall by default
  # Check for common firewalls
  if have_cmd ufw && sudo ufw status | grep -q 'Status: active'; then
    if sudo ufw status | grep -qw '22\|OpenSSH'; then
      ok "Firewall already allows SSH."
    else
      sudo ufw allow ssh \
        && ok "Firewall opened for SSH." \
        || warn "Could not open firewall for SSH."
    fi
  elif have_cmd firewall-cmd && systemctl is-active firewalld &>/dev/null; then
    if sudo firewall-cmd --query-service=ssh &>/dev/null; then
      ok "Firewall already allows SSH."
    else
      sudo firewall-cmd --add-service=ssh --permanent >/dev/null \
        && sudo firewall-cmd --reload >/dev/null \
        && ok "Firewall opened for SSH." \
        || warn "Could not open firewall for SSH."
    fi
  elif have_cmd iptables; then
    ok "No high-level firewall manager active; iptables allows SSH by default on Arch."
  else
    ok "No firewall configured — SSH reachable without firewall changes."
  fi
}