#!/usr/bin/env bash
# ==============================================================================
# modules/04-userland.sh — Userland tool installation
# ==============================================================================
# Installs everything that lives in the user's home directory rather than at
# the system level. No root access required after this module runs.
#
# Install order (matches the priority defined in the GOAL):
#   1. mise     — language runtimes and CLI tools (ripgrep, fzf, lazygit, etc.)
#   2. Flatpak  — sandboxed GUI applications (Zed, Bitwarden, Signal, etc.)
#   3. Homebrew — tools not available in mise or Flatpak (nushell, sshs, etc.)
#
# Why this order?
#   mise is checked first because it provides the most up-to-date versions and
#   is distro-agnostic. Flatpak covers GUI apps that mise can't handle. Homebrew
#   fills the remaining gaps for CLI tools that aren't in mise's registry.
#
# Depends on: 03-packages.sh (flatpak and curl must be installed first)
# ==============================================================================

[[ -n "${_MODULE_USERLAND_LOADED:-}" ]] && return
_MODULE_USERLAND_LOADED=1

PACKAGES_DIR="${SETUP_DIR}/packages"

# ------------------------------------------------------------------------------
# install_mise
# mise (pronounced "meez") is a polyglot runtime manager — it installs language
# runtimes (Python, Go, Rust, Node, Lua) and CLI tools without needing root.
# Everything lands in ~/.local/share/mise and is activated via shell hooks.
#
# If mise isn't already installed, it's fetched via the official install script
# from mise.run. The script adds mise to ~/.local/bin.
#
# Manifest selection, in priority order:
#   MISE_PACKAGES_FILE, mise-atomic.txt, mise-<distro>.txt, mise.txt
# ------------------------------------------------------------------------------
install_mise() {
    log_section "mise (language runtimes + CLI tools)"

    local mise_packages_file
    if [[ -n "${MISE_PACKAGES_FILE:-}" ]]; then
        mise_packages_file="$MISE_PACKAGES_FILE"
    elif [[ "$SYSTEM_PROFILE" == "atomic" && -f "$PACKAGES_DIR/mise-atomic.txt" ]]; then
        mise_packages_file="$PACKAGES_DIR/mise-atomic.txt"
    elif [[ -f "$PACKAGES_DIR/mise-${DISTRO_FAMILY}.txt" ]]; then
        mise_packages_file="$PACKAGES_DIR/mise-${DISTRO_FAMILY}.txt"
    else
        mise_packages_file="$PACKAGES_DIR/mise.txt"
    fi

    if [[ ! -f "$mise_packages_file" ]]; then
        log_error "mise package manifest not found: $mise_packages_file"
        return 1
    fi

    log_info "mise manifest: $mise_packages_file"

    # Install mise itself if not already present
    if ! cmd_exists mise; then
        log_info "Installing mise..."
        run_cmd bash -c "curl https://mise.run | sh"
    else
        log_info "mise already installed at $(command -v mise)"
    fi

    # Resolve the mise binary path (it may not be in $PATH yet in a fresh shell)
    local mise_bin
    mise_bin="${HOME}/.local/bin/mise"
    if [[ ! -x "$mise_bin" ]]; then
        local existing_mise
        existing_mise="$(command -v mise 2>/dev/null || true)"
        if [[ -n "$existing_mise" ]]; then
            mise_bin="$existing_mise"
        elif [[ "$DRY_RUN" != true ]]; then
            mise_bin=""
        fi
    fi

    if [[ -z "$mise_bin" ]]; then
        log_error "mise binary not found after install — check ~/.local/bin is in PATH"
        return 1
    fi

    # Install each tool listed in the selected manifest.
    # Format per line: <tool>@<version>  e.g.  python@3.12  or  ripgrep@latest
    log_info "Installing mise tools from $(basename "$mise_packages_file")..."
    while IFS= read -r tool; do
        [[ -z "$tool" ]] && continue
        log_info "mise: installing $tool"
        run_cmd "$mise_bin" use --global "$tool"
    done < <(read_package_list "$mise_packages_file")

    log_success "mise tools installed"
}

