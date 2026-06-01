#!/usr/bin/env bash
# ==============================================================================
# modules/05-atomic.sh — System snapshotting and atomic rollback
# ==============================================================================
# Sets up the "atomic" layer of the system: the ability to snapshot the OS
# state and boot directly into a previous snapshot if something goes wrong.
#
# This module has two components:
#
#   A. Snapper — manages Btrfs snapshots on a timeline (hourly/daily) and
#                around package installs (via snap-pac on Arch).
#                Configured once regardless of bootloader.
#
#   B. Boot menu integration — makes snapshots bootable, so you can select
#                one from the boot menu to roll back without logging in.
#                Tool depends on which bootloader is detected:
#
#      Bootloader       Tool                  What it does
#      ─────────────────────────────────────────────────────────────────────
#      GRUB             grub-btrfs +          Watches /.snapshots and
#                       grub-btrfsd           regenerates GRUB menu entries
#
#      systemd-boot     systemd-boot-btrfs    Generates /boot/loader/entries/
#                       (AUR / community)     for each Snapper snapshot
#
#      Limine           limine-snapper-sync   Syncs Limine boot entries from
#                       (AUR)                 Snapper snapshots
#
#      unknown          —                     Warning shown, integration skipped
#
# Prerequisites:
#   - Root filesystem must be Btrfs with /.snapshots as its own subvolume
#     (set up during OS install — archinstall can do this automatically)
#   - Snapper, snap-pac, and the relevant bootloader tool must be installed
#     (handled by 03-packages.sh)
#   - Timeshift is installed separately as an additional GUI-based backup
#
# If root is not Btrfs, the module prints a warning and exits gracefully
# rather than failing the whole setup.
# ==============================================================================

[[ -n "${_MODULE_ATOMIC_LOADED:-}" ]] && return
_MODULE_ATOMIC_LOADED=1

# ------------------------------------------------------------------------------
# check_btrfs
# Exits the module early if the root filesystem is not Btrfs.
# Snapper, grub-btrfs, systemd-boot-btrfs, and limine-snapper-sync are all
# Btrfs-specific tools — they cannot be configured on ext4 or xfs.
# ------------------------------------------------------------------------------
check_btrfs() {
    if [[ "$ROOT_FS" != "btrfs" ]]; then
        log_warn "Root filesystem is '$ROOT_FS', not btrfs — skipping snapshot setup"
        log_warn "To use snapshotting, reinstall with Btrfs and a separate /.snapshots subvolume"
        return 1
    fi
    return 0
}

# ------------------------------------------------------------------------------
# setup_snapper
# Configures Snapper for the root subvolume (/):
#   - Creates the Snapper config if it doesn't exist yet
#   - Sets conservative limits: 5 hourly, 7 daily snapshots kept
#   - Enables the snapper-timeline timer (creates snapshots on schedule)
#   - Enables the snapper-cleanup timer (prunes old snapshots)
#
# On Arch, snap-pac (installed by 03-packages.sh) automatically hooks into
# pacman to create pre/post snapshots around every upgrade. No extra config
# is needed for that here.
# ------------------------------------------------------------------------------
setup_snapper() {
    log_section "Snapper"

    if ! cmd_exists snapper; then
        log_warn "snapper not found — was it installed by 03-packages.sh?"
        return 1
    fi

    # Create the root config only if it doesn't already exist.
    # snapper create-config sets up /.snapshots and writes /etc/snapper/configs/root
    if [[ ! -f /etc/snapper/configs/root ]]; then
        log_info "Creating Snapper config for /"
        run_cmd sudo snapper -c root create-config /
    else
        log_info "Snapper root config already exists, skipping creation"
    fi

    # Apply snapshot retention limits to /etc/snapper/configs/root.
    # These settings control how many snapshots of each type Snapper keeps before
    # cleaning up old ones. The values below are a reasonable default:
    #   5 hourly  — enough to catch recent mistakes within a workday
    #   7 daily   — one week of daily restore points
    #   0 weekly/monthly/yearly — not needed alongside daily snapshots
    log_info "Applying Snapper retention limits..."
    if [[ "$DRY_RUN" != true ]]; then
        sudo snapper -c root set-config \
            TIMELINE_CREATE=yes         \
            TIMELINE_CLEANUP=yes        \
            NUMBER_LIMIT=10             \
            TIMELINE_LIMIT_HOURLY=5     \
            TIMELINE_LIMIT_DAILY=7      \
            TIMELINE_LIMIT_WEEKLY=0     \
            TIMELINE_LIMIT_MONTHLY=0    \
            TIMELINE_LIMIT_YEARLY=0
    else
        log_info "[DRY-RUN] Would set Snapper retention: 5 hourly, 7 daily"
    fi

    # Enable the systemd timers that run Snapper on schedule
    systemd_enable snapper-timeline.timer  # creates snapshots
    systemd_enable snapper-cleanup.timer   # prunes old snapshots

    log_success "Snapper configured"
}

