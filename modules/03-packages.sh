#!/usr/bin/env bash
# ==============================================================================
# modules/03-packages.sh — System package installation
# ==============================================================================
# Installs software that needs root / system-level access using the native
# package manager (pacman, dnf, or apt).
#
# Package lists live in setup/packages/ as plain text files — one package name
# per line, comments allowed with #. This keeps the package decisions readable
# and easy to edit without touching script logic.
#
# Install order within this module:
#   1. Conflict resolution — checks for packages that can't coexist, asks you
#                            which to keep before anything is installed
#   2. Common packages    — identical names on every distro (packages/common.txt)
#   3. Distro packages    — distro-specific names          (packages/<distro>.txt)
#   4. AUR packages       — Arch only, via paru            (packages/arch-aur.txt)
#   5. Sway ecosystem     — skipped if Sway already exists (packages/sway.txt)
#
# Depends on: 02-repos.sh (repos must be in place before installing)
# ==============================================================================

[[ -n "${_MODULE_PACKAGES_LOADED:-}" ]] && return
_MODULE_PACKAGES_LOADED=1

PACKAGES_DIR="${SETUP_DIR}/packages"

# ==============================================================================
# KNOWN CONFLICTS
# ==============================================================================
# Each entry is a pair: INSTALLED_PKG WANTED_PKG REASON
# If INSTALLED_PKG is found on the system, the user is asked whether to remove
# it before WANTED_PKG is installed. Without removal, the package manager will
# refuse to install the wanted package and the whole install step fails.
#
# Format: "installed_pkg|wanted_pkg|reason"
#
# To add a new conflict pair, append a line here — no other changes needed.
# ==============================================================================
KNOWN_CONFLICTS=(
    # jack2 and pipewire-jack both provide the JACK audio API. Our package list
    # installs pipewire-jack (PipeWire's JACK implementation). If jack2 is
    # already installed, pacman refuses to install pipewire-jack.
    "jack2|pipewire-jack|Both provide the JACK audio API. pipewire-jack is the PipeWire implementation and is preferred with a modern PipeWire audio stack."

    # CachyOS ships cachyos-snapper-support which conflicts with the vanilla
    # snapper package. It's a CachyOS-specific wrapper — we want plain snapper
    # so our Snapper config (module 06) works the same on all Arch derivatives.
    "cachyos-snapper-support|snapper|CachyOS ships its own snapper wrapper that conflicts with vanilla snapper. Removing it lets us manage snapper config directly."
)

# ------------------------------------------------------------------------------
# resolve_conflicts
# Checks each known conflict pair. If the installed package is present, prints
# a clear explanation of what conflicts and why, then asks you to choose:
#   - Remove the installed package and continue (recommended in most cases)
#   - Keep it and skip installing the wanted package
#   - Abort setup entirely
#
# This runs BEFORE any package installs so you see all conflicts upfront
# rather than hitting a cryptic package manager error halfway through.
# ------------------------------------------------------------------------------
resolve_conflicts() {
    [[ "$DISTRO_FAMILY" != "arch" ]] && return

    log_section "Conflict check"

    local any_found=false

    for entry in "${KNOWN_CONFLICTS[@]}"; do
        local installed wanted reason
        IFS='|' read -r installed wanted reason <<< "$entry"

        # Check if the conflicting package is currently installed
        if pacman -Q "$installed" &>/dev/null; then
            any_found=true
            echo ""
            log_warn "Conflict detected: $installed"
            echo ""
            echo "  Installed : $installed"
            echo "  Wanted    : $wanted"
            echo "  Why       : $reason"
            echo ""

            if [[ "$DRY_RUN" == true ]]; then
                log_info "[DRY-RUN] Would ask whether to remove $installed"
                continue
            fi

            # Present three options — default is to remove (recommended path)
            echo "  What would you like to do?"
            echo "    1) Remove $installed and install $wanted  (recommended)"
            echo "    2) Keep $installed and skip $wanted"
            echo "    3) Abort setup"
            echo ""
            read -r -p "  Choice [1/2/3] (default: 1): " choice
            choice="${choice:-1}"
            echo ""

            case "$choice" in
                1)
                    log_info "Removing $installed..."
                    run_cmd sudo pacman -Rns --noconfirm "$installed" 2>/dev/null || \
                        log_warn "Could not remove $installed — it may not have been fully installed"
                    log_success "$installed removed"
                    ;;
                2)
                    log_warn "Keeping $installed — $wanted will be skipped during install"
                    # Mark the wanted package to be excluded by adding it to a
                    # skip list that install_system_packages checks
                    CONFLICT_SKIPPED_PKGS+=("$wanted")
                    ;;
                3)
                    log_error "Aborted by user."
                    exit 1
                    ;;
                *)
                    log_warn "Unrecognised choice '$choice' — defaulting to option 1 (remove $installed)"
                    run_cmd sudo pacman -Rns --noconfirm "$installed" 2>/dev/null || true
                    ;;
            esac
        fi
    done

    if [[ "$any_found" == false ]]; then
        log_success "No conflicts found"
    fi
}

# Packages the user chose to keep instead of replacing — excluded from install
CONFLICT_SKIPPED_PKGS=()