# ------------------------------------------------------------------------------
# install_flatpak
# Flatpak provides sandboxed GUI applications that work across all distros.
# Flathub is the main registry — it's added as a remote if not already present.
#
# App list comes from packages/flatpak.txt — one Flatpak app ID per line.
# e.g. dev.zed.Zed, com.bitwarden.desktop
# ------------------------------------------------------------------------------
install_flatpak() {
    log_section "Flatpak (GUI applications)"

    # Flatpak is Linux-only. On macOS, GUI apps are installed as Homebrew casks
    # by install_macos_casks() below.
    if [[ "$DISTRO_FAMILY" == "macos" ]]; then
        log_info "macOS: GUI apps installed as Homebrew casks — skipping Flatpak"
        return
    fi

    if ! cmd_exists flatpak; then
        log_warn "flatpak binary not found — was it installed by 03-packages.sh?"
        return
    fi

    # Add Flathub as a remote if it isn't already registered
    if ! flatpak remotes --user | grep -q "flathub"; then
        log_info "Adding Flathub remote..."
        run_cmd flatpak remote-add --user --if-not-exists flathub \
            https://dl.flathub.org/repo/flathub.flatpakrepo
    else
        log_info "Flathub remote already configured"
    fi

    # Install each app from the list
    mapfile -t flatpak_apps < <(read_package_list "$PACKAGES_DIR/flatpak.txt")

    if [[ ${#flatpak_apps[@]} -eq 0 ]]; then
        log_info "No Flatpak apps listed, skipping"
        return
    fi

    confirm_packages "Flatpak" "${flatpak_apps[@]}" || {
        log_warn "Flatpak install skipped by user"
        return 0
    }

    run_cmd flatpak install --user -y --noninteractive flathub "${flatpak_apps[@]}"

    log_info "Flatpak updates are handled by the weekly update timer in module 09"

    log_success "Flatpak apps installed"
}

# ------------------------------------------------------------------------------
# install_homebrew
# Homebrew (Linuxbrew) provides formulae that aren't in mise's registry and
# aren't suitable for Flatpak (CLI-only tools). On Linux it installs to
# /home/linuxbrew/.linuxbrew and doesn't require root for formula installs.
#
# Note: Linux Homebrew does NOT support casks (GUI app bundles) — those are
# macOS-only. All GUI apps should go in the Flatpak list instead.
#
# Formula list comes from packages/homebrew.txt.
# ------------------------------------------------------------------------------
install_homebrew() {
    log_section "Homebrew (formulae)"

    # Arch has everything in pacman/AUR — Homebrew on Linux is unsupported
    # and requires sudo to create /home/linuxbrew. Skip it entirely.
    if [[ "$DISTRO_FAMILY" == "arch" ]]; then
        log_info "Arch detected — all Homebrew packages are available via pacman/AUR, skipping"
        return
    fi

    # Install Homebrew itself if missing
    if ! cmd_exists brew; then
        log_info "Installing Homebrew (Linuxbrew)..."
        run_cmd bash -c \
            'NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"'
    else
        log_info "Homebrew already installed at $(command -v brew)"
    fi

    # Resolve brew binary — Linuxbrew installs to a non-standard prefix
    local brew_bin
    brew_bin="$(command -v brew 2>/dev/null \
        || echo "/home/linuxbrew/.linuxbrew/bin/brew")"

    if [[ ! -x "$brew_bin" && "$DRY_RUN" == true ]]; then
        log_info "[DRY-RUN] brew is expected at $brew_bin after installation"
    elif [[ ! -x "$brew_bin" ]]; then
        log_error "brew binary not found after install"
        return 1
    fi

    mapfile -t brew_formulae < <(read_package_list "$PACKAGES_DIR/homebrew.txt")

    if [[ ${#brew_formulae[@]} -eq 0 ]]; then
        log_info "No Homebrew formulae listed, skipping"
        return
    fi

    confirm_packages "Homebrew formulae" "${brew_formulae[@]}" || {
        log_warn "Homebrew formula install skipped by user"
        return 0
    }

    run_cmd "$brew_bin" install "${brew_formulae[@]}"
    log_success "Homebrew formulae installed"
}

# ------------------------------------------------------------------------------
# install_macos_casks
# macOS only. Installs GUI applications as Homebrew casks from
# packages/macos-casks.txt. Casks are macOS app bundles (.app) distributed
# via Homebrew — the macOS equivalent of Flatpak apps.
#
# Unlike formulae (CLI tools), casks require macOS and cannot be installed
# on Linux. The cask list is intentionally separate from homebrew.txt so
# the two platforms don't interfere with each other.
# ------------------------------------------------------------------------------
install_macos_casks() {
    [[ "$DISTRO_FAMILY" != "macos" ]] && return

    log_section "Homebrew casks (macOS GUI apps)"

    local brew_bin
    brew_bin="$(command -v brew 2>/dev/null \
        || echo "/opt/homebrew/bin/brew")"   # Apple Silicon default prefix

    if [[ ! -x "$brew_bin" ]]; then
        log_error "brew not found — did Homebrew install correctly?"
        return 1
    fi

    mapfile -t casks < <(read_package_list "$PACKAGES_DIR/macos-casks.txt")

    if [[ ${#casks[@]} -eq 0 ]]; then
        log_info "No casks listed in packages/macos-casks.txt, skipping"
        return
    fi

    confirm_packages "Homebrew casks" "${casks[@]}" || {
        log_warn "Cask install skipped by user"
        return 0
    }

    # --no-quarantine bypasses macOS Gatekeeper quarantine flag which causes
    # an "unidentified developer" prompt on first launch for unsigned apps
    run_cmd "$brew_bin" install --cask --no-quarantine "${casks[@]}"
    log_success "macOS casks installed"
}

# ------------------------------------------------------------------------------
# main
# ------------------------------------------------------------------------------
main() {
    log_section "Module 04: Userland"

    # Make sure ~/.local/bin is on PATH before installing tools that land there
    # (mise here, Claude Code in module 05) so they're usable without a manual fix.
    ensure_local_bin_on_path

    install_mise
    install_flatpak
    install_homebrew
    install_macos_casks

    log_success "Module 04 complete"
}

main "$@"
