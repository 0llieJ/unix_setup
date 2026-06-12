#!/usr/bin/env bash
# ==============================================================================
# modules/07-proton.sh — Proton Drive mount via rclone
# ==============================================================================
# Mounts Proton Drive as a local directory using rclone's FUSE driver, managed
# as a systemd user service so it starts automatically on login.
#
# Mount point: ~/ProtonDrive
# rclone remote: "proton" (must be configured manually once — see below)
#
# IMPORTANT — first-time setup requires a manual step:
#   rclone config
#   → New remote → name: proton → type: protondrive → follow the prompts
#
# Once the remote is configured, re-run this module (or the full setup) and
# the systemd service will be created and enabled automatically.
#
# Why rclone and not the Proton Drive desktop app?
#   The official Proton Drive desktop app is not available for Linux at the
#   time of writing. rclone's protondrive backend provides full read/write
#   access via FUSE, mounted as a regular directory.
#
# VFS cache settings used:
#   --vfs-cache-mode writes  — cache files locally before uploading (avoids
#                              partial-write issues with apps that write in
#                              multiple passes like document editors)
#   --vfs-cache-max-size 2G  — cap the local write cache at 2 GB
#   --dir-cache-time 72h     — cache directory listings for 72 hours
#                              (reduces API calls for static file trees)
#   --poll-interval 15s      — check for remote changes every 15 seconds
#
# Depends on: 04-userland.sh (rclone is installed via mise)
# ==============================================================================

[[ -n "${_MODULE_PROTON_LOADED:-}" ]] && return
_MODULE_PROTON_LOADED=1

PROTON_REMOTE="proton"
MOUNT_POINT="${HOME}/ProtonDrive"
SERVICE_NAME="rclone-proton"
SERVICE_FILE="${HOME}/.config/systemd/user/${SERVICE_NAME}.service"
RCLONE_BIN=""

# ------------------------------------------------------------------------------
# check_rclone
# Verifies rclone is available. It should have been installed by mise in
# 04-userland.sh. Returns 1 if missing so the module can exit cleanly.
# ------------------------------------------------------------------------------
check_rclone() {
    local candidate
    for candidate in \
        "$(command -v rclone 2>/dev/null || true)" \
        "${HOME}/.local/share/mise/shims/rclone" \
        "${HOME}/.local/bin/rclone"; do
        if [[ -n "$candidate" && -x "$candidate" ]]; then
            RCLONE_BIN="$candidate"
            break
        fi
    done

    if [[ -z "$RCLONE_BIN" ]]; then
        log_error "rclone not found — did module 04-userland.sh run successfully?"
        log_error "Install manually: mise use --global rclone@latest"
        return 1
    fi
    export RCLONE_BIN
    log_info "rclone found at $RCLONE_BIN"
}

# ------------------------------------------------------------------------------
# check_remote_configured
# Checks whether the "proton" rclone remote has been configured by the user.
# If it hasn't, prints instructions and returns 1 — the rest of the module is
# skipped rather than creating a broken service that can't mount anything.
# ------------------------------------------------------------------------------
check_remote_configured() {
    if "$RCLONE_BIN" listremotes 2>/dev/null | grep -q "^${PROTON_REMOTE}:"; then
        log_info "rclone remote '${PROTON_REMOTE}' is configured"
        return 0
    fi

    log_warn "rclone remote '${PROTON_REMOTE}' is NOT configured yet."

    if [[ "$DRY_RUN" == true ]]; then
        log_info "[DRY-RUN] Would offer to configure the '${PROTON_REMOTE}' remote interactively"
        return 1
    fi

    if ask "Set up the Proton Drive remote now?" y; then
        configure_remote_interactive && return 0
    fi

    # Fall back to manual instructions if they declined or setup failed.
    log_warn "To set it up later, run:"
    log_warn "  rclone config"
    log_warn "  → New remote → name: ${PROTON_REMOTE} → type: protondrive → follow prompts"
    log_warn "Then re-run this module: bash ${SETUP_DIR}/modules/07-proton.sh"
    return 1
}

