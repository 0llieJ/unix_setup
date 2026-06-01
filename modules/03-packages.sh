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
#   1. Common packages  — identical names on every distro (packages/common.txt)
#   2. Distro packages  — distro-specific names          (packages/<distro>.txt)
#   3. AUR packages     — Arch only, via paru            (packages/arch-aur.txt)
#   4. Sway ecosystem   — skipped if Sway already exists (packages/sway.txt)
#
# Depends on: 02-repos.sh (repos must be in place before installing)
# ==============================================================================

[[ -n "${_MODULE_PACKAGES_LOADED:-}" ]] && return
_MODULE_PACKAGES_LOADED=1

# PACKAGES_DIR is set relative to SETUP_DIR (exported by setup.sh)
PACKAGES_DIR="${SETUP_DIR}/packages"

# ------------------------------------------------------------------------------
# install_system_packages
# Reads the common and distro-specific package lists, merges them, and passes
# them to pkg_install() in one call. Batching into a single install command is
# faster than calling the package manager once per package.
# ------------------------------------------------------------------------------
install_system_packages() {
    log_section "System packages"

    # Read common packages (same names across all distros)
    mapfile -t common_pkgs < <(read_package_list "$PACKAGES_DIR/common.txt")

    # Read distro-specific packages based on detected family
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

    # Combine both lists and install in one pass
    local all_pkgs=("${common_pkgs[@]}" "${distro_pkgs[@]}")
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
    [[ "$DISTRO_FAMILY" != "arch" ]] && return

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

    log_info "Installing ${#aur_pkgs[@]} AUR packages via paru..."
    run_cmd paru -S --needed --noconfirm --skipreview "${aur_pkgs[@]}"

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
    # Check for either sway or swayfx — both satisfy the "desktop is present" condition
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

    install_system_packages
    install_aur_packages
    install_sway_packages

    log_success "Module 03 complete"
}

main "$@"
