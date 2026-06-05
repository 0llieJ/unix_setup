#!/usr/bin/env bash
# ==============================================================================
# modules/01-system.sh — Base system configuration
# ==============================================================================
# Defines system configuration functions and performs the base system upgrade.
# Post-package configuration is run by modules/03-system-config.sh so services
# are configured only after their packages have been installed.
# ==============================================================================

# Guard against being sourced more than once
[[ -n "${_MODULE_SYSTEM_LOADED:-}" ]] && return
_MODULE_SYSTEM_LOADED=1

# ------------------------------------------------------------------------------
# setup_firewall
# Asks which firewall to use and applies a minimal ruleset:
#   - Default deny on incoming connections
#   - Default allow on outgoing connections
#   - SSH allowed in (so remote installs don't lock you out)
#   - LocalSend TCP port 53317 allowed in
#
# Set FIREWALL=firewalld, FIREWALL=ufw, FIREWALL=nftables, or FIREWALL=none
# to skip the prompt.
# ------------------------------------------------------------------------------
setup_firewall() {
    log_section "Firewall"

    if [[ "$DISTRO_FAMILY" == "macos" ]]; then
        # macOS has a built-in Application Firewall managed via System Settings.
        # Enable it via socketfilterfw and set to block all incoming connections.
        log_info "Configuring macOS Application Firewall..."
        run_cmd sudo /usr/libexec/ApplicationFirewall/socketfilterfw --setglobalstate on
        run_cmd sudo /usr/libexec/ApplicationFirewall/socketfilterfw --setblockall on
        log_success "macOS Application Firewall enabled (block all incoming)"
        return
    fi

    local firewall="${FIREWALL:-}"

    if [[ -z "$firewall" ]]; then
        if [[ "$DRY_RUN" == true ]]; then
            firewall="firewalld"
            log_info "[DRY-RUN] Defaulting firewall preview to firewalld"
        else
            echo "  Choose a firewall:"
            echo "    1) firewalld (recommended)"
            echo "    2) ufw"
            echo "    3) nftables"
            echo "    4) none"
            echo ""
            local choice
            read -r -p "  Choice [1/2/3/4] (default: 1): " choice
            case "${choice:-1}" in
                1) firewall="firewalld" ;;
                2) firewall="ufw" ;;
                3) firewall="nftables" ;;
                4) firewall="none" ;;
                *)
                    log_error "Invalid firewall choice: $choice"
                    return 1
                    ;;
            esac
        fi
    fi

    case "$firewall" in
        firewalld)
            if ! cmd_exists firewall-cmd; then
                pkg_install firewalld
            fi
            if [[ "$DRY_RUN" != true ]] && ! cmd_exists firewall-cmd; then
                log_error "firewalld was not installed"
                return 1
            fi

        # firewalld — Fedora/RHEL default. Uses zones; "public" is the default zone.
            log_info "Configuring firewalld..."
            run_cmd sudo systemctl enable --now firewalld
            run_cmd sudo firewall-cmd --set-default-zone=public
            run_cmd sudo firewall-cmd --permanent --zone=public --add-service=ssh
            run_cmd sudo firewall-cmd --permanent --zone=public --add-port=53317/tcp
            run_cmd sudo firewall-cmd --reload
            log_success "firewalld configured: SSH and LocalSend TCP 53317 allowed"
            ;;

        ufw)
            if ! cmd_exists ufw; then
                pkg_install ufw
            fi
            if [[ "$DRY_RUN" != true ]] && ! cmd_exists ufw; then
                log_error "ufw was not installed"
                return 1
            fi

        # ufw — Ubuntu/Debian default. Simple wrapper around iptables.
            log_info "Configuring ufw..."
            run_cmd sudo ufw default deny incoming
            run_cmd sudo ufw default allow outgoing
            run_cmd sudo ufw allow ssh
            run_cmd sudo ufw allow 53317/tcp comment LocalSend
            run_cmd sudo ufw --force enable
            log_success "ufw configured: SSH and LocalSend TCP 53317 allowed"
            ;;

        nftables)
            if ! cmd_exists nft; then
                pkg_install nftables
            fi
            if [[ "$DRY_RUN" != true ]] && ! cmd_exists nft; then
                log_error "nftables was not installed"
                return 1
            fi

            log_info "Configuring nftables..."
            if [[ "$DRY_RUN" == true ]]; then
                log_info "[DRY-RUN] Would write /etc/nftables.conf"
            else
                sudo tee /etc/nftables.conf > /dev/null << 'EOF'
#!/usr/bin/nft -f

flush ruleset