# ------------------------------------------------------------------------------
# configure_remote_interactive
# Walks the user through creating the "proton" rclone remote by prompting for
# their Proton credentials, then creating the remote non-interactively via
# `rclone config create`. This replaces the manual `rclone config` wizard so the
# user only has to answer a few questions.
#
# Proton specifics:
#   username / password — your Proton account login. The password is obscured by
#                         rclone (--obscure) before being written to the config.
#   2fa                 — a current 6-digit TOTP code if 2FA is enabled. It is
#                         only used once, at creation time, to obtain a login
#                         token, so it must be entered fresh (codes expire ~30s).
#   mailbox_password    — only for accounts using Proton's two-password mode
#                         (separate login + mailbox password); left blank otherwise.
# ------------------------------------------------------------------------------
configure_remote_interactive() {
    log_section "Configure Proton Drive remote"

    local username password password2 twofa mailbox_pw

    read -r -p "$(printf "${BOLD}Proton email/username: ${NC}")" username
    if [[ -z "$username" ]]; then
        log_error "No username entered — aborting remote setup"
        return 1
    fi

    # Read the password twice without echoing, and confirm they match.
    read -r -s -p "$(printf "${BOLD}Proton password: ${NC}")" password; echo
    read -r -s -p "$(printf "${BOLD}Confirm password: ${NC}")" password2; echo
    if [[ "$password" != "$password2" ]]; then
        log_error "Passwords did not match — aborting remote setup"
        return 1
    fi

    read -r -p "$(printf "${BOLD}2FA code (leave blank if 2FA is off): ${NC}")" twofa
    read -r -s -p "$(printf "${BOLD}Mailbox password (blank unless you use two-password mode): ${NC}")" mailbox_pw; echo

    # Build the key=value args. Only include optional fields when provided so we
    # don't write empty values into the remote config.
    local -a args=(config create "$PROTON_REMOTE" protondrive
        username="$username" password="$password" --obscure)
    [[ -n "$twofa" ]]     && args+=("2fa=${twofa}")
    [[ -n "$mailbox_pw" ]] && args+=("mailbox_password=${mailbox_pw}")

    log_info "Creating rclone remote '${PROTON_REMOTE}'..."
    if "$RCLONE_BIN" "${args[@]}"; then
        log_success "Proton Drive remote '${PROTON_REMOTE}' configured"
        return 0
    fi

    log_error "rclone could not create the remote (check credentials / 2FA code and retry)"
    return 1
}

# ------------------------------------------------------------------------------
# create_mount_point
# Creates the ~/ProtonDrive directory that rclone will mount onto.
# The directory must exist before rclone can mount into it.
# ------------------------------------------------------------------------------
create_mount_point() {
    if [[ -d "$MOUNT_POINT" ]]; then
        log_info "Mount point already exists: $MOUNT_POINT"
    else
        log_info "Creating mount point: $MOUNT_POINT"
        run_cmd mkdir -p "$MOUNT_POINT"
    fi
}

# ------------------------------------------------------------------------------
# write_systemd_service
# Writes a user-level systemd service file that runs rclone mount on login.
#
# Key service settings:
#   Type=notify   — rclone signals systemd when the mount is ready, so other
#                   services that depend on ProtonDrive won't start too early
#   ExecStartPre  — ensures the mount point exists before rclone starts
#   ExecStop      — unmounts cleanly using fusermount3 on logout
#   Restart=on-failure / RestartSec=10 — auto-restarts if the connection drops
#
# The service uses the resolved absolute rclone path, including the mise shim
# location when mise is not active in the current shell.
# ------------------------------------------------------------------------------
write_systemd_service() {
    log_info "Writing systemd user service: $SERVICE_FILE"
    if [[ "$DRY_RUN" != true ]]; then
        mkdir -p "$(dirname "$SERVICE_FILE")"
        cat > "$SERVICE_FILE" << EOF
[Unit]
Description=Proton Drive (rclone FUSE mount)
After=network-online.target
Wants=network-online.target

[Service]
Type=notify
ExecStartPre=/bin/mkdir -p ${MOUNT_POINT}
ExecStart=${RCLONE_BIN} mount ${PROTON_REMOTE}: ${MOUNT_POINT} \\
    --vfs-cache-mode writes \\
    --vfs-cache-max-size 2G \\
    --dir-cache-time 72h \\
    --poll-interval 15s \\
    --log-level INFO
ExecStop=/bin/fusermount3 -u ${MOUNT_POINT}
Restart=on-failure
RestartSec=10

[Install]
WantedBy=default.target
EOF
    else
        log_info "[DRY-RUN] Would write $SERVICE_FILE"
    fi
}

# ------------------------------------------------------------------------------
# enable_service
# Reloads the systemd user daemon so it picks up the new service file, then
# enables and starts the service. The mount will be active immediately and will
# auto-start on every subsequent login.
# ------------------------------------------------------------------------------
enable_service() {
    log_info "Enabling and starting ${SERVICE_NAME}..."
    if [[ "$DRY_RUN" != true ]]; then
        systemctl --user daemon-reload
        systemctl --user enable --now "${SERVICE_NAME}.service"
    else
        log_info "[DRY-RUN] Would enable and start ${SERVICE_NAME}.service"
    fi
    log_success "Proton Drive mounted at $MOUNT_POINT (auto-starts on login)"
}

# ------------------------------------------------------------------------------
# main
# ------------------------------------------------------------------------------
main() {
    log_section "Module 07: Proton Drive"

    check_rclone          || return 0
    check_remote_configured || return 0
    create_mount_point

    if ! has_systemd; then
        # Non-systemd systems can still mount Proton Drive manually:
        #   rclone mount proton: ~/ProtonDrive --vfs-cache-mode writes --daemon
        log_warn "systemd is not active — Proton Drive auto-mount not configured"
        log_warn "Mount manually with: rclone mount proton: ~/ProtonDrive --vfs-cache-mode writes --daemon"
        if [[ "$DISTRO_FAMILY" == "macos" ]]; then
            log_warn "macFUSE must be installed first: brew install --cask macfuse"
        fi
        return 0
    fi

    write_systemd_service
    enable_service

    log_success "Module 07 complete"
}

main "$@"
