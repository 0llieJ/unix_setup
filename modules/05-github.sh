#!/usr/bin/env bash
# ==============================================================================
# modules/05-github.sh — GitHub release and install-script tools
# ==============================================================================
# Installs tools that aren't available via mise, Flatpak, Homebrew, or system
# package managers — they must be fetched directly from GitHub or via an
# official install script.
#
# Which tools run is controlled by packages/github.txt — comment a line there
# to skip that tool. The install functions themselves live in this file.
#
# Current tools:
#   claude-code  — Anthropic Claude Code CLI (official install script)
#   devpod       — Dev Container manager (static binary from GitHub releases)
#   nerd-fonts   — Icon glyphs for terminal tools (GitHub release archive)
#                  Skipped on Arch — installed via pacman (ttf-nerd-fonts-symbols)
#
# ------------------------------------------------------------------------------
# HOW TO ADD A NEW GITHUB TOOL
# ------------------------------------------------------------------------------
# 1. Add the tool name to packages/github.txt (one name per line)
# 2. Add a function here named _install_<toolname>() that performs the install.
#    Use run_cmd for any command that changes system state so DRY_RUN is respected.
#
# Template:
#
#   _install_mytool() {
#       if cmd_exists mytool; then
#           log_info "mytool already installed at $(command -v mytool)"
#           return
#       fi
#       log_info "Installing mytool..."
#       local version
#       version=$(curl -fsSL https://api.github.com/repos/owner/mytool/releases/latest \
#           | grep '"tag_name"' | sed 's/.*"v\(.*\)".*/\1/')
#       run_cmd curl -fsSL -o /tmp/mytool \
#           "https://github.com/owner/mytool/releases/download/v${version}/mytool-linux-amd64"
#       run_cmd sudo install -m 0755 /tmp/mytool /usr/local/bin/mytool
#       run_cmd rm -f /tmp/mytool
#       log_success "mytool ${version} installed"
#   }
#
# Tips:
#   - Always check cmd_exists first so re-runs are safe
#   - Use /tmp for downloads and clean up after
#   - `sudo install -m 0755 <src> <dest>` is the correct way to place a binary
#   - Detect architecture with `uname -m` if the tool ships arch-specific binaries
#     (x86_64 → amd64, aarch64 → arm64 in most GitHub release naming conventions)
# ==============================================================================

[[ -n "${_MODULE_GITHUB_LOADED:-}" ]] && return
_MODULE_GITHUB_LOADED=1

# ------------------------------------------------------------------------------
# _install_claude-code
# Installs the Claude Code CLI using Anthropic's official install script.
# The script places the binary at ~/.claude/local/claude and adds a wrapper
# to ~/.local/bin/claude.
# ------------------------------------------------------------------------------
_install_claude-code() {
    if cmd_exists claude; then
        log_info "Claude Code already installed at $(command -v claude)"
        return
    fi

    log_info "Installing Claude Code CLI..."
    run_cmd bash -c "curl -fsSL https://claude.ai/install.sh | sh"
    log_success "Claude Code installed"
}

# ------------------------------------------------------------------------------
# _install_devpod
# DevPod is a Dev Container manager — it lets you open any repo in a
# containerised dev environment defined by a devcontainer.json, using Podman,
# Docker, SSH, or a cloud provider as the backend.
#
# Distributed as a single static binary from GitHub releases — no package
# manager needed, works on any distro.
# ------------------------------------------------------------------------------
_install_devpod() {
    if cmd_exists devpod; then
        log_info "DevPod already installed at $(command -v devpod)"
        return
    fi

    log_info "Installing DevPod..."

    # Map uname -m output to the arch suffix GitHub uses in release filenames
    local arch
    case "$(uname -m)" in
        x86_64)  arch="amd64" ;;
        aarch64) arch="arm64" ;;
        *)
            log_error "Unsupported architecture for DevPod: $(uname -m)"
            return 1
            ;;
    esac

    local url="https://github.com/loft-sh/devpod/releases/latest/download/devpod-linux-${arch}"
    run_cmd curl -fsSL -o /tmp/devpod "$url"
    run_cmd sudo install -c -m 0755 /tmp/devpod /usr/local/bin/devpod
    run_cmd rm -f /tmp/devpod

    log_success "DevPod installed to /usr/local/bin/devpod"
}

