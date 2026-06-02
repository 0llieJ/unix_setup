#!/usr/bin/env bash
# ==============================================================================
# lib/detect.sh — OS, filesystem, and bootloader detection
# ==============================================================================
# Reads the running system and exports variables that every other module uses
# to decide what to install and how to configure things.
# Source this file from any module — do not execute it directly.
#
# After calling detect_all(), the following variables are available everywhere:
#
#   OS_ID          — raw distro ID from /etc/os-release  (e.g. "arch", "fedora")
#   OS_ID_LIKE     — space-separated list of similar distros (e.g. "debian ubuntu")
#   OS_NAME        — human-readable distro name           (e.g. "Arch Linux")
#   OS_VERSION     — version string if the distro has one (e.g. "40" for Fedora 40)
#   DISTRO_FAMILY  — normalised family: arch | fedora | ubuntu | debian | unknown
#   PKG_MANAGER    — package manager to use: pacman | dnf | apt | unknown
#   ROOT_FS        — filesystem type of /                 (e.g. "btrfs", "ext4")
#   BOOTLOADER     — detected bootloader: grub | systemd-boot | limine | unknown
# ==============================================================================

# ------------------------------------------------------------------------------
# detect_os
# Reads /etc/os-release (the standard Linux distro identification file) and
# maps the raw ID to one of four known families. Derivatives like CachyOS and
# EndeavourOS are recognised as Arch; Rocky and Alma are recognised as Fedora.
# ID_LIKE is used as a fallback for distros that don't match a known ID directly.
# ------------------------------------------------------------------------------
detect_os() {
    if [[ -f /etc/os-release ]]; then
        # Source the file — it sets ID, ID_LIKE, NAME, VERSION_ID, etc.
        # shellcheck source=/dev/null
        . /etc/os-release
        OS_ID="${ID:-unknown}"
        OS_ID_LIKE="${ID_LIKE:-}"
        OS_NAME="${NAME:-unknown}"
        OS_VERSION="${VERSION_ID:-}"
    else
        # /etc/os-release missing — very old or unusual system
        OS_ID="unknown"
        OS_ID_LIKE=""
        OS_NAME="unknown"
        OS_VERSION=""
    fi

    # Map the raw distro ID to a normalised family string.
    # Modules use DISTRO_FAMILY rather than OS_ID so they don't need to know
    # about every Arch/Fedora/Debian derivative individually.
    case "$OS_ID" in
        arch|cachyos|endeavouros|garuda|manjaro)
            DISTRO_FAMILY="arch" ;;
        fedora|rhel|centos|rocky|almalinux)
            DISTRO_FAMILY="fedora" ;;
        ubuntu)
            DISTRO_FAMILY="ubuntu" ;;
        debian)
            DISTRO_FAMILY="debian" ;;
        *)
            # ID didn't match — try ID_LIKE (e.g. Linux Mint has ID_LIKE="ubuntu")
            case "$OS_ID_LIKE" in
                *arch*)          DISTRO_FAMILY="arch"   ;;
                *fedora*|*rhel*) DISTRO_FAMILY="fedora" ;;
                *ubuntu*)        DISTRO_FAMILY="ubuntu" ;;
                *debian*)        DISTRO_FAMILY="debian" ;;
                *)               DISTRO_FAMILY="unknown" ;;
            esac ;;
    esac

    export OS_ID OS_ID_LIKE OS_NAME OS_VERSION DISTRO_FAMILY
}

# ------------------------------------------------------------------------------
# detect_pkg_manager
# Sets PKG_MANAGER based on DISTRO_FAMILY. Must be called after detect_os().
# Falls back to probing $PATH if the family is unknown.
# ------------------------------------------------------------------------------
detect_pkg_manager() {
    case "$DISTRO_FAMILY" in
        arch)          PKG_MANAGER="pacman" ;;
        fedora)        PKG_MANAGER="dnf"    ;;
        ubuntu|debian) PKG_MANAGER="apt"    ;;
        *)
            # Unknown family — check what's actually installed
            if   command -v pacman &>/dev/null; then PKG_MANAGER="pacman"
            elif command -v dnf    &>/dev/null; then PKG_MANAGER="dnf"
            elif command -v apt    &>/dev/null; then PKG_MANAGER="apt"
            else PKG_MANAGER="unknown"
            fi ;;
    esac
    export PKG_MANAGER
}

