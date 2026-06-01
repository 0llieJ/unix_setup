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
# Tool list comes from packages/mise.txt — one `name@version` or `name@latest`
# per line.
# ------------------------------------------------------------------------------
install_mise() {
    log_section "mise (language runtimes + CLI tools)"

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
    [[ ! -x "$mise_bin" ]] && mise_bin="$(command -v mise 2>/dev/null || true)"

    if [[ -z "$mise_bin" ]]; then
        log_error "mise binary not found after install — check ~/.local/bin is in PATH"
        return 1
    fi

    # Install each tool listed in mise.txt
    # Format per line: <tool>@<version>  e.g.  python@3.12  or  ripgrep@latest
    log_info "Installing mise tools from packages/mise.txt..."
    while IFS= read -r tool; do
        [[ -z "$tool" ]] && continue
        log_info "mise: installing $tool"
        run_cmd "$mise_bin" use --global "$tool"
    done < <(read_package_list "$PACKAGES_DIR/mise.txt")

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

    if ! cmd_exists flatpak; then
        log_warn "flatpak binary not found — was it installed by 03-packages.sh?"
        return
    fi

    # Add Flathub as a remote if it isn't already registered
    if ! flatpak remotes | grep -q "flathub"; then
        log_info "Adding Flathub remote..."
        run_cmd sudo flatpak remote-add --if-not-exists flathub \
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

    log_info "Installing ${#flatpak_apps[@]} Flatpak apps..."
    run_cmd flatpak install -y --noninteractive flathub "${flatpak_apps[@]}"

    # Set up a daily auto-update timer so Flatpak apps stay current.
    # This creates a user-level systemd service+timer rather than running
    # updates at login, which would slow down session start.
    log_info "Configuring Flatpak auto-update timer..."
    if [[ "$DRY_RUN" != true ]]; then
        mkdir -p ~/.config/systemd/user

        cat > ~/.config/systemd/user/flatpak-update.service << 'EOF'
[Unit]
Description=Update Flatpak applications

[Service]
Type=oneshot
ExecStart=/usr/bin/flatpak update -y --noninteractive
EOF

        cat > ~/.config/systemd/user/flatpak-update.timer << 'EOF'
[Unit]
Description=Update Flatpak applications daily

[Timer]
OnCalendar=daily
Persistent=true

[Install]
WantedBy=timers.target
EOF

        systemctl --user daemon-reload
        systemctl --user enable flatpak-update.timer
    fi

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

    if [[ ! -x "$brew_bin" ]]; then
        log_error "brew binary not found after install"
        return 1
    fi

    mapfile -t brew_formulae < <(read_package_list "$PACKAGES_DIR/homebrew.txt")

    if [[ ${#brew_formulae[@]} -eq 0 ]]; then
        log_info "No Homebrew formulae listed, skipping"
        return
    fi

    log_info "Installing ${#brew_formulae[@]} Homebrew formulae..."
    run_cmd "$brew_bin" install "${brew_formulae[@]}"

    log_success "Homebrew formulae installed"
}

# ------------------------------------------------------------------------------
# main
# ------------------------------------------------------------------------------
main() {
    log_section "Module 04: Userland"

    install_mise
    install_flatpak
    install_homebrew

    log_success "Module 04 complete"
}

main "$@"
