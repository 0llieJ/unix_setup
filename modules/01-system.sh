#!/usr/bin/env bash
# ==============================================================================
# modules/01-system.sh — Base system configuration
# ==============================================================================
# The first module to run. Sets up the foundational system settings that
# everything else depends on:
#
#   1. Firewall — deny incoming, allow outgoing
#   2. User groups — adds the current user to groups needed for hardware access
#   3. Sudo feedback — shows asterisks when typing passwords in the terminal
#   4. ClamAV — configures antivirus with automatic definition updates and a
#               weekly home-directory scan
#
# Run order: must run before any package installs because the firewall should
# be in place as early as possible on a fresh machine.
# ==============================================================================

# Guard against being sourced more than once
[[ -n "${_MODULE_SYSTEM_LOADED:-}" ]] && return
_MODULE_SYSTEM_LOADED=1

# ------------------------------------------------------------------------------
# setup_firewall
# Detects whichever firewall tool is available and applies a minimal ruleset:
#   - Default deny on incoming connections
#   - Default allow on outgoing connections
#   - SSH allowed in (so remote installs don't lock you out)
#
# Tool priority: firewalld (Fedora default) → ufw (Ubuntu default) → iptables
# ------------------------------------------------------------------------------
setup_firewall() {
    log_section "Firewall"

    if cmd_exists firewall-cmd; then
        # firewalld — Fedora/RHEL default. Uses zones; "public" is the default zone.
        log_info "Configuring firewalld..."
        run_cmd sudo systemctl enable --now firewalld
        # Set the default zone to public (restrictive by default — only SSH allowed)
        run_cmd sudo firewall-cmd --set-default-zone=public
        run_cmd sudo firewall-cmd --runtime-to-permanent
        log_success "firewalld configured: default zone = public (SSH allowed, all else denied)"

    elif cmd_exists ufw; then
        # ufw — Ubuntu/Debian default. Simple wrapper around iptables.
        log_info "Configuring ufw..."
        run_cmd sudo ufw default deny incoming
        run_cmd sudo ufw default allow outgoing
        # Allow SSH so remote connections aren't broken
        run_cmd sudo ufw allow ssh
        run_cmd sudo ufw --force enable
        log_success "ufw configured: deny incoming, allow outgoing, SSH allowed"

    elif cmd_exists iptables; then
        # iptables — lowest-level fallback, available on almost all Linux systems.
        # These rules are not persistent across reboots without iptables-save;
        # a warning is shown so the user knows to make them permanent.
        log_info "Configuring iptables (fallback)..."
        run_cmd sudo iptables -P INPUT DROP       # Drop all incoming by default
        run_cmd sudo iptables -P FORWARD DROP     # Drop forwarded packets
        run_cmd sudo iptables -P OUTPUT ACCEPT    # Allow all outgoing
        # Allow established/related connections (needed for replies to outgoing traffic)
        run_cmd sudo iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
        # Allow loopback (localhost) — many services communicate via 127.0.0.1
        run_cmd sudo iptables -A INPUT -i lo -j ACCEPT
        # Allow SSH
        run_cmd sudo iptables -A INPUT -p tcp --dport 22 -j ACCEPT
        log_warn "iptables rules set but NOT persistent. Install iptables-persistent or equivalent."

    else
        log_warn "No firewall tool found (firewalld, ufw, iptables). Skipping firewall setup."
    fi
}

# ------------------------------------------------------------------------------
# setup_user_groups
# Adds the current user to the system groups they'll need for hardware access
# and privileged operations. Without these, things like VMs, audio, Bluetooth,
# and USB devices may fail to work or require sudo every time.
#
# Groups may not exist on every distro — missing groups are silently skipped.
# A re-login (or `newgrp`) is required for group changes to take effect.
# ------------------------------------------------------------------------------
setup_user_groups() {
    log_section "User groups"

    # Groups the current user should belong to:
    #   wheel / sudo  — sudo access (wheel = Arch/Fedora, sudo = Ubuntu/Debian)
    #   networkmanager — manage network connections without root
    #   video          — direct GPU access (needed for Wayland compositors)
    #   audio          — direct audio device access
    #   input          — read input devices (keyboard/mouse) directly
    #   libvirt        — manage VMs without sudo
    #   docker/podman  — rootless container access (podman doesn't strictly need this)
    local groups=(wheel sudo networkmanager video audio input libvirt)

    for group in "${groups[@]}"; do
        if getent group "$group" &>/dev/null; then
            run_cmd sudo usermod -aG "$group" "$USER"
            log_info "Added $USER to group: $group"
        else
            log_info "Group '$group' not present on this system, skipping"
        fi
    done

    log_success "Group memberships updated (re-login required for changes to take effect)"
}

