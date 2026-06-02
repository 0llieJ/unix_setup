#!/usr/bin/env bash
# ==============================================================================
# modules/02-repair-paru.sh — Rebuild paru after a pacman/libalpm upgrade
# ==============================================================================
# Run this when paru fails with:
#   "error while loading shared libraries: libalpm.so.XX: cannot open shared
#    object file: No such file or directory"
#
# This happens when pacman upgrades libalpm to a new version but the paru
# binary was compiled against the old version. paru can't fix itself because
# it can't load — this script does the rebuild using only makepkg and pacman.
#
# Usage:
#   bash ~/unix_setup/modules/02-repair-paru.sh
#
# After it completes, verify with: paru --version
# Then continue setup:            bash ~/unix_setup/setup.sh --only 03
# ==============================================================================

[[ -n "${_MODULE_REPAIR_PARU_LOADED:-}" ]] && return
_MODULE_REPAIR_PARU_LOADED=1

if [[ -z "${SETUP_DIR:-}" ]]; then
    SETUP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    source "$SETUP_DIR/lib/log.sh"
    source "$SETUP_DIR/lib/detect.sh"
    source "$SETUP_DIR/lib/utils.sh"
    detect_all
fi

main() {
    log_section "Repair paru (libalpm mismatch)"

    if [[ "$DISTRO_FAMILY" != "arch" ]]; then
        log_info "Not an Arch-based system — paru is only used on Arch. Nothing to do."
        return 0
    fi

    # Check whether paru is actually broken before doing anything
    local paru_err
    paru_err=$(paru --version 2>&1) || true

    if ! echo "$paru_err" | grep -q "cannot open shared object file"; then
        # paru ran successfully — either it's fine or it's not installed
        if cmd_exists paru; then
            log_success "paru is working correctly — no repair needed"
            paru --version
        else
            log_info "paru is not installed — run setup.sh to install it"
        fi
        return 0
    fi

    log_warn "Broken paru detected: $paru_err"

    # Ensure build tools are available
    run_cmd sudo pacman -S --needed --noconfirm base-devel git

    # Remove the broken paru completely.
    # Reinstalling over the top reuses the cached binary which is still linked
    # against the old libalpm. Removing first forces a clean download.
    log_info "Removing broken paru..."
    run_cmd sudo pacman -Rns --noconfirm paru paru-bin paru-bin-debug 2>/dev/null || true

    # Upgrade the full system so libalpm is at the latest version before
    # the new paru-bin is downloaded and installed against it.
    log_info "Upgrading system to latest libalpm..."
    run_cmd sudo pacman -Syu --noconfirm

    # Reinstall paru-bin fresh — the new download will be compiled against
    # the current libalpm version.
    log_info "Reinstalling paru-bin from AUR..."
    local tmpdir
    tmpdir=$(mktemp -d)
    git clone --depth=1 https://aur.archlinux.org/paru-bin.git "$tmpdir/paru-bin"
    (cd "$tmpdir/paru-bin" && makepkg -si --noconfirm)
    rm -rf "$tmpdir"

    # Verify it works
    local new_version
    new_version=$(paru --version 2>&1) || true
    if echo "$new_version" | grep -q "cannot open shared object file"; then
        log_error "paru is still broken after reinstall."
        log_error "The AUR maintainer may not have updated paru-bin for the current libalpm yet."
        log_error "Check https://aur.archlinux.org/packages/paru-bin for the latest build date."
        log_error "Try again in a few hours when the package has been updated."
        return 1
    fi

    log_success "paru reinstalled successfully: $new_version"
    log_info "Continue setup with: bash ~/unix_setup/setup.sh --only 03"
}

main "$@"
