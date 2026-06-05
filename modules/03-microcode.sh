#!/usr/bin/env bash
# ==============================================================================
# modules/03-microcode.sh — CPU microcode installation
# ==============================================================================
# Runs immediately after the full system update. Installs Intel or AMD CPU
# firmware updates and refreshes the initramfs/bootloader when required.
# ==============================================================================

[[ -n "${_MODULE_MICROCODE_LOADED:-}" ]] && return
_MODULE_MICROCODE_LOADED=1

if [[ -z "${SETUP_DIR:-}" ]]; then
    SETUP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    source "$SETUP_DIR/lib/log.sh"
    source "$SETUP_DIR/lib/detect.sh"
    source "$SETUP_DIR/lib/utils.sh"
    detect_all
fi

install_microcode() {
    log_section "CPU microcode (vendor: $CPU_VENDOR)"

    if [[ "$SYSTEM_PROFILE" == "atomic" ]]; then
        log_info "Atomic system detected — microcode is supplied by the base image"
        return
    fi

    case "$CPU_VENDOR" in
        apple)
            log_info "Apple firmware is managed by macOS Software Update"
            return
            ;;
        unknown)
            log_warn "Could not detect CPU vendor — skipping microcode installation"
            return
            ;;
    esac

    case "$DISTRO_FAMILY" in
        arch)          _microcode_arch ;;
        fedora)        _microcode_fedora ;;
        ubuntu|debian) _microcode_debian ;;
        macos)         log_info "macOS firmware is managed by Software Update" ;;
        *)             log_warn "No microcode method for distro: $DISTRO_FAMILY" ;;
    esac
}

_microcode_arch() {
    local pkg
    case "$CPU_VENDOR" in
        intel) pkg="intel-ucode" ;;
        amd)   pkg="amd-ucode" ;;
    esac

    run_cmd sudo pacman -S --needed --noconfirm "$pkg"
    _rebuild_initramfs

    if [[ "$BOOTLOADER" == "grub" ]] && cmd_exists grub-mkconfig; then
        run_cmd sudo grub-mkconfig -o /boot/grub/grub.cfg
    fi

    log_success "$pkg installed — active after reboot"
}

_microcode_fedora() {
    run_cmd sudo dnf install -y microcode_ctl
    log_success "microcode_ctl installed"
}

_microcode_debian() {
    local pkg
    case "$CPU_VENDOR" in
        intel) pkg="intel-microcode" ;;
        amd)   pkg="amd64-microcode" ;;
    esac

    run_cmd sudo apt-get install -y "$pkg"
    log_success "$pkg installed"
}

_rebuild_initramfs() {
    if cmd_exists mkinitcpio; then
        run_cmd sudo mkinitcpio -P
    elif cmd_exists dracut; then
        run_cmd sudo dracut --regenerate-all --force
    else
        log_warn "No supported initramfs builder found; package hooks may handle it"
    fi
}

main() {
    log_section "Module 03: CPU microcode"
    install_microcode
    log_success "CPU microcode step complete"
}

main "$@"
