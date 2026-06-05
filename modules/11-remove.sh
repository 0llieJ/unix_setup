#!/usr/bin/env bash
# ==============================================================================
# modules/11-remove.sh — Tool removal and cleanup
# ==============================================================================
# OPTIONAL MODULE — removes a tool completely: stops and disables its systemd
# services, uninstalls its packages, and deletes its config files.
#
# Usage:
#   bash setup/modules/10-remove.sh <tool>
#   bash setup/setup.sh --only 10 -- <tool>
#
# Examples:
#   bash setup/modules/10-remove.sh sddm
#   bash setup/modules/10-remove.sh lightdm
#   bash setup/modules/10-remove.sh greetd
#
# To list all available profiles:
#   bash setup/modules/10-remove.sh --list
#
# Dry-run (preview without removing anything):
#   DRY_RUN=true bash setup/modules/10-remove.sh sddm
#
# Why the order matters:
#   Services must be stopped and disabled BEFORE the package is removed,
#   otherwise systemd can be left with orphaned unit references that require
#   a daemon-reload to clear. Config files are removed last so nothing is
#   left behind after the package is gone.
# ==============================================================================

[[ -n "${_MODULE_REMOVE_LOADED:-}" ]] && return
_MODULE_REMOVE_LOADED=1

if [[ -z "${SETUP_DIR:-}" ]]; then
    SETUP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    source "$SETUP_DIR/lib/log.sh"
    source "$SETUP_DIR/lib/detect.sh"
    source "$SETUP_DIR/lib/utils.sh"
    detect_all
fi

# ==============================================================================
# REMOVAL PROFILES
# ==============================================================================
# Each profile is a bash function named _profile_<toolname> that calls
# do_remove() with four arguments:
#
#   do_remove \
#     "pkg1 pkg2 ..."           — packages to uninstall (space-separated)
#     "svc1 svc2 ..."           — systemd SYSTEM services to stop/disable
#     "svc1 svc2 ..."           — systemd USER services to stop/disable
#     "/etc/foo ~/.config/foo"  — config paths to delete (space-separated)
#
# Pass an empty string "" for any argument that doesn't apply to the tool.
#
# ------------------------------------------------------------------------------
# HOW TO ADD A NEW PROFILE
# ------------------------------------------------------------------------------
# 1. Add a new function below following this template:
#
#      _profile_mytool() {
#          do_remove \
#              "package-name other-package" \   # packages to remove
#              "mytool.service mytool.timer" \   # system services to stop/disable
#              "mytool-user.service"          \   # user services (empty "" if none)
#              "/etc/mytool ~/.config/mytool"     # config dirs/files to delete
#      }
#
# 2. That's it. The function is auto-discovered by list_profiles() and
#    callable immediately as: bash 10-remove.sh mytool
#
# Tips:
#   - Package names must match the distro you're on (pacman/dnf/apt names differ).
#     If a package doesn't exist on the current distro, do_remove() skips it safely.
#   - Use "~/.config/foo" for user config and "/etc/foo" for system config.
#   - If removal needs extra steps beyond packages/services/configs (e.g.
#     unmounting a FUSE filesystem first), add them directly in the profile
#     function before calling do_remove() — see _profile_proton-drive() below.
#   - Always test with DRY_RUN=true first.
# ==============================================================================

# ------------------------------------------------------------------------------
# LOGIN MANAGERS
# Each manager gets its own profile so you can swap cleanly:
#   bash 10-remove.sh sddm   → then install gdm and run module 09
# Greeters (tuigreet, regreet, nwg-hello) also have individual profiles
# in case you want to swap greeter while keeping greetd.
# ------------------------------------------------------------------------------

_profile_sddm() {
    # Qt-based login manager. Most popular for tiling WM setups.
    # Themes live in /usr/share/sddm/themes/ (installed separately, not removed here).
    do_remove \
        "sddm"                          \
        "sddm"                          \
        ""                              \
        "/etc/sddm.conf /etc/sddm.conf.d"
}