# ------------------------------------------------------------------------------
# install_system_packages
# Reads the common and distro-specific package lists, merges them, removes any
# packages the user chose to skip during conflict resolution, and installs in
# one pass. Batching into a single install command is faster than calling the
# package manager once per package.
# ------------------------------------------------------------------------------
install_system_packages() {
    log_section "System packages"

    mapfile -t common_pkgs < <(read_package_list "$PACKAGES_DIR/common.txt")

    # macOS uses Homebrew for everything — formulae are installed in 04-userland.sh
    # alongside casks. Nothing to do here for system packages on macOS.
    if [[ "$DISTRO_FAMILY" == "macos" ]]; then
        log_info "macOS: system packages handled by Homebrew in module 04 — skipping"
        return
    fi

    local distro_list
    case "$DISTRO_FAMILY" in
        arch)          distro_list="$PACKAGES_DIR/arch.txt"   ;;
        fedora)        distro_list="$PACKAGES_DIR/fedora.txt" ;;
        ubuntu)        distro_list="$PACKAGES_DIR/ubuntu.txt" ;;
        debian)        distro_list="$PACKAGES_DIR/debian.txt" ;;
        *)
            log_warn "No distro-specific package list for '$DISTRO_FAMILY'"
            distro_list=""
            ;;
    esac

    mapfile -t distro_pkgs < <(read_package_list "$distro_list")

    # On Fedora, install the development tools group first. This provides gcc,
    # make, autoconf etc. — the equivalent of Arch's base-devel.
    if [[ "$DISTRO_FAMILY" == "fedora" ]]; then
        log_info "Installing Fedora development tools group..."
        run_cmd sudo dnf group install -y development-tools c-development
    fi

    # Build the final package list, excluding anything the user chose to skip
    local all_pkgs=()
    for pkg in "${common_pkgs[@]}" "${distro_pkgs[@]}"; do
        local skip=false
        for skipped in "${CONFLICT_SKIPPED_PKGS[@]}"; do
            [[ "$pkg" == "$skipped" ]] && skip=true && break
        done
        if [[ "$skip" == true ]]; then
            log_info "Skipping $pkg (conflict resolution choice)"
        else
            all_pkgs+=("$pkg")
        fi
    done

    if [[ ${#all_pkgs[@]} -gt 0 ]]; then
        log_info "Installing ${#all_pkgs[@]} system packages..."
        pkg_install "${all_pkgs[@]}"
    fi

    log_success "System packages installed"
}

# ------------------------------------------------------------------------------
# install_aur_packages
# Arch only. Uses paru (installed by 02-repos.sh) to install packages from the
# AUR (Arch User Repository) — community-maintained packages not in the
# official repos.
#
# --skipreview skips the PKGBUILD review prompt so the install is non-interactive.
# This is intentional for an automated setup; review PKGBUILDs manually on
# sensitive machines.
# ------------------------------------------------------------------------------
install_aur_packages() {
    [[ "$DISTRO_FAMILY" != "arch" ]] && return  # AUR is Arch-only; macOS/Fedora/etc. skip

    log_section "AUR packages"

    if ! cmd_exists paru; then
        log_error "paru not found — did module 02-repos.sh run successfully?"
        return 1
    fi

    mapfile -t aur_pkgs < <(read_package_list "$PACKAGES_DIR/arch-aur.txt")

    if [[ ${#aur_pkgs[@]} -eq 0 ]]; then
        log_info "No AUR packages listed, skipping"
        return
    fi

    confirm_packages "AUR" "${aur_pkgs[@]}" || {
        log_warn "AUR install skipped by user"
        return 0
    }

    if ! run_cmd paru -S --needed --noconfirm --skipreview "${aur_pkgs[@]}"; then
        # Check if the failure was a shared library error (broken paru after pacman upgrade)
        local paru_err
        paru_err=$(paru --version 2>&1) || true
        if echo "$paru_err" | grep -q "cannot open shared object file"; then
            log_error "paru is broken — libalpm was upgraded and paru needs rebuilding."
            log_error "Fix it by running:"
            log_error "  bash ~/unix_setup/modules/02-repair-paru.sh"
            log_error "Then re-run:  bash ~/unix_setup/setup.sh --only 03"
        else
            log_error "paru install failed. Check the output above for details."
        fi
        return 1
    fi

    log_success "AUR packages installed"
}

# ------------------------------------------------------------------------------
# install_sway_packages
# Installs the Sway Wayland compositor ecosystem. Skipped if sway or swayfx is
# already installed — allows re-running setup on an existing machine without
# reinstalling the desktop environment.
#
# On Arch, swayfx (AUR) is installed instead of plain sway — it's a drop-in
# fork with visual extras (rounded corners, blur, shadows). The sway entry in
# sway.txt is still installed on non-Arch distros where swayfx isn't packaged.
#
# Sway packages are in a separate file because they're optional — the same
# setup script should work on a headless server where no desktop is wanted.
# ------------------------------------------------------------------------------
install_sway_packages() {
    # Sway is Linux-only — no Wayland compositor on macOS
    [[ "$DISTRO_FAMILY" == "macos" ]] && return

    if cmd_exists sway || cmd_exists swayfx; then
        log_info "Sway/SwayFX already installed, skipping Sway ecosystem packages"
        return
    fi

    log_section "Sway ecosystem"

    mapfile -t sway_pkgs < <(read_package_list "$PACKAGES_DIR/sway.txt")

    if [[ ${#sway_pkgs[@]} -eq 0 ]]; then
        log_info "No Sway packages listed, skipping"
        return
    fi

    log_info "Installing ${#sway_pkgs[@]} Sway packages..."
    pkg_install "${sway_pkgs[@]}"

    log_success "Sway packages installed"
}

# ------------------------------------------------------------------------------
# main
# ------------------------------------------------------------------------------
main() {
    log_section "Module 03: System Packages"

    resolve_conflicts
    install_system_packages
    install_aur_packages
    install_sway_packages

    log_success "Module 03 complete"
}

main "$@"