# ------------------------------------------------------------------------------
# setup_timeshift
# Writes a Timeshift configuration file that schedules daily backups at 21:00.
# Timeshift is a complementary tool to Snapper — it provides a GUI for browsing
# and restoring snapshots, which is useful for less technical users or as a
# safety net alongside Snapper's automated timeline.
#
# Timeshift requires cronie (cron daemon) for scheduled snapshots — enabled here.
# The UUID for the backup device is left blank; Timeshift will auto-detect it
# on first launch.
# ------------------------------------------------------------------------------
setup_timeshift() {
    log_section "Timeshift"

    if ! cmd_exists timeshift; then
        log_warn "timeshift not found — was it installed by 03-packages.sh?"
        return
    fi

    local config_dir="/etc/timeshift"
    local config_file="$config_dir/timeshift.json"

    if [[ -f "$config_file" ]]; then
        log_info "Timeshift config already exists, skipping"
    else
        log_info "Writing Timeshift config (daily at 21:00, Btrfs mode)..."
        if [[ "$DRY_RUN" != true ]]; then
            sudo mkdir -p "$config_dir"
            sudo tee "$config_file" > /dev/null << 'EOF'
{
  "backup_device_uuid": "",
  "do_first_run_after_boot": "false",
  "btrfs_mode": "true",
  "include_btrfs_home_for_backup": "false",
  "include_btrfs_home_for_restore": "false",
  "schedule_monthly": "false",
  "schedule_weekly": "false",
  "schedule_daily": "true",
  "schedule_hourly": "false",
  "schedule_boot": "false",
  "schedule_day": "0",
  "schedule_hour": "21",
  "schedule_minute": "0",
  "count_monthly": "2",
  "count_weekly": "3",
  "count_daily": "5",
  "count_hourly": "6",
  "count_boot": "5",
  "snapshot_size": "",
  "snapshot_count": "",
  "date_format": "%Y-%m-%d %H:%M:%S",
  "exclude": [],
  "exclude-apps": []
}
EOF
        else
            log_info "[DRY-RUN] Would write $config_file"
        fi
    fi

    # Timeshift uses cron for scheduling; enable the cron daemon
    case "$DISTRO_FAMILY" in
        arch|fedora) systemd_enable cronie ;;
        ubuntu|debian) systemd_enable cron ;;
    esac

    log_success "Timeshift configured (daily backup at 21:00)"
}

# ------------------------------------------------------------------------------
# setup_bootloader_integration
# Dispatches to the correct boot-menu integration tool based on BOOTLOADER.
# Without this step, snapshots exist on disk but can't be booted into directly.
# ------------------------------------------------------------------------------
setup_bootloader_integration() {
    log_section "Boot menu integration (bootloader: $BOOTLOADER)"

    case "$BOOTLOADER" in
        grub)         _setup_grub_btrfs       ;;
        systemd-boot) _setup_systemd_boot_btrfs ;;
        limine)       _setup_limine_snapper    ;;
        *)
            log_warn "Bootloader not detected or unsupported: '$BOOTLOADER'"
            log_warn "Boot menu snapshot integration skipped."
            log_warn "You can still roll back using: sudo snapper rollback <number>"
            ;;
    esac
}