table inet filter {
    chain input {
        type filter hook input priority filter; policy drop;

        ct state invalid drop
        ct state established,related accept
        iifname "lo" accept

        # ICMP is required for diagnostics, IPv6 neighbour discovery, and PMTU.
        ip protocol icmp accept
        ip6 nexthdr ipv6-icmp accept

        tcp dport 22 ct state new accept
        tcp dport 53317 ct state new accept comment "LocalSend"
    }

    chain forward {
        type filter hook forward priority filter; policy drop;
    }

    chain output {
        type filter hook output priority filter; policy accept;
    }
}
EOF
            fi
            run_cmd sudo nft --check --file /etc/nftables.conf
            run_cmd sudo systemctl enable --now nftables
            log_success "nftables configured: SSH and LocalSend TCP 53317 allowed"
            ;;

        none)
            log_warn "Firewall setup skipped by user"
            ;;

        *)
            log_error "Unsupported FIREWALL value '$firewall' (use firewalld, ufw, nftables, or none)"
            return 1
            ;;
    esac
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

    # macOS manages groups differently — dscl rather than usermod/getent.
    # The groups that matter on Linux (wheel, libvirt, video etc.) don't exist
    # on macOS in the same form. Admin access is managed via System Settings.
    if [[ "$DISTRO_FAMILY" == "macos" ]]; then
        log_info "macOS: group management handled via System Settings — skipping"
        return
    fi

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

    if [[ "$DISTRO_FAMILY" == "macos" ]]; then
        log_info "macOS: leaving the system sudoers configuration unchanged"
        return
    fi

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
    if ! has_systemd; then
        log_warn "systemd is not active, skipping the ClamAV timer"
    elif [[ "$DRY_RUN" != true ]]; then
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

    if ! has_systemd; then
        log_warn "systemd is not active, skipping the Podman socket"
        return
    fi

    # podman.socket is a user-level unit — it activates on demand when something
    # connects to the socket, rather than running podman as a background daemon.
    run_cmd systemctl --user enable --now podman.socket

    log_success "Podman socket enabled (Docker-compatible API active)"
    log_info "Socket path: \$XDG_RUNTIME_DIR/podman/podman.sock"
}

# ------------------------------------------------------------------------------
# setup_pacman
# Ensures the [extra] repository is enabled in /etc/pacman.conf and enables
# useful pacman quality-of-life settings:
#   Color               — coloured output in the terminal
#   ParallelDownloads   — download up to 5 packages simultaneously
#
# [extra] is enabled by default on most Arch installs, but some minimal
# installs (archinstall with a bare profile) omit it. This is idempotent —
# if the repo is already present the sed commands are no-ops.
# ------------------------------------------------------------------------------
setup_pacman() {
    if [[ "$DISTRO_FAMILY" != "arch" ]]; then
        return
    fi

    log_section "pacman configuration"

    # Enable [extra] repo if it's commented out
    if grep -q '^\s*#\s*\[extra\]' /etc/pacman.conf; then
        log_info "Enabling [extra] repository..."
        if [[ "$DRY_RUN" != true ]]; then
            sudo sed -i '/^\s*#\s*\[extra\]/{
                s/^#\s*//
                n
                s/^#\s*//
            }' /etc/pacman.conf
        else
            log_info "[DRY-RUN] Would uncomment [extra] in /etc/pacman.conf"
        fi
    else
        log_info "[extra] repository already enabled"
    fi

    # Enable Color if not already set
    if ! grep -q '^Color' /etc/pacman.conf; then
        log_info "Enabling Color in pacman.conf..."
        run_cmd sudo sed -i 's/^#Color/Color/' /etc/pacman.conf
    fi

    # Enable ParallelDownloads if not already set
    if ! grep -q '^ParallelDownloads' /etc/pacman.conf; then
        log_info "Enabling ParallelDownloads = 5 in pacman.conf..."
        run_cmd sudo sed -i 's/^#ParallelDownloads.*/ParallelDownloads = 5/' /etc/pacman.conf
    fi

    log_success "pacman configured"
}

# ------------------------------------------------------------------------------
# update_system
# Fully updates the mutable base operating system before repositories, package
# installation, and CPU microcode are configured.
# ------------------------------------------------------------------------------
update_system() {
    log_section "System update"

    if [[ "$SYSTEM_PROFILE" == "atomic" ]]; then
        log_info "Atomic system detected — base image updates are managed separately"
        return
    fi

    case "$PKG_MANAGER" in
        pacman) run_cmd sudo pacman -Syu --noconfirm ;;
        dnf)    run_cmd sudo dnf upgrade --refresh -y ;;
        apt)
            run_cmd sudo apt-get update
            run_cmd sudo apt-get full-upgrade -y
            ;;
        brew)
            log_info "macOS system updates are managed by Software Update"
            ;;
        *) log_error "No update method for package manager: $PKG_MANAGER"; return 1 ;;
    esac
}

# ------------------------------------------------------------------------------
# main — called by setup.sh to run this module
# ------------------------------------------------------------------------------
main() {
    log_section "Module 01: System preflight"

    setup_pacman
    update_system

    log_success "Module 01 preflight complete"
}

if [[ "${SYSTEM_MODULE_NO_MAIN:-false}" != true ]]; then
    main "$@"
fi