_profile_gdm() {
    # GNOME Display Manager. Polished but pulls in GNOME dependencies.
    # gdm3 = Debian/Ubuntu package name; gdm = Arch/Fedora.
    do_remove \
        "gdm gdm3"                      \
        "gdm"                           \
        ""                              \
        "/etc/gdm /etc/gdm3"
}

_profile_lightdm() {
    # Lightweight modular login manager. Removes the manager and both supported
    # greeters (slick and webkit2) — only the installed one will actually be removed.
    do_remove \
        "lightdm lightdm-slick-greeter lightdm-webkit2-greeter" \
        "lightdm"                       \
        ""                              \
        "/etc/lightdm"
}

_profile_greetd() {
    # Minimal login daemon. Removes greetd and ALL greeters that may have been
    # installed alongside it — tuigreet, regreet, and nwg-hello.
    # Use _profile_greetd-tuigreet etc. to swap greeter while keeping greetd.
    do_remove \
        "greetd greetd-tuigreet greetd-regreet nwg-hello" \
        "greetd"                        \
        ""                              \
        "/etc/greetd"
}

_profile_greetd-tuigreet() {
    # Removes only the tuigreet greeter, leaving greetd itself in place.
    # Useful when swapping to a GUI greeter (regreet or nwg-hello).
    # After removal, re-run module 09 to reconfigure greetd with the new greeter.
    do_remove \
        "greetd-tuigreet"               \
        ""                              \
        ""                              \
        ""
}

_profile_greetd-regreet() {
    # Removes the ReGreet GTK4 GUI greeter, leaving greetd in place.
    # ReGreet config lives in /etc/regreet.toml.
    do_remove \
        "greetd-regreet"                \
        ""                              \
        ""                              \
        "/etc/regreet.toml"
}

_profile_nwg-hello() {
    # Removes the nwg-hello GTK3 GUI greeter, leaving greetd in place.
    # Designed for Sway/Hyprland — config in /etc/nwg-hello/.
    do_remove \
        "nwg-hello"                     \
        ""                              \
        ""                              \
        "/etc/nwg-hello"
}

# ------------------------------------------------------------------------------
# SNAPSHOT / ATOMIC TOOLS
# ------------------------------------------------------------------------------

_profile_snapper() {
    do_remove \
        "snapper snap-pac"              \
        "snapper-timeline.timer snapper-cleanup.timer" \
        ""                              \
        "/etc/snapper"
}

_profile_timeshift() {
    do_remove \
        "timeshift timeshift-autosnap" \
        ""                              \
        ""                              \
        "/etc/timeshift"
}

_profile_grub-btrfs() {
    do_remove \
        "grub-btrfs"                    \
        "grub-btrfsd"                   \
        ""                              \
        ""
    # Regenerate GRUB config to remove snapshot entries
    log_info "Regenerating GRUB config to remove snapshot entries..."
    case "$DISTRO_FAMILY" in
        arch)          run_cmd sudo grub-mkconfig -o /boot/grub/grub.cfg   ;;
        fedora)        run_cmd sudo grub2-mkconfig -o /boot/grub2/grub.cfg ;;
        ubuntu|debian) run_cmd sudo update-grub                             ;;
    esac
}

_profile_systemd-boot-btrfs() {
    do_remove \
        "systemd-boot-btrfs"            \
        "systemd-boot-btrfs"            \
        ""                              \
        ""
    # Remove generated snapshot boot entries from /boot/loader/entries/
    log_info "Removing generated snapshot boot entries..."
    if [[ "$DRY_RUN" != true ]]; then
        sudo find /boot/loader/entries/ -name "*.conf" -path "*snapshot*" -delete 2>/dev/null || true
    else
        log_info "[DRY-RUN] Would delete snapshot *.conf files from /boot/loader/entries/"
    fi
}

_profile_limine-snapper-sync() {
    do_remove \
        "limine-snapper-sync"           \
        "limine-snapper-sync"           \
        ""                              \
        ""
}

