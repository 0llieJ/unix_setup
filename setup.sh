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
SKIP_MODULE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --only) ONLY_MODULE="$2"; shift 2 ;;
        --skip) SKIP_MODULE="$2"; shift 2 ;;
        --dry-run) DRY_RUN=true; shift ;;
        *) log_error "Unknown argument: $1"; exit 1 ;;
    esac
done

export DRY_RUN

# ------------------------------------------------------------------------------
# Banner
# ------------------------------------------------------------------------------
clear
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

    # Apply --skip filter
    if [[ -n "$SKIP_MODULE" && "$module_num" == "$SKIP_MODULE" ]]; then
        log_warn "Skipping $module_name (--skip $SKIP_MODULE)"
        return 0
    fi

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
run_module "$SETUP_DIR/modules/03-packages.sh"
run_module "$SETUP_DIR/modules/04-userland.sh"
run_module "$SETUP_DIR/modules/05-github.sh"
run_module "$SETUP_DIR/modules/06-atomic.sh"
run_module "$SETUP_DIR/modules/07-proton.sh"
run_module "$SETUP_DIR/modules/08-dotfiles.sh"
run_module "$SETUP_DIR/modules/09-done.sh"
