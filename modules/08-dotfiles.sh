#!/usr/bin/env bash
# ==============================================================================
# modules/07-dotfiles.sh — SSH key setup and dotfile application via chezmoi
# ==============================================================================
# The final configuration step — pulls down your personal dotfiles and applies
# them to the home directory.
#
# Two steps:
#   1. SSH key — if no SSH key exists, one is generated and the public key is
#                shown so it can be added to GitHub/Gitea before the next step.
#   2. chezmoi — initialises the dotfiles repo (via SSH) and applies it.
#                chezmoi manages files in $HOME in a declarative way, handling
#                templates, encrypted secrets, and machine-specific overrides.
#
# The dotfiles repo URL is set in DOTFILES_REPO below — update it to match
# your own repo if you fork this setup.
#
# Depends on: 04-userland.sh (chezmoi is installed via mise)
# ==============================================================================

[[ -n "${_MODULE_DOTFILES_LOADED:-}" ]] && return
_MODULE_DOTFILES_LOADED=1

# Your dotfiles repository — change this to your own fork/repo
DOTFILES_REPO="git@github.com:0llieJ/dotfiles.git"

# Blog repository
BLOG_REPO="git@github.com:0llieJ/blog.git"
BLOG_DIR="${HOME}/projects/blog"

# Where chezmoi stores its source directory
CHEZMOI_SOURCE="${HOME}/.local/share/chezmoi"

# ------------------------------------------------------------------------------
# setup_ssh_key
# Checks for an existing SSH key. If none is found, generates an ed25519 key
# (smaller and faster than RSA, recommended for new keys) and prints the public
# key so it can be manually added to GitHub.
#
# If a key already exists, the existing public key is shown so you can verify
# it's already authorised on GitHub before the dotfiles clone step.
#
# The function then waits for the user to confirm they've added the key before
# continuing — the clone will fail silently if GitHub doesn't accept the key.
# ------------------------------------------------------------------------------
setup_ssh_key() {
    log_section "SSH key"

    local key_file="${HOME}/.ssh/id_ed25519"
    local pub_file="${key_file}.pub"

    if [[ -f "$key_file" ]]; then
        log_info "SSH key already exists: $key_file"
    else
        log_info "No SSH key found — generating ed25519 key..."
        if [[ "$DRY_RUN" != true ]]; then
            mkdir -p "${HOME}/.ssh"
            chmod 700 "${HOME}/.ssh"
            # -N "" = no passphrase (for automated setups; add one manually if preferred)
            # -C   = comment shown in the public key — set to user@hostname for clarity
            ssh-keygen -t ed25519 -C "${USER}@$(hostname)" -f "$key_file" -N ""
        else
            log_info "[DRY-RUN] Would generate SSH key at $key_file"
            return
        fi
    fi

    # Print the public key so it can be copied to GitHub/Gitea
    echo ""
    echo "────────────────────────────────────────────────────────────"
    echo "  Your SSH public key:"
    echo ""
    cat "$pub_file"
    echo "────────────────────────────────────────────────────────────"
    echo ""
    log_warn "Add the key above to GitHub: Settings → SSH and GPG keys → New SSH key"
    echo ""

    # Pause and wait for confirmation before trying to clone via SSH
    if ! ask "Have you added the key to GitHub and are ready to continue?" n; then
        log_warn "Skipping dotfile setup — re-run module 07-dotfiles.sh when ready"
        return 1
    fi
}

# ------------------------------------------------------------------------------
# setup_chezmoi
# Initialises and applies the dotfiles repo using chezmoi.
#
# chezmoi init clones the repo into ~/.local/share/chezmoi (the source dir).
# chezmoi apply then symlinks or copies files into $HOME according to the repo's
# .chezmoiignore and template rules.
#
# If chezmoi is already initialised (source dir exists), init is skipped and
# only apply is run. This makes the module safe to re-run to pick up new
# dotfile changes.
# ------------------------------------------------------------------------------
setup_chezmoi() {
    log_section "Dotfiles (chezmoi)"

    # Resolve the chezmoi binary — installed by mise, so it may be in the
    # mise shims directory rather than a standard $PATH location
    local chezmoi_bin
    chezmoi_bin="$(command -v chezmoi 2>/dev/null \
        || echo "${HOME}/.local/share/mise/shims/chezmoi")"

    if [[ ! -x "$chezmoi_bin" ]]; then
        log_error "chezmoi not found — did module 04-userland.sh run successfully?"
        log_error "Install manually: mise use --global chezmoi@latest"
        return 1
    fi

    if [[ -d "$CHEZMOI_SOURCE" ]]; then
        log_info "chezmoi source directory exists — skipping init, running apply only"
    else
        log_info "Initialising chezmoi from $DOTFILES_REPO..."
        run_cmd "$chezmoi_bin" init "$DOTFILES_REPO"
    fi

    log_info "Applying dotfiles..."
    run_cmd "$chezmoi_bin" apply

    log_success "Dotfiles applied"
}

# ------------------------------------------------------------------------------
# setup_blog
# Clones the Hugo blog repo into ~/projects/blog and verifies Hugo is available.
# Safe to re-run — pulls latest changes if the repo already exists.
# ------------------------------------------------------------------------------
setup_blog() {
    log_section "Blog"

    if ! cmd_exists hugo; then
        log_warn "Hugo not found — skipping blog setup (install via mise: hugo@latest)"
        return
    fi

    mkdir -p "${HOME}/projects"

    if [[ -d "$BLOG_DIR/.git" ]]; then
        log_info "Blog repo already cloned — pulling latest changes..."
        run_cmd git -C "$BLOG_DIR" pull
    else
        log_info "Cloning blog repo from $BLOG_REPO..."
        run_cmd git clone "$BLOG_REPO" "$BLOG_DIR"
    fi

    log_success "Blog ready at $BLOG_DIR"
}

# ------------------------------------------------------------------------------
# main
# ------------------------------------------------------------------------------
main() {
    log_section "Module 08: Dotfiles"

    setup_ssh_key || return 0
    setup_chezmoi
    setup_blog

    log_success "Module 08 complete"
}

main "$@"