# ------------------------------------------------------------------------------
# PROTON DRIVE
# ------------------------------------------------------------------------------

_profile_proton-drive() {
    # Unmount before removing the service — rclone holds the FUSE mount open
    log_info "Unmounting Proton Drive if mounted..."
    if mountpoint -q "${HOME}/ProtonDrive" 2>/dev/null; then
        run_cmd fusermount3 -u "${HOME}/ProtonDrive" || true
    fi
    do_remove \
        ""                              \
        ""                              \
        "rclone-proton"                 \
        ""
    # Remove the mount point directory only if it's empty
    if [[ -d "${HOME}/ProtonDrive" ]] && [[ -z "$(ls -A "${HOME}/ProtonDrive")" ]]; then
        run_cmd rm -rf "${HOME}/ProtonDrive"
        log_info "Removed empty mount point: ~/ProtonDrive"
    else
        log_warn "~/ProtonDrive is not empty — leaving it in place"
    fi
}

# ------------------------------------------------------------------------------
# FIREWALLS
# ------------------------------------------------------------------------------

_profile_ufw() {
    log_info "Disabling ufw before removal..."
    run_cmd sudo ufw disable || true
    do_remove \
        "ufw"                           \
        "ufw"                           \
        ""                              \
        "/etc/ufw"
}

_profile_firewalld() {
    do_remove \
        "firewalld"                     \
        "firewalld"                     \
        ""                              \
        "/etc/firewalld"
}

_profile_nftables() {
    do_remove \
        "nftables"                       \
        "nftables"                       \
        ""                               \
        "/etc/nftables.conf"
}

# ------------------------------------------------------------------------------
# ANTIVIRUS
# ------------------------------------------------------------------------------

_profile_clamav() {
    do_remove \
        "clamav clamav-update"          \
        "clamav-freshclam clamav-daemon" \
        "clamav-scan.timer clamav-scan" \
        "/etc/clamav"
}

# ------------------------------------------------------------------------------
# DESKTOP / COMPOSITOR
# ------------------------------------------------------------------------------

_profile_sway() {
    do_remove \
        "sway"                          \
        ""                              \
        ""                              \
        "${HOME}/.config/sway"
}

_profile_swayfx() {
    do_remove \
        "swayfx"                        \
        ""                              \
        ""                              \
        "${HOME}/.config/sway"
}

_profile_waybar() {
    do_remove \
        "waybar"                        \
        ""                              \
        ""                              \
        "${HOME}/.config/waybar"
}

# ------------------------------------------------------------------------------
# CONTAINER TOOLS
# ------------------------------------------------------------------------------

_profile_podman() {
    do_remove \
        "podman podman-compose"         \
        "podman.socket"                 \
        ""                              \
        "${HOME}/.config/containers /etc/containers"
}

_profile_distrobox() {
    # Distrobox lets you run other Linux distros as containers sharing your home
    # directory and shell — e.g. running apt packages on Arch without a full VM.
    # Commented out in packages/common.txt by default; uncomment to install.
    # WARNING: this removes all distrobox container state. Export your data first.
    do_remove \
        "distrobox"                     \
        ""                              \
        ""                              \
        "${HOME}/.local/share/distrobox"
}

_profile_toolbox() {
    # Toolbox (toolbx) is Red Hat's container tool — similar to distrobox but
    # simpler and Fedora-first. Uses Podman under the hood and is designed for
    # running Fedora/RHEL container images as a dev environment.
    # Commented out in packages/common.txt by default; uncomment to install.
    # WARNING: this removes all toolbox containers. Export your data first.
    do_remove \
        "toolbox"                       \
        ""                              \
        ""                              \
        "${HOME}/.local/share/containers/storage/volumes"
}

# ==============================================================================
# ENGINE — do not edit below unless adding new behaviour
# ==============================================================================

