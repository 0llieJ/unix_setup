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
# FAILED_PKG_FILE
# Packages that fail to install are appended here so the run can carry on and
# you can install them manually afterwards. One record per line:
#   <iso-timestamp>\t<package-manager>\t<package>\t<reason>
# Override before sourcing if you want it somewhere else.
# ------------------------------------------------------------------------------
FAILED_PKG_FILE="${FAILED_PKG_FILE:-${HOME}/failed-packages.txt}"

# ------------------------------------------------------------------------------
# record_failed_pkg <manager> <package> [reason]
# Appends a failed package to FAILED_PKG_FILE so it isn't lost when the setup
# continues past it. Safe to call repeatedly — it just appends.
# ------------------------------------------------------------------------------
record_failed_pkg() {
    local manager="$1" pkg="$2" reason="${3:-install failed}"
    local stamp
    stamp="$(date --iso-8601=seconds 2>/dev/null || date 2>/dev/null || echo unknown)"
    printf '%s\t%s\t%s\t%s\n' "$stamp" "$manager" "$pkg" "$reason" >> "$FAILED_PKG_FILE"
    log_warn "Recorded failed package '$pkg' → $FAILED_PKG_FILE"
}

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

# Returns true when systemd is the active init system, not merely installed.
has_systemd() {
    cmd_exists systemctl && [[ -d /run/systemd/system ]]
}

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
        (( ++i ))
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
# _pkg_install_cmd <package...>
# Runs the detected package manager for the given packages and returns its exit
# status. Used for both the fast batch attempt and the per-package retry below.
# -u (pacman) upgrades out-of-date deps pulled in alongside new packages,
# preventing partial upgrades that break AUR tools like paru when libalpm gets
# bumped as a transitive dependency mid-setup.
_pkg_install_cmd() {
    case "$PKG_MANAGER" in
        pacman) run_cmd sudo pacman -Syu --needed --noconfirm "$@" ;;
        dnf)    run_cmd sudo dnf install -y "$@" ;;
        apt)    run_cmd sudo apt-get install -y "$@" ;;
        brew)   run_cmd brew install "$@" ;;
        *)      log_error "Unknown package manager: $PKG_MANAGER"; return 1 ;;
    esac
}

pkg_install() {
    local packages=("$@")
    [[ ${#packages[@]} -eq 0 ]] && return 0

    # Atomic/OSTree systems have a read-only /usr — native package managers
    # (dnf/apt/pacman) can't install into the running system. Layering must go
    # through `rpm-ostree install` instead, which is intentionally out of scope
    # here. Skip and record so the caller carries on rather than erroring.
    if [[ "${SYSTEM_PROFILE:-mutable}" == "atomic" ]]; then
        log_warn "Atomic system — cannot install ${packages[*]} via $PKG_MANAGER (read-only base)"
        log_warn "Layer it manually if needed:  rpm-ostree install ${packages[*]}"
        local p
        for p in "${packages[@]}"; do
            record_failed_pkg "$PKG_MANAGER" "$p" "atomic: layer with rpm-ostree"
        done
        return 0
    fi

    confirm_packages "$PKG_MANAGER" "${packages[@]}" || {
        log_warn "Install skipped by user"
        return 0
    }

    # Fast path: install the whole batch in one transaction.
    if _pkg_install_cmd "${packages[@]}"; then
        return 0
    fi

    # Batch failed — one or more packages is bad (renamed, dropped from repos,
    # unmet deps). Retry each individually so the good ones still land, and
    # record only the genuinely failing ones for manual follow-up. Always
    # return 0 afterwards so the overall setup carries on past failures.
    log_warn "Batch install failed — retrying packages individually to isolate failures"
    local pkg failed=()
    for pkg in "${packages[@]}"; do
        if _pkg_install_cmd "$pkg"; then
            log_success "Installed: $pkg"
        else
            log_error "Failed to install: $pkg"
            record_failed_pkg "$PKG_MANAGER" "$pkg"
            failed+=("$pkg")
        fi
    done

    if [[ ${#failed[@]} -gt 0 ]]; then
        log_warn "${#failed[@]} package(s) failed — see $FAILED_PKG_FILE"
    fi
    return 0
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
    if ! has_systemd; then
        log_warn "systemd is not active, skipping unit: $unit"
        return 0
    fi
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
    if ! has_systemd; then
        log_warn "systemd is not active, skipping user unit: $unit"
        return 0
    fi
    if systemctl --user list-unit-files "$unit" &>/dev/null; then
        run_cmd systemctl --user enable --now "$unit"
    else
        log_warn "systemd user unit not found, skipping: $unit"
    fi
}