# ------------------------------------------------------------------------------
# detect_filesystem
# Uses `findmnt` to check the filesystem type of the root partition (/).
# This is used by the atomic module (05-atomic.sh) to decide whether
# snapper/grub-btrfs/systemd-boot-btrfs should be set up — those tools only
# work on Btrfs. If the root is ext4 or xfs, snapshotting is skipped or falls
# back to Timeshift in rsync mode.
# ------------------------------------------------------------------------------
detect_filesystem() {
    ROOT_FS="$(findmnt -n -o FSTYPE / 2>/dev/null || echo "unknown")"
    export ROOT_FS
}

# ------------------------------------------------------------------------------
# detect_bootloader
# Checks known paths and EFI entries to figure out which bootloader is in use.
# The result drives which snapshot-boot-menu integration tool gets installed:
#
#   grub         → grub-btrfs + grub-btrfsd (auto-updates GRUB menu from snapshots)
#   systemd-boot → systemd-boot-btrfs (AUR) — generates loader entries per snapshot
#   limine       → limine-snapper-sync (AUR) — syncs Limine entries from snapshots
#   unknown      → warning shown; boot menu integration is skipped
#
# Detection order matters — systemd-boot is checked first because /boot/loader
# can coexist with a grub.cfg on some setups.
# ------------------------------------------------------------------------------
detect_bootloader() {
    BOOTLOADER="unknown"

    # systemd-boot creates a /boot/loader directory with loader.conf and an
    # entries/ subdirectory for individual boot entries.
    if [[ -d /boot/loader/entries ]] || [[ -f /boot/loader/loader.conf ]]; then
        BOOTLOADER="systemd-boot"

    # GRUB writes its config to /boot/grub/grub.cfg (Arch/Ubuntu/Debian) or
    # /boot/grub2/grub.cfg (Fedora/RHEL).
    elif [[ -f /boot/grub/grub.cfg ]] || [[ -f /boot/grub2/grub.cfg ]]; then
        BOOTLOADER="grub"

    # Limine stores its config at /boot/limine.conf or /boot/limine/limine.conf
    elif [[ -f /boot/limine.conf ]] || [[ -f /boot/limine/limine.conf ]]; then
        BOOTLOADER="limine"

    # Last resort — ask bootctl (systemd-boot's management tool) if it's active.
    # This catches installs where /boot/loader exists on a separate EFI partition
    # that isn't mounted at detection time.
    elif command -v bootctl &>/dev/null && bootctl status 2>/dev/null | grep -qi "systemd-boot"; then
        BOOTLOADER="systemd-boot"
    fi

    export BOOTLOADER
}

# ------------------------------------------------------------------------------
# detect_cpu
# Reads /proc/cpuinfo to identify the CPU vendor.
# Sets CPU_VENDOR to "intel", "amd", or "unknown".
# Used by module 12 to install the correct microcode package.
# ------------------------------------------------------------------------------
detect_cpu() {
    local vendor
    vendor=$(grep -m1 "vendor_id" /proc/cpuinfo 2>/dev/null | awk '{print $3}')
    case "$vendor" in
        GenuineIntel) CPU_VENDOR="intel" ;;
        AuthenticAMD) CPU_VENDOR="amd"   ;;
        *)            CPU_VENDOR="unknown" ;;
    esac
    export CPU_VENDOR
}

# ------------------------------------------------------------------------------
# detect_gpu
# Uses lspci to identify the discrete GPU vendor.
# Sets GPU_VENDOR to "nvidia", "amd", "intel", or "unknown".
# Used by module 12 to install the correct GPU driver.
# Note: on systems with both integrated and discrete GPUs, discrete takes
# priority (checked first).
# ------------------------------------------------------------------------------
detect_gpu() {
    if ! command -v lspci &>/dev/null; then
        GPU_VENDOR="unknown"
        export GPU_VENDOR
        return
    fi

    local lspci_out
    lspci_out=$(lspci 2>/dev/null)

    if echo "$lspci_out" | grep -qi "nvidia"; then
        GPU_VENDOR="nvidia"
    elif echo "$lspci_out" | grep -qiE "radeon|amd.*display|advanced micro.*display"; then
        GPU_VENDOR="amd"
    elif echo "$lspci_out" | grep -qi "intel.*display\|intel.*graphics\|intel.*uhd\|intel.*iris"; then
        GPU_VENDOR="intel"
    else
        GPU_VENDOR="unknown"
    fi

    export GPU_VENDOR
}

# ------------------------------------------------------------------------------
# detect_all — convenience wrapper that runs every detection function in order.
# Call this once at the top of setup.sh; all modules inherit the exported vars.
# ------------------------------------------------------------------------------
detect_all() {
    detect_os
    detect_pkg_manager
    detect_filesystem
    detect_bootloader
    detect_cpu
    detect_gpu
}