# ------------------------------------------------------------------------------
# setup_sudo_feedback
# By default, Linux terminals show nothing when you type a sudo password.
# This adds a sudoers rule to display asterisks (*) instead — a small UX
# improvement that makes it obvious input is being received.
#
# Uses visudo validation so a broken sudoers fragment can't lock you out of sudo.
# ------------------------------------------------------------------------------
setup_sudo_feedback() {
    log_section "Sudo password feedback"

    local sudoers_file="/etc/sudoers.d/pwfeedback"

    if [[ -f "$sudoers_file" ]]; then
        log_info "Sudo password feedback already configured, skipping"
        return
    fi

    log_info "Enabling asterisk feedback when typing sudo passwords..."
    if [[ "$DRY_RUN" == true ]]; then
        log_info "[DRY-RUN] Would write $sudoers_file with 'Defaults pwfeedback'"
    else
        echo "Defaults pwfeedback" | sudo tee "$sudoers_file" > /dev/null
        # Validate the file — visudo -c exits non-zero if the syntax is wrong,
        # which prevents a broken fragment from being left in place.
        if ! sudo visudo -cf "$sudoers_file"; then
            log_error "sudoers fragment failed validation, removing"
            sudo rm -f "$sudoers_file"
            return 1
        fi
        log_success "Sudo password feedback enabled"
    fi
}

# ------------------------------------------------------------------------------
# setup_clamav
# Configures ClamAV antivirus:
#   - Runs freshclam to pull the latest virus definition database
#   - Enables the clamav-freshclam systemd service for automatic daily updates
#   - Creates a user-level systemd timer for a weekly home-directory scan
#
# ClamAV is a passive scanner — it doesn't run as a daemon watching files in
# real time (that would be clamd). This setup is a lightweight scheduled scan.
# Only configured if ClamAV was installed by the packages module.
# ------------------------------------------------------------------------------
setup_clamav() {
    log_section "ClamAV"

    if ! cmd_exists freshclam; then
        log_info "ClamAV not installed, skipping"
        return
    fi

    log_info "Updating ClamAV virus definitions..."
    run_cmd sudo freshclam || log_warn "freshclam update failed (may need network access)"

    # Enable the systemd service that keeps definitions up to date automatically
    systemd_enable clamav-freshclam.service

    # Create a weekly home-directory scan as a user systemd timer
    # (user timers run without root and only scan $HOME, not the whole system)
    log_info "Setting up weekly ClamAV home scan..."
    if [[ "$DRY_RUN" != true ]]; then
        mkdir -p ~/.config/systemd/user

        # The service defines what to run: clamscan on the home directory.
        # -r = recursive, -i = only print infected files, --bell = audio alert
        # Excludes /proc, /sys, /dev — pseudo-filesystems that confuse the scanner.
        cat > ~/.config/systemd/user/clamav-scan.service << 'EOF'
[Unit]
Description=ClamAV weekly home directory scan

[Service]
Type=oneshot
ExecStart=/usr/bin/clamscan -r --bell -i \
    --exclude-dir="^/sys" \
    --exclude-dir="^/proc" \
    --exclude-dir="^/dev" \
    %h
StandardOutput=journal
EOF

        # The timer defines when to run: weekly, with a random 1-hour delay to
        # spread load across machines if multiple systems use the same config.
        cat > ~/.config/systemd/user/clamav-scan.timer << 'EOF'
[Unit]
Description=Run ClamAV home scan weekly

[Timer]
OnCalendar=weekly
Persistent=true
RandomizedDelaySec=3600

[Install]
WantedBy=timers.target
EOF

        systemctl --user daemon-reload
        systemctl --user enable clamav-scan.timer
        log_success "ClamAV: weekly home scan timer enabled"
    fi
}

# ------------------------------------------------------------------------------
# setup_podman
# Enables podman.socket so Podman exposes a Docker-compatible API on a Unix
# socket at /run/user/<uid>/podman/podman.sock. This lets tools that speak
# the Docker API (Portainer, lazydocker, VS Code Dev Containers, etc.) work
# with Podman without any extra config.
#
# On Arch, the runtime dependencies (netavark, crun, slirp4netns) are installed
# by 03-packages.sh from arch.txt. Without those, `podman run` will fail with
# network or OCI runtime errors even though the binary is present.
#
# Rootless Podman (running containers as your user rather than root) works out
# of the box on Fedora and recent Arch/Ubuntu. No further config is needed
# beyond enabling the socket.
# ------------------------------------------------------------------------------
setup_podman() {
    log_section "Podman"

    if ! cmd_exists podman; then
        log_info "Podman not installed yet — socket will be enabled after package install"
        return
    fi

    # podman.socket is a user-level unit — it activates on demand when something
    # connects to the socket, rather than running podman as a background daemon.
    run_cmd systemctl --user enable --now podman.socket

    log_success "Podman socket enabled (Docker-compatible API active)"
    log_info "Socket path: \$XDG_RUNTIME_DIR/podman/podman.sock"
}

# ------------------------------------------------------------------------------
# main — called by setup.sh to run this module
# ------------------------------------------------------------------------------
main() {
    log_section "Module 01: System"

    setup_firewall
    setup_user_groups
    setup_sudo_feedback
    setup_clamav
    setup_podman

    log_success "Module 01 complete"
}

main "$@"
