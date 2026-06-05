#!/usr/bin/env bash
# ==============================================================================
# modules/09-updates.sh — Weekly automatic updates
# ==============================================================================
# Creates:
#   - A system timer for pacman, dnf, apt, or rpm-ostree updates.
#   - A user timer for Flatpak, mise, and Homebrew updates.
#
# AUR packages are reported but not installed unattended. AUR upgrades execute
# third-party PKGBUILDs and may require review or an interactive rebuild.
# ==============================================================================

[[ -n "${_MODULE_UPDATES_LOADED:-}" ]] && return
_MODULE_UPDATES_LOADED=1

if [[ -z "${SETUP_DIR:-}" ]]; then
    SETUP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    source "$SETUP_DIR/lib/log.sh"
    source "$SETUP_DIR/lib/detect.sh"
    source "$SETUP_DIR/lib/utils.sh"
    detect_all
fi

SYSTEM_SCRIPT="/usr/local/libexec/unix-setup-system-update"
SYSTEM_SERVICE="/etc/systemd/system/unix-setup-system-update.service"
SYSTEM_TIMER="/etc/systemd/system/unix-setup-system-update.timer"
USER_SCRIPT="${HOME}/.local/bin/unix-setup-user-update"
USER_SERVICE="${HOME}/.config/systemd/user/unix-setup-user-update.service"
USER_TIMER="${HOME}/.config/systemd/user/unix-setup-user-update.timer"

setup_system_updates() {
    log_section "Weekly system updates"

    if ! has_systemd; then
        log_warn "systemd is not active — weekly system update timer skipped"
        return
    fi

    if [[ "$DRY_RUN" == true ]]; then
        log_info "[DRY-RUN] Would install $SYSTEM_SCRIPT"
        log_info "[DRY-RUN] Would enable unix-setup-system-update.timer"
        return
    fi

    sudo install -d -m 0755 /usr/local/libexec
    sudo tee "$SYSTEM_SCRIPT" > /dev/null << 'EOF'
#!/usr/bin/env bash
set -uo pipefail

LOG_FILE="/var/log/unix-setup-weekly-update.log"
LOCK_FILE="/run/lock/unix-setup-weekly-update.lock"

exec 9>"$LOCK_FILE"
flock -n 9 || exit 0
exec >> "$LOG_FILE" 2>&1

echo
echo "===== System update started: $(date --iso-8601=seconds) ====="

pre_snapshot=""
if ! command -v pacman >/dev/null 2>&1 \
    && command -v snapper >/dev/null 2>&1 \
    && [[ -f /etc/snapper/configs/root ]]; then
    pre_snapshot="$(snapper -c root create --type pre \
        --description "Before weekly automatic update" --print-number 2>/dev/null || true)"
fi

status=0
if [[ -e /run/ostree-booted ]] && command -v rpm-ostree >/dev/null 2>&1; then
    rpm-ostree upgrade || status=$?
elif command -v pacman >/dev/null 2>&1; then
    # snap-pac creates the pre/post snapshots for this transaction.
    pacman -Syu --noconfirm || status=$?
elif command -v dnf >/dev/null 2>&1; then
    dnf upgrade --refresh -y || status=$?
elif command -v apt-get >/dev/null 2>&1; then
    apt-get update || status=$?
    if (( status == 0 )); then
        DEBIAN_FRONTEND=noninteractive apt-get full-upgrade -y || status=$?
        DEBIAN_FRONTEND=noninteractive apt-get autoremove -y || status=$?
    fi
else
    echo "No supported system package manager found"
    status=1
fi

if command -v flatpak >/dev/null 2>&1; then
    flatpak update --system -y --noninteractive || true
    flatpak uninstall --system --unused -y --noninteractive || true
fi

if [[ -n "$pre_snapshot" ]]; then
    snapper -c root create --type post --pre-number "$pre_snapshot" \
        --description "After weekly automatic update (status $status)" || true
fi

if [[ -f /var/run/reboot-required ]]; then
    echo "A reboot is required."
fi

echo "===== System update finished: $(date --iso-8601=seconds), status=$status ====="
exit "$status"
EOF
    sudo chmod 0755 "$SYSTEM_SCRIPT"

    sudo tee "$SYSTEM_SERVICE" > /dev/null << EOF
[Unit]
Description=Weekly operating-system update
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=${SYSTEM_SCRIPT}
Nice=10
IOSchedulingClass=best-effort
IOSchedulingPriority=7
EOF

    sudo tee "$SYSTEM_TIMER" > /dev/null << 'EOF'
[Unit]
Description=Run operating-system updates weekly

[Timer]
OnCalendar=Sun *-*-* 10:00:00
Persistent=true
RandomizedDelaySec=2h

[Install]
WantedBy=timers.target
EOF

    sudo systemctl daemon-reload
    sudo systemctl enable --now unix-setup-system-update.timer
    log_success "Weekly system updates enabled"
}

