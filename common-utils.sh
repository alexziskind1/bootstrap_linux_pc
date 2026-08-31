#!/usr/bin/env bash
#
# common-utils.sh
# Shared utility functions for ReviewPC Linux scripts.
# Detects the distro and sources the matching adapter from distro/,
# which provides the package-manager layer:
#
#   pkg_name <canonical>          -> native package name
#   native_pkg_installed <name>   -> 0 if installed
#   native_install_pkg <name>
#   native_remove_pkg <name>
#   distro_setup_repos
#   distro_install_vulkan_deps
#   distro_install_uv
#   distro_install_ffmpeg
#   distro_install_dotnet
#   distro_install_dev_group
#   distro_cleanup_extras
#   distro_remove_libreoffice
#   distro_open_ssh_firewall
#   SSH_SERVICE, CLEANUP_PKGS
#

# ---------------------------------------------------------------------------
# Colors & logging
# ---------------------------------------------------------------------------
C_RESET=$'\e[0m'
C_CYAN=$'\e[36m'
C_GREEN=$'\e[32m'
C_YELLOW=$'\e[33m'
C_RED=$'\e[31m'

ts() { date '+%Y-%m-%d %H:%M:%S'; }

log()  { echo "${C_CYAN}[${SCRIPT_PREFIX:-ReviewPC}] $(ts) - $*${C_RESET}"; }
ok()   { echo "${C_GREEN}[${SCRIPT_PREFIX:-ReviewPC}] $(ts) - $*${C_RESET}"; }
warn() { echo "${C_YELLOW}[${SCRIPT_PREFIX:-ReviewPC}] $(ts) - WARNING: $*${C_RESET}"; }
err()  { echo "${C_RED}[${SCRIPT_PREFIX:-ReviewPC}] $(ts) - ERROR: $*${C_RESET}" >&2; }

# ---------------------------------------------------------------------------
# Logging to file
# ---------------------------------------------------------------------------
start_logging() {
  local script_name="$1"
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[1]}")" && pwd)"
  local log_dir="$script_dir/logs"
  mkdir -p "$log_dir"
  LOG_PATH="$log_dir/${script_name}_$(date '+%Y%m%d_%H%M%S').log"
  exec > >(tee -a "$LOG_PATH") 2>&1
  log "Logging to $LOG_PATH"
}

# ---------------------------------------------------------------------------
# Privilege handling — run as a regular user; sudo is used internally
# ---------------------------------------------------------------------------
ensure_not_root() {
  if [[ $EUID -eq 0 ]]; then
    err "Run this script as a regular user, not root. It uses sudo internally where needed."
    exit 1
  fi
}

ensure_sudo() {
  log "Requesting sudo access (used for package installs and system config)..."
  sudo -v
  ( while kill -0 "$$" 2>/dev/null; do sudo -n true 2>/dev/null; sleep 50; done ) &
}

# ---------------------------------------------------------------------------
# Existence checks
# ---------------------------------------------------------------------------
have_cmd()          { command -v "$1" &>/dev/null; }
flatpak_installed() { flatpak info "$1" &>/dev/null; }

# ---------------------------------------------------------------------------
# Distro detection + adapter loading
# ---------------------------------------------------------------------------
COMMON_UTILS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

init_distro() {
  if [[ ! -r /etc/os-release ]]; then
    err "/etc/os-release not found — cannot detect distro."
    exit 1
  fi
  # shellcheck disable=SC1091
  source /etc/os-release
  case "${ID:-}" in
    fedora) DISTRO="fedora" ;;
    ubuntu) DISTRO="ubuntu" ;;
    arch|endeavouros|manjaro|garuda|artix) DISTRO="arch" ;;
    *)
      case "${ID_LIKE:-}" in
        *fedora*|*rhel*)   DISTRO="fedora" ;;
        *ubuntu*|*debian*) DISTRO="ubuntu" ;;
        *arch*)            DISTRO="arch" ;;
        *)
          err "Unsupported distro: ${ID:-unknown}. Supported: Fedora, Ubuntu (and derivatives), Arch (and derivatives)."
          exit 1
          ;;
      esac
      ;;
  esac
  # shellcheck disable=SC1090
  source "$COMMON_UTILS_DIR/distro/$DISTRO.sh"
  log "Detected distro: ${PRETTY_NAME:-$DISTRO} (using $DISTRO adapter)"
}

# ---------------------------------------------------------------------------
# Package install wrappers (idempotent, warn-and-continue)
# ---------------------------------------------------------------------------
install_pkg() {
  local canonical="$1"
  local native
  native="$(pkg_name "$canonical")"
  if native_pkg_installed "$native"; then
    ok "$native already installed. Skipping."
    return 0
  fi
  log "Installing $native..."
  if native_install_pkg "$native"; then
    ok "$native installed successfully."
  else
    warn "$native installation failed. Continuing."
  fi
}

install_flatpak() {
  local app_id="$1"
  if ! have_cmd flatpak; then
    warn "flatpak not available; skipping $app_id."
    return 0
  fi
  if flatpak_installed "$app_id"; then
    ok "$app_id already installed. Skipping."
    return 0
  fi
  log "Installing Flatpak $app_id..."
  if flatpak install -y --noninteractive flathub "$app_id"; then
    ok "$app_id installed successfully."
  else
    warn "$app_id installation failed. Continuing."
  fi
}

# ---------------------------------------------------------------------------
# Git configuration
# ---------------------------------------------------------------------------
set_reviewpc_git_config() {
  local user_name="$1" user_email="$2"
  if ! have_cmd git; then
    warn "git not found; skipping git configuration."
    return 0
  fi
  log "Configuring git global settings..."
  git config --global user.name "$user_name"
  git config --global user.email "$user_email"
  git config --global init.defaultBranch main
  ok "Git configured: $user_name <$user_email>"
}

# ---------------------------------------------------------------------------
# Run a child script
# ---------------------------------------------------------------------------
run_reviewpc_script() {
  local script_path="$1" script_name="$2"; shift 2
  if [[ ! -f "$script_path" ]]; then
    err "$script_name script not found at $script_path"
    return 1
  fi
  log "Running $script_name..."
  if bash "$script_path" "$@"; then
    ok "$script_name completed."
  else
    err "$script_name failed (exit $?)."
    return 1
  fi
}
