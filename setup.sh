#!/usr/bin/env bash
# ==============================================================================
# setup.sh — Entry point for system setup
# ==============================================================================
# Runs all setup modules in order. Can be invoked from any shell (bash, zsh,
# fish) because the OS executes it via the shebang line above — the calling
# shell doesn't matter.
#
# Usage:
#   bash setup.sh                   # full setup
#   DRY_RUN=true bash setup.sh      # preview without making changes
#   bash setup.sh --only 05         # run a single module by number
#   bash setup.sh --skip 06         # skip a module
#
# Each module is a self-contained script in modules/. They communicate through
# exported environment variables set by lib/detect.sh and lib/utils.sh.
# ==============================================================================

set -euo pipefail

# ------------------------------------------------------------------------------
# SETUP_DIR
# Resolve the directory this script lives in, regardless of where it's called
# from. All other paths are relative to this so the script works from any
# working directory.
# ------------------------------------------------------------------------------
SETUP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export SETUP_DIR

# AUR builds, mise, Flatpak, user services, SSH keys, and chezmoi must run as
# the target desktop user. Individual privileged operations use sudo.
if [[ "$EUID" -eq 0 ]]; then
    printf 'ERROR: Run this setup as your normal user, not as root or with sudo.\n' >&2
    printf 'Example: bash %s/setup.sh\n' "$SETUP_DIR" >&2
    exit 1
fi

# ------------------------------------------------------------------------------
# Source shared libraries
# Order matters: log.sh first (others call log_*), then detect.sh and utils.sh
# ------------------------------------------------------------------------------
# shellcheck source=lib/log.sh
source "$SETUP_DIR/lib/log.sh"
# shellcheck source=lib/detect.sh
source "$SETUP_DIR/lib/detect.sh"
# shellcheck source=lib/utils.sh
source "$SETUP_DIR/lib/utils.sh"

# ------------------------------------------------------------------------------
# Parse arguments
# --only <number>  run only the module matching that number prefix
# --skip <number>  skip the module matching that number prefix
# DRY_RUN=true     set before invoking to preview without changes
# ------------------------------------------------------------------------------
ONLY_MODULE=""
SKIP_MODULES=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --only)
            [[ $# -ge 2 ]] || { log_error "--only requires a module number"; exit 1; }
            ONLY_MODULE="$2"
            shift 2
            ;;
        --skip)
            [[ $# -ge 2 ]] || { log_error "--skip requires a module number"; exit 1; }
            SKIP_MODULES+=("$2")
            shift 2
            ;;
        --dry-run) DRY_RUN=true; shift ;;
        *) log_error "Unknown argument: $1"; exit 1 ;;
    esac
done

export DRY_RUN

# ------------------------------------------------------------------------------
# Banner
# ------------------------------------------------------------------------------
if [[ -t 1 && -n "${TERM:-}" ]]; then
    clear
fi
printf "${BOLD}"
cat << 'BANNER'
  ███████╗███████╗████████╗██╗   ██╗██████╗
  ██╔════╝██╔════╝╚══██╔══╝██║   ██║██╔══██╗
  ███████╗█████╗     ██║   ██║   ██║██████╔╝
  ╚════██║██╔══╝     ██║   ██║   ██║██╔═══╝
  ███████║███████╗   ██║   ╚██████╔╝██║
  ╚══════╝╚══════╝   ╚═╝    ╚═════╝ ╚═╝
BANNER
printf "${NC}"
echo ""

# ------------------------------------------------------------------------------
# Detect the system
# Populates: DISTRO_FAMILY, PKG_MANAGER, ROOT_FS, BOOTLOADER
# All modules read these exported variables — they don't re-detect themselves.
# ------------------------------------------------------------------------------
log_section "Detecting system"
detect_all

log_info "Distro:      $OS_NAME ($DISTRO_FAMILY)"
log_info "Profile:     $SYSTEM_PROFILE"
log_info "Pkg manager: $PKG_MANAGER"
log_info "Root FS:     $ROOT_FS"
log_info "Bootloader:  $BOOTLOADER"
log_info "CPU:         $CPU_VENDOR"
log_info "GPU:         $GPU_VENDOR"
log_info "Dry run:     $DRY_RUN"
log_info "Log file:    $LOG_FILE"
echo ""

# Bail out early if we can't identify the distro — better than running
# half a setup with the wrong package manager
if [[ "$DISTRO_FAMILY" == "unknown" || "$PKG_MANAGER" == "unknown" ]]; then
    log_error "Could not detect distro or package manager."
    log_error "Supported: Arch (and derivatives), Fedora, Ubuntu, Debian, macOS"
    exit 1
fi

# ------------------------------------------------------------------------------
# Confirmation prompt (skipped in dry-run mode)
# ------------------------------------------------------------------------------
if [[ "$DRY_RUN" != true ]]; then
    echo ""
    if ! ask "Detected: $OS_NAME with $PKG_MANAGER. Continue with setup?"; then
        log_info "Aborted."
        exit 0
    fi
    echo ""
fi

# ------------------------------------------------------------------------------
# run_module <path>
# Runs a single module script in the current shell (source) so it inherits all
# exported variables. Checks --only / --skip filters first.
# Exits the entire setup if a module returns a non-zero exit code.
# ------------------------------------------------------------------------------
run_module() {
    local module_path="$1"
    local module_name
    module_name="$(basename "$module_path")"
    local module_num="${module_name%%[-_]*}"   # extracts leading digits e.g. "05"

    # Apply --only filter: skip everything except the requested module
    if [[ -n "$ONLY_MODULE" && "$module_num" != "$ONLY_MODULE" ]]; then
        log_info "Skipping $module_name (--only $ONLY_MODULE)"
        return 0
    fi

    # Apply --skip filters
    local skipped
    for skipped in "${SKIP_MODULES[@]}"; do
        if [[ "$module_num" == "$skipped" ]]; then
            log_warn "Skipping $module_name (--skip $skipped)"
            return 0
        fi
    done

    log_info "Running module: $module_name"
    # Source rather than exec so modules share variables and functions
    # shellcheck source=/dev/null
    source "$module_path"
}

# ------------------------------------------------------------------------------
# Run modules in order
# Add or remove lines here to change which modules run and in what order.
# ------------------------------------------------------------------------------
run_module "$SETUP_DIR/modules/01-system.sh"
run_module "$SETUP_DIR/modules/02-repos.sh"
run_module "$SETUP_DIR/modules/03-microcode.sh"
run_module "$SETUP_DIR/modules/03-packages.sh"
run_module "$SETUP_DIR/modules/03-system-config.sh"
run_module "$SETUP_DIR/modules/10-sway-config.sh"
run_module "$SETUP_DIR/modules/04-userland.sh"
run_module "$SETUP_DIR/modules/05-github.sh"
run_module "$SETUP_DIR/modules/06-atomic.sh"
run_module "$SETUP_DIR/modules/07-proton.sh"
run_module "$SETUP_DIR/modules/08-dotfiles.sh"
run_module "$SETUP_DIR/modules/09-updates.sh"
run_module "$SETUP_DIR/modules/09-done.sh"