# ------------------------------------------------------------------------------
# do_remove <packages> <system_services> <user_services> <config_paths>
# The core function that all profiles call. Executes removal in safe order:
#   1. Stop + disable user services
#   2. Stop + disable system services
#   3. Uninstall packages
#   4. Delete config paths
# ------------------------------------------------------------------------------
do_remove() {
    local packages="$1"
    local system_services="$2"
    local user_services="$3"
    local config_paths="$4"

    # Step 1 — user services (no root needed, must be stopped before package removal)
    if [[ -n "$user_services" ]]; then
        for svc in $user_services; do
            log_info "Stopping user service: $svc"
            run_cmd systemctl --user stop "$svc"    2>/dev/null || true
            run_cmd systemctl --user disable "$svc" 2>/dev/null || true
        done
        run_cmd systemctl --user daemon-reload
    fi

    # Step 2 — system services (root, must be stopped before package removal)
    if [[ -n "$system_services" ]]; then
        for svc in $system_services; do
            log_info "Stopping system service: $svc"
            run_cmd sudo systemctl stop "$svc"    2>/dev/null || true
            run_cmd sudo systemctl disable "$svc" 2>/dev/null || true
        done
        run_cmd sudo systemctl daemon-reload
    fi

    # Step 3 — uninstall packages
    if [[ -n "$packages" ]]; then
        log_info "Removing packages: $packages"
        case "$PKG_MANAGER" in
            pacman)
                # --nosave removes package config files managed by pacman
                # shellcheck disable=SC2086
                run_cmd sudo pacman -Rns --noconfirm $packages 2>/dev/null || \
                    log_warn "Some packages may not have been installed — skipping"
                ;;
            dnf)
                # shellcheck disable=SC2086
                run_cmd sudo dnf remove -y $packages 2>/dev/null || true
                ;;
            apt)
                # --purge removes package config files managed by apt
                # shellcheck disable=SC2086
                run_cmd sudo apt-get remove --purge -y $packages 2>/dev/null || true
                run_cmd sudo apt-get autoremove -y
                ;;
        esac
    fi

    # Step 4 — delete config files and directories left behind by the package
    if [[ -n "$config_paths" ]]; then
        for path in $config_paths; do
            # Expand ~ manually since it doesn't expand inside double quotes
            path="${path/\~/$HOME}"
            if [[ -e "$path" ]]; then
                log_info "Removing config: $path"
                run_cmd sudo rm -rf "$path"
            else
                log_info "Config path not found, skipping: $path"
            fi
        done
    fi
}

# ------------------------------------------------------------------------------
# list_profiles — prints all available tool names
# ------------------------------------------------------------------------------
list_profiles() {
    echo ""
    echo "Available removal profiles:"
    echo ""
    # Find all functions named _profile_* and strip the prefix
    declare -F | awk '{print $3}' | grep '^_profile_' | sed 's/_profile_/  /' | sort
    echo ""
}

# ------------------------------------------------------------------------------
# main
# ------------------------------------------------------------------------------
main() {
    local tool="${1:-}"

    if [[ "$tool" == "--list" || -z "$tool" ]]; then
        list_profiles
        echo "Usage: bash setup/modules/10-remove.sh <tool>"
        echo "       DRY_RUN=true bash setup/modules/10-remove.sh <tool>"
        exit 0
    fi

    log_section "Module 10: Remove — $tool"

    # Check a profile exists for the requested tool
    local profile_fn="_profile_${tool}"
    if ! declare -F "$profile_fn" &>/dev/null; then
        log_error "No removal profile for '$tool'"
        log_error "Run with --list to see available profiles"
        exit 1
    fi

    # Confirm before doing anything destructive (skipped in dry-run)
    if [[ "$DRY_RUN" != true ]]; then
        echo ""
        if ! ask "This will remove '$tool' and its config files. Continue?" n; then
            log_info "Aborted."
            exit 0
        fi
        echo ""
    fi

    # Run the profile
    "$profile_fn"

    log_success "Module 10 complete — $tool removed"
}

main "$@"
