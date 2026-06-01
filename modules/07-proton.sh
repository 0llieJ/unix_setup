#!/usr/bin/env bash
# ==============================================================================
# modules/06-proton.sh — Proton Drive mount via rclone
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

# ------------------------------------------------------------------------------
# check_rclone
# Verifies rclone is available. It should have been installed by mise in
# 04-userland.sh. Returns 1 if missing so the module can exit cleanly.
# ------------------------------------------------------------------------------
check_rclone() {
    if ! cmd_exists rclone; then
        log_error "rclone not found — did module 04-userland.sh run successfully?"
        log_error "Install manually: mise use --global rclone@latest"
        return 1
    fi
    log_info "rclone found at $(command -v rclone)"
}

# ------------------------------------------------------------------------------
# check_remote_configured
# Checks whether the "proton" rclone remote has been configured by the user.
# If it hasn't, prints instructions and returns 1 — the rest of the module is
# skipped rather than creating a broken service that can't mount anything.
# ------------------------------------------------------------------------------
check_remote_configured() {
    if rclone listremotes 2>/dev/null | grep -q "^${PROTON_REMOTE}:"; then
        log_info "rclone remote '${PROTON_REMOTE}' is configured"
        return 0
    else
        log_warn "rclone remote '${PROTON_REMOTE}' is NOT configured yet."
        log_warn "Run the following to set it up (one-time step):"
        log_warn "  rclone config"
        log_warn "  → New remote → name: ${PROTON_REMOTE} → type: protondrive → follow prompts"
        log_warn "Then re-run this module: bash ${SETUP_DIR}/modules/06-proton.sh"
        return 1
    fi
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
# PATH in the service includes the mise shims directory so rclone is found
# even though it wasn't installed via the system package manager.
# ------------------------------------------------------------------------------
write_systemd_service() {
    if [[ -f "$SERVICE_FILE" ]]; then
        log_info "systemd service already exists: $SERVICE_FILE"
        return
    fi

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
# Include mise shims so rclone is found regardless of which shell activated mise
Environment=PATH=${HOME}/.local/share/mise/shims:/usr/local/bin:/usr/bin:/bin
ExecStartPre=/bin/mkdir -p ${MOUNT_POINT}
ExecStart=rclone mount ${PROTON_REMOTE}: ${MOUNT_POINT} \\
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
    log_section "Module 06: Proton Drive"

    check_rclone          || return 0
    check_remote_configured || return 0
    create_mount_point
    write_systemd_service
    enable_service

    log_success "Module 06 complete"
}

main "$@"
