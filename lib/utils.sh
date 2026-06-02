#!/usr/bin/env bash
# ==============================================================================
# lib/utils.sh — Shared utility functions
# ==============================================================================
# General-purpose helpers used across every module.
# Source this file from any module — do not execute it directly.
#
# Depends on: lib/log.sh (must be sourced first for log_* functions)
# ==============================================================================

# ------------------------------------------------------------------------------
# DRY_RUN
# When set to true (e.g. DRY_RUN=true ./setup.sh), no commands that change
# system state are executed. Instead, run_cmd() prints what it would have run.
# Useful for previewing a setup on an existing machine without touching anything.
# ------------------------------------------------------------------------------
DRY_RUN="${DRY_RUN:-false}"

# ------------------------------------------------------------------------------
# cmd_exists <command>
# Returns 0 (true) if the command is available in $PATH, 1 otherwise.
# Used throughout modules to check whether something is already installed
# before trying to install or configure it.
#
# Example:
#   cmd_exists paru && paru -S --needed foo
# ------------------------------------------------------------------------------
cmd_exists() { command -v "$1" &>/dev/null; }

# ------------------------------------------------------------------------------
# run_cmd <command> [args...]
# The standard way to run any command that changes system state.
# - In normal mode:  logs the command then executes it.
# - In dry-run mode: logs what would have run but does nothing.
#
# Always use run_cmd for installs, service changes, and file writes so that
# dry-run mode gives a complete preview of what the script would do.
#
# Example:
#   run_cmd sudo pacman -S --needed --noconfirm git
# ------------------------------------------------------------------------------
run_cmd() {
    if [[ "$DRY_RUN" == true ]]; then
        log_info "[DRY-RUN] $*"
        return 0
    fi
    log_info "Running: $*"
    "$@"
}

# ------------------------------------------------------------------------------
# read_package_list <file>
# Reads a plain-text package list file and prints one package name per line,
# stripping comments (lines starting with #) and blank lines.
# The first word on each line is used — this allows inline comments like:
#   git   # version control
#
# Example:
#   mapfile -t pkgs < <(read_package_list "$PACKAGES_DIR/arch.txt")
# ------------------------------------------------------------------------------
read_package_list() {
    local file="$1"
    if [[ ! -f "$file" ]]; then
        log_warn "Package list not found: $file"
        return
    fi
    # grep -v strips comment and blank lines; awk '{print $1}' takes only the
    # first word so inline comments after package names are ignored.
    grep -v '^\s*#' "$file" | grep -v '^\s*$' | awk '{print $1}'
}

# ------------------------------------------------------------------------------
# confirm_packages <label> <package> [package...]
# Prints the list of packages about to be installed and asks once for
# confirmation before proceeding. The user sees everything upfront and
# approves the whole batch with one keypress — no per-package prompts.
#
# Returns 1 (skip install) if the user says no.
# In DRY_RUN mode the prompt is skipped and the list is just printed.
#
# Example:
#   confirm_packages "system packages" git curl rsync || return
# ------------------------------------------------------------------------------
confirm_packages() {
    local label="$1"
    shift
    local packages=("$@")
    [[ ${#packages[@]} -eq 0 ]] && return 0

    echo ""
    printf "${BOLD}  Packages to install (%s — %d total):${NC}\n" "$label" "${#packages[@]}"
    echo ""

    # Print in columns of 4 so long lists are readable
    local i=0
    for pkg in "${packages[@]}"; do
        printf "    %-30s" "$pkg"
        (( i++ ))
        (( i % 4 == 0 )) && echo ""
    done
    # Final newline if the last row wasn't complete
    (( i % 4 != 0 )) && echo ""
    echo ""

    if [[ "$DRY_RUN" == true ]]; then
        log_info "[DRY-RUN] Would install ${#packages[@]} packages"
        return 0
    fi

    ask "Install these ${#packages[@]} packages?" y
}

# ------------------------------------------------------------------------------
# pkg_install <package> [package...]
# Installs one or more system packages using whatever package manager was
# detected by detect_pkg_manager() in lib/detect.sh.
#
# Shows the package list and asks for confirmation once before installing.
# Uses --needed / --no-reinstall flags so re-running on an existing machine
# is safe — already-installed packages are skipped automatically.
#
# Example:
#   pkg_install git curl rsync
# ------------------------------------------------------------------------------
pkg_install() {
    local packages=("$@")
    [[ ${#packages[@]} -eq 0 ]] && return

    confirm_packages "$PKG_MANAGER" "${packages[@]}" || {
        log_warn "Install skipped by user"
        return 0
    }

    case "$PKG_MANAGER" in
        # -u upgrades any out-of-date deps pulled in alongside new packages,
        # preventing partial upgrades that break AUR tools like paru when
        # libalpm gets bumped as a transitive dependency mid-setup.
        pacman) run_cmd sudo pacman -Syu --needed --noconfirm "${packages[@]}" ;;
        dnf)    run_cmd sudo dnf install -y "${packages[@]}" ;;
        apt)    run_cmd sudo apt-get install -y "${packages[@]}" ;;
        brew)   run_cmd brew install "${packages[@]}" ;;
        *)      log_error "Unknown package manager: $PKG_MANAGER"; return 1 ;;
    esac
}

# ------------------------------------------------------------------------------
# ask <prompt> [default]
# Prints a yes/no prompt and returns 0 for yes, 1 for no.
# The default (y or n) is used when the user just presses Enter.
# Used in modules that have optional or destructive steps.
#
# Example:
#   ask "Set up Proton Drive mount?" && setup_proton_drive
# ------------------------------------------------------------------------------
ask() {
    local prompt="$1" default="${2:-y}"
    local yn_hint
    [[ "$default" == "y" ]] && yn_hint="[Y/n]" || yn_hint="[y/N]"
    read -r -p "$(printf "${BOLD}%s %s: ${NC}" "$prompt" "$yn_hint")" answer
    answer="${answer:-$default}"
    [[ "$answer" =~ ^[Yy] ]]
}

# ------------------------------------------------------------------------------
# systemd_enable <unit>
# Enables and immediately starts a system-level (root) systemd unit.
# Checks the unit exists before attempting to enable it so the script doesn't
# fail on systems where a service wasn't installed.
#
# Example:
#   systemd_enable libvirtd
# ------------------------------------------------------------------------------
systemd_enable() {
    local unit="$1"
    if systemctl list-unit-files "$unit" &>/dev/null; then
        run_cmd sudo systemctl enable --now "$unit"
    else
        log_warn "systemd unit not found, skipping: $unit"
    fi
}

# ------------------------------------------------------------------------------
# systemd_enable_user <unit>
# Same as systemd_enable but for user-level (--user) systemd units.
# User units run as the current user rather than root — used for things like
# the Proton Drive rclone mount and Flatpak auto-update timers.
#
# Example:
#   systemd_enable_user rclone-proton.service
# ------------------------------------------------------------------------------
systemd_enable_user() {
    local unit="$1"
    if systemctl --user list-unit-files "$unit" &>/dev/null; then
        run_cmd systemctl --user enable --now "$unit"
    else
        log_warn "systemd user unit not found, skipping: $unit"
    fi
}