# ------------------------------------------------------------------------------
# _install_codex
# Installs the OpenAI Codex CLI — OpenAI's AI coding agent that runs in the
# terminal. It can read, write, and execute code autonomously within a sandboxed
# environment.
#
# Installed via npm as it's a Node.js package. Requires node@lts to be present
# in mise.txt so npm is available before this function runs (module 04 handles
# that). The npm global prefix is set to ~/.local so no sudo is needed.
# ------------------------------------------------------------------------------
_install_codex() {
    if cmd_exists codex; then
        log_info "OpenAI Codex already installed at $(command -v codex)"
        return
    fi

    # npm comes from the Node runtime installed by mise
    local npm_bin
    npm_bin="$(command -v npm 2>/dev/null \
        || echo "${HOME}/.local/share/mise/shims/npm")"

    if [[ ! -x "$npm_bin" ]]; then
        log_error "npm not found — ensure node@lts is in packages/mise.txt and module 04 has run"
        return 1
    fi

    log_info "Installing OpenAI Codex CLI via npm..."
    # --prefix ~/.local installs to ~/.local/bin without needing root
    run_cmd "$npm_bin" install -g --prefix "${HOME}/.local" @openai/codex
    log_success "OpenAI Codex CLI installed"
}

# ------------------------------------------------------------------------------
# _install_nerd-fonts
# Installs the Nerd Fonts Symbols Only pack — a font containing only the icon
# glyphs (no text), used by terminal tools like starship, waybar, yazi, and
# lf to render icons in the terminal.
#
# "Symbols Only" keeps download size small (~4MB vs hundreds of MB for full
# font packs) and avoids conflicts with your chosen programming font.
#
# Skipped on Arch because ttf-nerd-fonts-symbols is available via pacman
# and was already installed by 03-packages.sh.
# ------------------------------------------------------------------------------
_install_nerd-fonts() {
    # Arch gets ttf-nerd-fonts-symbols from pacman — no need to install manually
    if [[ "$DISTRO_FAMILY" == "arch" ]]; then
        log_info "Arch detected — Nerd Fonts installed via pacman (ttf-nerd-fonts-symbols), skipping"
        return
    fi

    local font_dir="${HOME}/.local/share/fonts/NerdFonts"

    if [[ -d "$font_dir" ]] && ls "$font_dir"/*.ttf &>/dev/null 2>&1; then
        log_info "Nerd Fonts already installed at $font_dir"
        return
    fi

    log_info "Installing Nerd Fonts Symbols Only..."

    if [[ "$DRY_RUN" != true ]]; then
        # Fetch the latest release version tag from the GitHub API
        local version
        version=$(curl -fsSL https://api.github.com/repos/ryanoasis/nerd-fonts/releases/latest \
            | grep '"tag_name"' \
            | sed 's/.*"v\(.*\)".*/\1/')

        if [[ -z "$version" ]]; then
            log_error "Could not determine Nerd Fonts version from GitHub API"
            return 1
        fi

        log_info "Downloading Nerd Fonts Symbols Only v${version}..."
        mkdir -p "$font_dir"
        curl -fsSL -o /tmp/NerdFontsSymbolsOnly.tar.xz \
            "https://github.com/ryanoasis/nerd-fonts/releases/download/v${version}/NerdFontsSymbolsOnly.tar.xz"
        tar -xf /tmp/NerdFontsSymbolsOnly.tar.xz -C "$font_dir"
        rm -f /tmp/NerdFontsSymbolsOnly.tar.xz

        # Rebuild the font cache so the system knows about the new font
        fc-cache -fv "$font_dir"
    else
        log_info "[DRY-RUN] Would download and install Nerd Fonts Symbols Only to $font_dir"
    fi

    log_success "Nerd Fonts Symbols Only installed"
}

# ==============================================================================
# ENGINE
# ==============================================================================

# ------------------------------------------------------------------------------
# main
# Reads packages/github.txt and calls the matching _install_<tool>() function
# for each uncommented entry. Missing install functions are flagged as errors
# rather than silently skipped, so a typo in github.txt is caught immediately.
# ------------------------------------------------------------------------------
main() {
    log_section "Module 05-github: GitHub & install-script tools"

    local packages_file="${SETUP_DIR}/packages/github.txt"

    if [[ ! -f "$packages_file" ]]; then
        log_warn "packages/github.txt not found — skipping"
        return
    fi

    while IFS= read -r tool; do
        [[ -z "$tool" ]] && continue

        local fn="_install_${tool}"

        if declare -F "$fn" &>/dev/null; then
            log_info "Installing: $tool"
            "$fn"
        else
            log_error "No install function for '$tool' — add _install_${tool}() to modules/05-github.sh"
        fi
    done < <(read_package_list "$packages_file")

    log_success "Module 05-github complete"
}

main "$@"
