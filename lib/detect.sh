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
#                    "macos" on macOS
#   OS_ID_LIKE     — space-separated list of similar distros (linux only)
#   OS_NAME        — human-readable name  (e.g. "Arch Linux", "macOS 15.0")
#   OS_VERSION     — version string       (e.g. "40" for Fedora 40)
#   DISTRO_FAMILY  — arch | fedora | ubuntu | debian | macos | unknown
#   PKG_MANAGER    — pacman | dnf | apt | brew | unknown
#   ROOT_FS        — filesystem type of / (e.g. "btrfs", "apfs", "ext4")
#   BOOTLOADER     — grub | systemd-boot | limine | unknown (always unknown on macOS)
#   CPU_VENDOR     — intel | amd | apple | unknown
#   GPU_VENDOR     — nvidia | amd | intel | apple | unknown
# ==============================================================================

# ------------------------------------------------------------------------------
# detect_os
# On Linux reads /etc/os-release and maps the ID to a known family.
# On macOS reads sw_vers to get the version, and sets DISTRO_FAMILY="macos".
# ------------------------------------------------------------------------------
detect_os() {
    # macOS doesn't have /etc/os-release — detect it first via uname
    if [[ "$(uname -s)" == "Darwin" ]]; then
        OS_ID="macos"
        OS_ID_LIKE=""
        OS_NAME="macOS $(sw_vers -productVersion 2>/dev/null || echo '')"
        OS_VERSION="$(sw_vers -productVersion 2>/dev/null || echo '')"
        DISTRO_FAMILY="macos"
        export OS_ID OS_ID_LIKE OS_NAME OS_VERSION DISTRO_FAMILY
        return
    fi

    if [[ -f /etc/os-release ]]; then
        # shellcheck source=/dev/null
        . /etc/os-release
        OS_ID="${ID:-unknown}"
        OS_ID_LIKE="${ID_LIKE:-}"
        OS_NAME="${NAME:-unknown}"
        OS_VERSION="${VERSION_ID:-}"
    else
        OS_ID="unknown"
        OS_ID_LIKE=""
        OS_NAME="unknown"
        OS_VERSION=""
    fi

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
# On macOS, Homebrew is the package manager. brew may not be in PATH yet on a
# fresh machine — we still set PKG_MANAGER="brew" so modules know what to use,
# and module 02-repos.sh handles installing Homebrew if it's missing.
# ------------------------------------------------------------------------------
detect_pkg_manager() {
    case "$DISTRO_FAMILY" in
        arch)          PKG_MANAGER="pacman" ;;
        fedora)        PKG_MANAGER="dnf"    ;;
        ubuntu|debian) PKG_MANAGER="apt"    ;;
        macos)         PKG_MANAGER="brew"   ;;
        *)
            if   command -v pacman &>/dev/null; then PKG_MANAGER="pacman"
            elif command -v dnf    &>/dev/null; then PKG_MANAGER="dnf"
            elif command -v apt    &>/dev/null; then PKG_MANAGER="apt"
            elif command -v brew   &>/dev/null; then PKG_MANAGER="brew"
            else PKG_MANAGER="unknown"
            fi ;;
    esac
    export PKG_MANAGER
}

# ------------------------------------------------------------------------------
# detect_filesystem
# On Linux uses findmnt. On macOS uses diskutil to get the filesystem type of
# the root volume — almost always "apfs" on modern Macs.
# Snapshotting modules check ROOT_FS and skip themselves on non-Btrfs / APFS.
# ------------------------------------------------------------------------------
detect_filesystem() {
    if [[ "$DISTRO_FAMILY" == "macos" ]]; then
        # diskutil info / | grep "Type" gives e.g. "Type (Bundle):  apfs"
        ROOT_FS="$(diskutil info / 2>/dev/null | awk '/Type \(Bundle\)/{print $NF}' || echo "apfs")"
    else
        ROOT_FS="$(findmnt -n -o FSTYPE / 2>/dev/null || echo "unknown")"
    fi
    export ROOT_FS
}

# ------------------------------------------------------------------------------
# detect_bootloader
# Not applicable on macOS — the bootloader is the Apple firmware (iBoot) which
# can't be configured from userspace. Set to "unknown" and modules that care
# about the bootloader skip themselves on macOS.
# ------------------------------------------------------------------------------
detect_bootloader() {
    if [[ "$DISTRO_FAMILY" == "macos" ]]; then
        BOOTLOADER="unknown"
        export BOOTLOADER
        return
    fi

    BOOTLOADER="unknown"

    if [[ -d /boot/loader/entries ]] || [[ -f /boot/loader/loader.conf ]]; then
        BOOTLOADER="systemd-boot"
    elif [[ -f /boot/grub/grub.cfg ]] || [[ -f /boot/grub2/grub.cfg ]]; then
        BOOTLOADER="grub"
    elif [[ -f /boot/limine.conf ]] || [[ -f /boot/limine/limine.conf ]]; then
        BOOTLOADER="limine"
    elif command -v bootctl &>/dev/null && bootctl status 2>/dev/null | grep -qi "systemd-boot"; then
        BOOTLOADER="systemd-boot"
    fi

    export BOOTLOADER
}

# ------------------------------------------------------------------------------
# detect_cpu
# On Linux reads /proc/cpuinfo. On macOS uses sysctl.
# Apple Silicon (M1/M2/M3/M4) reports as "apple" — no microcode package exists
# for Apple Silicon since the firmware is managed by Apple directly.
# ------------------------------------------------------------------------------
detect_cpu() {
    if [[ "$DISTRO_FAMILY" == "macos" ]]; then
        local brand
        brand="$(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo '')"
        if echo "$brand" | grep -qi "apple"; then
            CPU_VENDOR="apple"
        elif echo "$brand" | grep -qi "intel"; then
            CPU_VENDOR="intel"
        else
            CPU_VENDOR="unknown"
        fi
        export CPU_VENDOR
        return
    fi

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
# On Linux uses lspci. On macOS uses system_profiler — works for both
# integrated and discrete GPUs, including Apple Silicon's integrated GPU.
# ------------------------------------------------------------------------------
detect_gpu() {
    if [[ "$DISTRO_FAMILY" == "macos" ]]; then
        local gpu_info
        gpu_info="$(system_profiler SPDisplaysDataType 2>/dev/null | grep -i "chipset\|vendor\|model")"
        if echo "$gpu_info" | grep -qi "apple"; then
            GPU_VENDOR="apple"
        elif echo "$gpu_info" | grep -qi "nvidia"; then
            GPU_VENDOR="nvidia"
        elif echo "$gpu_info" | grep -qi "amd\|radeon"; then
            GPU_VENDOR="amd"
        elif echo "$gpu_info" | grep -qi "intel"; then
            GPU_VENDOR="intel"
        else
            GPU_VENDOR="unknown"
        fi
        export GPU_VENDOR
        return
    fi

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
# ------------------------------------------------------------------------------
detect_all() {
    detect_os
    detect_pkg_manager
    detect_filesystem
    detect_bootloader
    detect_cpu
    detect_gpu
}