setup_user_updates() {
    log_section "Weekly user application updates"

    if ! has_systemd; then
        log_warn "systemd is not active — weekly user update timer skipped"
        return
    fi

    if [[ "$DRY_RUN" == true ]]; then
        log_info "[DRY-RUN] Would install $USER_SCRIPT"
        log_info "[DRY-RUN] Would enable unix-setup-user-update.timer"
        return
    fi

    mkdir -p "$(dirname "$USER_SCRIPT")" "$(dirname "$USER_SERVICE")"
    cat > "$USER_SCRIPT" << 'EOF'
#!/usr/bin/env bash
set -uo pipefail

LOG_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/unix-setup"
LOG_FILE="$LOG_DIR/weekly-update.log"
mkdir -p "$LOG_DIR"
exec >> "$LOG_FILE" 2>&1

echo
echo "===== User update started: $(date --iso-8601=seconds) ====="

if command -v flatpak >/dev/null 2>&1; then
    flatpak update --user -y --noninteractive || true
    flatpak uninstall --user --unused -y --noninteractive || true
fi

mise_bin="$(command -v mise 2>/dev/null || true)"
[[ -x "$HOME/.local/bin/mise" ]] && mise_bin="$HOME/.local/bin/mise"
if [[ -n "$mise_bin" ]]; then
    MISE_YES=1 "$mise_bin" upgrade || true
fi

brew_bin="$(command -v brew 2>/dev/null || true)"
[[ -x /home/linuxbrew/.linuxbrew/bin/brew ]] && brew_bin=/home/linuxbrew/.linuxbrew/bin/brew
if [[ -n "$brew_bin" ]]; then
    "$brew_bin" update || true
    "$brew_bin" upgrade || true
    "$brew_bin" cleanup || true
fi

if command -v paru >/dev/null 2>&1; then
    echo "AUR updates are intentionally not installed unattended."
    paru -Qua || true
fi

echo "===== User update finished: $(date --iso-8601=seconds) ====="
EOF
    chmod 0755 "$USER_SCRIPT"

    cat > "$USER_SERVICE" << EOF
[Unit]
Description=Weekly Flatpak, mise, and Homebrew update
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=${USER_SCRIPT}
Nice=10
IOSchedulingClass=best-effort
IOSchedulingPriority=7
EOF

    cat > "$USER_TIMER" << 'EOF'
[Unit]
Description=Run user application updates weekly

[Timer]
OnCalendar=Sun *-*-* 13:00:00
Persistent=true
RandomizedDelaySec=2h

[Install]
WantedBy=timers.target
EOF

    # Remove the old daily Flatpak timer to avoid duplicate update jobs.
    systemctl --user disable --now flatpak-update.timer 2>/dev/null || true
    rm -f "${HOME}/.config/systemd/user/flatpak-update.service"
    rm -f "${HOME}/.config/systemd/user/flatpak-update.timer"

    systemctl --user daemon-reload
    systemctl --user enable --now unix-setup-user-update.timer
    log_success "Weekly Flatpak, mise, and Homebrew updates enabled"
    log_warn "AUR packages remain manual: paru -Sua"
}

main() {
    log_section "Module 09: Automatic updates"
    setup_system_updates
    setup_user_updates
    log_success "Weekly update timers configured"
}

main "$@"