# ------------------------------------------------------------------------------
# _setup_grub_btrfs
# Installs grub-btrfs and its companion daemon grub-btrfsd.
#
# grub-btrfs:   Scans /.snapshots and generates GRUB menu entries for each one.
# grub-btrfsd:  A daemon that watches /.snapshots with inotify and triggers a
#               GRUB config regeneration whenever a snapshot is created or deleted.
#               This keeps the boot menu in sync automatically without any
#               manual intervention after upgrades.
#
# After installing, grub-mkconfig is run once to populate the menu immediately.
# The correct grub-mkconfig path differs by distro.
# ------------------------------------------------------------------------------
_setup_grub_btrfs() {
    log_info "Setting up grub-btrfs (GRUB snapshot boot entries)..."

    # grub-btrfs is a pacman package on Arch; on Fedora/Debian it may need
    # to be built from source — the package module handles this.
    if ! cmd_exists grub-btrfsd && [[ "$DISTRO_FAMILY" == "arch" ]]; then
        log_info "Installing grub-btrfs and inotify-tools via paru..."
        run_cmd paru -S --needed --noconfirm grub-btrfs inotify-tools
    fi

    # Enable grub-btrfsd so the GRUB menu updates automatically on each snapshot
    systemd_enable grub-btrfsd

    # Run grub-mkconfig once now to add existing snapshots to the boot menu
    log_info "Regenerating GRUB config..."
    case "$DISTRO_FAMILY" in
        arch)          run_cmd sudo grub-mkconfig -o /boot/grub/grub.cfg    ;;
        fedora)        run_cmd sudo grub2-mkconfig -o /boot/grub2/grub.cfg  ;;
        ubuntu|debian) run_cmd sudo update-grub                              ;;
        *)             log_warn "Don't know how to run grub-mkconfig on '$DISTRO_FAMILY'" ;;
    esac

    log_success "grub-btrfs configured — snapshots will appear in GRUB menu"
}

# ------------------------------------------------------------------------------
# _setup_systemd_boot_btrfs
# Installs systemd-boot-btrfs, which generates /boot/loader/entries/*.conf
# files for each Snapper snapshot so they appear as selectable boot entries
# in the systemd-boot menu.
#
# systemd-boot-btrfs is available on the AUR (Arch) and as a community package
# on some other distros. The service watches /.snapshots and regenerates entries
# automatically when snapshots change.
# ------------------------------------------------------------------------------
_setup_systemd_boot_btrfs() {
    log_info "Setting up systemd-boot-btrfs (systemd-boot snapshot entries)..."

    if ! cmd_exists systemd-boot-btrfs; then
        case "$DISTRO_FAMILY" in
            arch)
                # Install from AUR via paru
                log_info "Installing systemd-boot-btrfs via paru (AUR)..."
                run_cmd paru -S --needed --noconfirm systemd-boot-btrfs
                ;;
            *)
                # On non-Arch distros, the package may not exist in standard repos.
                # Attempt a generic install; the package module should have tried
                # to install it already if it's available.
                log_warn "systemd-boot-btrfs not found and auto-install only supported on Arch"
                log_warn "Install it manually: https://github.com/andrewgregory/systemd-boot-btrfs"
                return 1
                ;;
        esac
    fi

    # Enable the service that keeps boot entries in sync with snapshots
    systemd_enable systemd-boot-btrfs.service

    # Run once immediately to generate entries for existing snapshots
    if [[ "$DRY_RUN" != true ]]; then
        log_info "Generating initial systemd-boot snapshot entries..."
        sudo systemd-boot-btrfs || log_warn "Initial systemd-boot-btrfs run failed (snapshots may not exist yet)"
    fi

    log_success "systemd-boot-btrfs configured — snapshots appear in boot menu"
}

# ------------------------------------------------------------------------------
# _setup_limine_snapper
# Installs limine-snapper-sync (AUR — Arch only), which watches /.snapshots
# and updates the Limine bootloader config to add/remove entries as snapshots
# are created and deleted by Snapper.
# ------------------------------------------------------------------------------
_setup_limine_snapper() {
    log_info "Setting up limine-snapper-sync (Limine snapshot entries)..."

    if [[ "$DISTRO_FAMILY" != "arch" ]]; then
        log_warn "limine-snapper-sync is AUR-only — skipping on non-Arch systems"
        return 1
    fi

    if ! cmd_exists limine-snapper-sync; then
        log_info "Installing limine-snapper-sync via paru (AUR)..."
        run_cmd paru -S --needed --noconfirm limine-snapper-sync
    fi

    # Enable the service that watches /.snapshots and updates Limine entries
    systemd_enable limine-snapper-sync

    # Run once now to sync existing snapshots into the Limine config
    if [[ "$DRY_RUN" != true ]]; then
        log_info "Running initial limine-snapper-sync..."
        sudo limine-snapper-sync || log_warn "Initial sync failed (no snapshots yet?)"
    fi

    log_success "limine-snapper-sync configured — snapshots appear in Limine menu"
}

# ------------------------------------------------------------------------------
# main
# ------------------------------------------------------------------------------
main() {
    log_section "Module 05: Atomic (Snapshotting)"

    # Exit early if root is not Btrfs — nothing in this module applies
    check_btrfs || return 0

    setup_snapper
    setup_timeshift
    setup_bootloader_integration

    log_success "Module 05 complete"
    log_info "Rollback: snapper list  →  sudo snapper rollback <number>"
}

main "$@"
