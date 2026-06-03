#!/usr/bin/env bash
# ==============================================================================
# modules/02-repair-paru.sh — Rebuild paru after a pacman/libalpm upgrade
# ==============================================================================
# Run this when paru fails with:
#   "error while loading shared libraries: libalpm.so.XX: cannot open shared
#    object file: No such file or directory"
#
# WHY THIS HAPPENS:
#   paru is an AUR helper — it installs packages from the Arch User Repository.
#   paru-bin is a pre-compiled binary that links against libalpm (part of pacman).
#   When pacman upgrades libalpm to a new version (e.g. .so.15 → .so.16), the
#   paru binary can no longer load and is immediately broken. paru can't fix
#   itself because it can't even start.
#
# WHAT THIS SCRIPT DOES:
#   Step 1 — Remove the broken paru and reinstall paru-bin fresh.
#            Reinstalling over the top reuses the cached binary (still broken).
#            Removing first forces a clean download of the latest binary.
#
#   Step 2 — If paru-bin is still broken, the AUR maintainer hasn't updated
#            the pre-compiled binary for the new libalpm yet. In this case
#            paru is compiled from source against the current libalpm.
#            This is a one-time compile that takes a few minutes.
#            Once the AUR maintainer ships an updated binary, future installs
#            will go back to using paru-bin automatically.
#
# Usage:
#   bash ~/unix_setup/modules/02-repair-paru.sh
#
# After it completes:
#   paru --version                          — verify it works
#   bash ~/unix_setup/setup.sh --only 03   — continue setup
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

    # Check whether paru is actually broken before doing anything.
    # If it works fine (e.g. already repaired via source build), exit cleanly.
    local paru_err
    paru_err=$(paru --version 2>&1) || true

    if ! echo "$paru_err" | grep -q "cannot open shared object file"; then
        if cmd_exists paru; then
            log_success "paru is working correctly — no repair needed"
            paru --version
        else
            log_info "paru is not installed — run setup.sh to install it"
        fi
        return 0
    fi

    log_warn "Broken paru detected: $paru_err"
    echo ""

    # Ensure build tools are present for both paths below
    run_cmd sudo pacman -S --needed --noconfirm base-devel git

    # ── Step 1: remove and reinstall paru-bin ─────────────────────────────────
    log_section "Step 1 — Reinstalling paru-bin"

    log_info "Removing all paru variants (forces clean download, not cached binary)..."
    # Remove each variant individually — pacman errors if a package isn't installed,
    # so we suppress per-package errors rather than silencing the whole command.
    for pkg in paru paru-bin paru-bin-debug paru-debug; do
        if pacman -Q "$pkg" &>/dev/null; then
            run_cmd sudo pacman -Rns --noconfirm "$pkg"
        fi
    done

    log_info "Upgrading system so libalpm is at latest before reinstalling..."
    run_cmd sudo pacman -Syu --noconfirm

    log_info "Downloading and installing paru-bin fresh from AUR..."
    local tmpdir
    tmpdir=$(mktemp -d)
    git clone --depth=1 https://aur.archlinux.org/paru-bin.git "$tmpdir/paru-bin"
    (cd "$tmpdir/paru-bin" && makepkg -si --noconfirm)
    rm -rf "$tmpdir"

    local new_version
    new_version=$(paru --version 2>&1) || true
    if ! echo "$new_version" | grep -q "cannot open shared object file"; then
        log_success "paru-bin reinstalled successfully: $new_version"
        log_info "Continue setup with: bash ~/unix_setup/setup.sh --only 03"
        return 0
    fi

    # ── Step 2: compile from source ───────────────────────────────────────────
    # paru-bin is still broken. The AUR maintainer hasn't updated the
    # pre-compiled binary for the current libalpm version yet.
    # Compiling from source links against whatever libalpm is installed now.
    # This is a one-time compile — once the maintainer ships an updated binary
    # the script will use paru-bin again on future runs.
    log_section "Step 2 — Compiling paru from source (paru-bin not updated yet)"
    echo ""
    log_warn "The paru-bin pre-compiled binary is still linked against the old libalpm."
    log_warn "The AUR maintainer hasn't released an updated binary yet."
    log_warn "Compiling paru from source so it links against the current libalpm."
    log_warn "This takes a few minutes and only needs to happen once."
    log_warn "Check https://aur.archlinux.org/packages/paru-bin for when it gets updated."
    echo ""

    run_cmd sudo pacman -S --needed --noconfirm rust

    # Ensure all paru-bin variants are gone before installing paru (they conflict)
    for pkg in paru-bin paru-bin-debug; do
        if pacman -Q "$pkg" &>/dev/null; then
            log_info "Removing $pkg before source build (packages conflict)..."
            run_cmd sudo pacman -Rns --noconfirm "$pkg"
        fi
    done

    tmpdir=$(mktemp -d)
    log_info "Cloning paru source from AUR..."
    git clone --depth=1 https://aur.archlinux.org/paru.git "$tmpdir/paru"
    log_info "Compiling paru (this takes a few minutes)..."
    (cd "$tmpdir/paru" && makepkg -si --noconfirm)
    rm -rf "$tmpdir"

    new_version=$(paru --version 2>&1) || true
    if echo "$new_version" | grep -q "cannot open shared object file"; then
        log_error "Both reinstall and source build failed — something else is wrong."
        log_error "Check: pacman -Q libalpm  and  ldd \$(which paru)"
        return 1
    fi

    log_success "paru compiled from source successfully: $new_version"
    log_info "Continue setup with: bash ~/unix_setup/setup.sh --only 03"
}

main "$@"
