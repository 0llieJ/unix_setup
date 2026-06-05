#!/usr/bin/env bash
# ==============================================================================
# modules/12-hardware.sh — GPU drivers
# ==============================================================================
# OPTIONAL MODULE — not in the default setup.sh run.
# Run after the main setup (modules 01-09) has completed.
#
# Usage:
#   bash ~/unix_setup/modules/12-hardware.sh
#   bash ~/unix_setup/setup.sh --only 12
#
# Detects your GPU vendor and installs the appropriate driver stack:
#
#      Vendor   Driver              Notes
#      ───────────────────────────────────────────────────────────────────────
#      Nvidia   nvidia-open         Pre-built for stock Arch kernel
#               nvidia-open-dkms    DKMS build for CachyOS / lts / zen kernels
#               akmod-nvidia        Fedora (RPM Fusion, auto-rebuilds on upgrade)
#               ubuntu-drivers      Ubuntu/Debian (auto-selects recommended)
#
#      AMD      amdgpu (in-kernel)  No driver install needed — built into Linux.
#               + mesa / vulkan     Mesa provides the OpenGL and Vulkan userspace
#               + VA-API / VDPAU    layer and hardware video decode support.
#
#      Intel    i915/xe (in-kernel) No driver install needed — built into Linux.
#               + mesa / vulkan     Same as AMD — Mesa + hardware video decode.
#               + intel-media-driver VA-API for Gen 8+ (Broadwell and newer).
#
# AMD and Intel both use open-source drivers built into the kernel. There is
# nothing to install for the driver itself. What this module installs is the
# Mesa userspace stack (OpenGL, Vulkan) and hardware video acceleration support
# which are needed for smooth rendering, gaming, and video playback.
# ==============================================================================

[[ -n "${_MODULE_HARDWARE_LOADED:-}" ]] && return
_MODULE_HARDWARE_LOADED=1

# When run standalone (not via setup.sh), SETUP_DIR and the shared libs won't
# be loaded yet. Detect the script's own location and source them directly.
if [[ -z "${SETUP_DIR:-}" ]]; then
    SETUP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    source "$SETUP_DIR/lib/log.sh"
    source "$SETUP_DIR/lib/detect.sh"
    source "$SETUP_DIR/lib/utils.sh"
    detect_all
fi

# ==============================================================================
# GPU DRIVERS
# ==============================================================================

# ------------------------------------------------------------------------------
# install_gpu_drivers
# Dispatches to the correct installer based on GPU_VENDOR, which is set by
# detect_gpu() in lib/detect.sh when setup.sh runs detect_all().
# ------------------------------------------------------------------------------
install_gpu_drivers() {
    log_section "GPU drivers (vendor: $GPU_VENDOR)"

    case "$GPU_VENDOR" in
        nvidia) _install_nvidia ;;
        amd)    _install_amd    ;;
        intel)  _install_intel  ;;
        *)
            log_warn "GPU not detected or vendor unrecognised — skipping GPU driver install"
            log_warn "Run 'lspci | grep -iE \"display|vga|3d\"' to check your GPU"
            ;;
    esac
}

# ==============================================================================
# NVIDIA
# ==============================================================================

# Edit these lists if you need a different variant.
# Use 'nvidia' instead of 'nvidia-open' for GPUs older than Turing (pre-RTX 20xx).
ARCH_STOCK_PKGS=(nvidia-open nvidia-utils nvidia-settings lib32-nvidia-utils)
ARCH_DKMS_PKGS=(nvidia-open-dkms nvidia-utils nvidia-settings lib32-nvidia-utils)
FEDORA_NVIDIA_PKGS=(akmod-nvidia xorg-x11-drv-nvidia-cuda)

_install_nvidia() {
    log_info "Nvidia GPU — installing proprietary drivers"
    case "$DISTRO_FAMILY" in
        arch)          _nvidia_arch          ;;
        fedora)        _nvidia_fedora        ;;
        ubuntu|debian) _nvidia_ubuntu_debian ;;
        *) log_error "No Nvidia install method for: $DISTRO_FAMILY"; return 1 ;;
    esac
}

_nvidia_arch() {
    local kernel kernel_type="stock"
    kernel=$(uname -r)
    echo "$kernel" | grep -qiE "cachyos|lts|zen|hardened|xanmod|tkg" && kernel_type="custom"
    log_info "Kernel: $kernel ($kernel_type)"

    # Warn if the GPU may be too old for nvidia-open (requires Turing / RTX 20xx+)
    if lspci | grep -i nvidia | grep -qiE "GTX [0-9]{3}[^0-9]|GTX 10[0-9]{2}|GT [0-9]"; then
        log_warn "GPU may be pre-Turing — nvidia-open requires RTX 20xx or newer."
        log_warn "If install fails, edit ARCH_STOCK_PKGS/ARCH_DKMS_PKGS in this module"
        log_warn "to use 'nvidia' instead of 'nvidia-open'."
        ask "Continue with nvidia-open anyway?" n || { log_info "Aborted."; return 0; }
    fi

    if [[ "$kernel_type" == "custom" ]]; then
        log_info "Installing DKMS drivers (compiling against kernel — takes a few minutes)..."
        run_cmd sudo pacman -S --needed --noconfirm "${ARCH_DKMS_PKGS[@]}"
    else
        log_info "Installing pre-built drivers..."
        run_cmd sudo pacman -S --needed --noconfirm "${ARCH_STOCK_PKGS[@]}"
    fi

    # Enable DRM modesetting — required for Wayland/SwayFX
    if [[ "$DRY_RUN" != true ]]; then
        [[ -f /etc/kernel/cmdline ]] && \
            grep -q "nvidia-drm.modeset" /etc/kernel/cmdline || \
            sudo sed -i 's/$/ nvidia-drm.modeset=1 nvidia-drm.fbdev=1/' /etc/kernel/cmdline

        [[ -f /etc/default/grub ]] && \
            grep -q "nvidia-drm.modeset" /etc/default/grub || \
            sudo sed -i \
                's/GRUB_CMDLINE_LINUX_DEFAULT="\(.*\)"/GRUB_CMDLINE_LINUX_DEFAULT="\1 nvidia-drm.modeset=1 nvidia-drm.fbdev=1"/' \
                /etc/default/grub
    fi

    # Add Nvidia modules to initramfs for early GPU availability at boot
    if [[ "$DRY_RUN" != true ]]; then
        if [[ -f /etc/mkinitcpio.conf ]] && ! grep -q "nvidia" /etc/mkinitcpio.conf; then
            sudo sed -i \
                's/^MODULES=(\(.*\))/MODULES=(\1 nvidia nvidia_modeset nvidia_uvm nvidia_drm)/' \
                /etc/mkinitcpio.conf
        fi
        run_cmd sudo mkinitcpio -P
    else
        log_info "[DRY-RUN] Would add nvidia modules to mkinitcpio.conf and rebuild initramfs"
    fi

    log_success "Nvidia drivers installed — reboot required"
}

_nvidia_fedora() {
    log_info "Installing via RPM Fusion (akmod builds in background — takes a few minutes)..."
    run_cmd sudo dnf install -y "${FEDORA_NVIDIA_PKGS[@]}"
    if [[ -f /etc/default/grub ]] && [[ "$DRY_RUN" != true ]]; then
        grep -q "nvidia-drm.modeset" /etc/default/grub || sudo sed -i \
            's/GRUB_CMDLINE_LINUX="\(.*\)"/GRUB_CMDLINE_LINUX="\1 nvidia-drm.modeset=1"/' \
            /etc/default/grub
        run_cmd sudo grub2-mkconfig -o /boot/grub2/grub.cfg
    fi
    log_success "Nvidia drivers installed — reboot required"
}

_nvidia_ubuntu_debian() {
    if cmd_exists ubuntu-drivers; then
        log_info "Running ubuntu-drivers autoinstall (auto-selects recommended driver)..."
        run_cmd sudo ubuntu-drivers autoinstall
    else
        log_warn "ubuntu-drivers not found — installing nvidia-driver metapackage directly"
        run_cmd sudo apt-get install -y nvidia-driver
    fi
    log_success "Nvidia drivers installed — reboot required"
}

# ==============================================================================
# AMD
# ==============================================================================
# The amdgpu kernel driver is built into Linux — no driver install needed.
# We install the Mesa userspace stack: OpenGL, Vulkan (RADV), and hardware
# video acceleration (VA-API and VDPAU).
#
# lib32-* packages provide 32-bit support needed for Steam and Wine.
# libva-mesa-driver / mesa-vdpau provide hardware video decode — used by
# browsers (YouTube), video players, and screen recorders.

_install_amd() {
    log_info "AMD GPU — installing Mesa userspace stack"
    log_info "(amdgpu kernel driver is already built into Linux)"

    case "$DISTRO_FAMILY" in
        arch)
            local pkgs=(
                mesa                     # OpenGL
                lib32-mesa               # 32-bit OpenGL for Steam/Wine
                vulkan-radeon            # AMD Vulkan driver (RADV)
                lib32-vulkan-radeon      # 32-bit Vulkan
                libva-mesa-driver        # VA-API hardware video decode
                lib32-libva-mesa-driver  # 32-bit VA-API
                mesa-vdpau               # VDPAU hardware video decode
                lib32-mesa-vdpau         # 32-bit VDPAU
            )
            run_cmd sudo pacman -S --needed --noconfirm "${pkgs[@]}"
            ;;
        fedora)
            # Fedora ships Mesa by default — install/update Vulkan and VA-API
            run_cmd sudo dnf install -y \
                mesa-dri-drivers mesa-vulkan-drivers libva-mesa-driver
            ;;
        ubuntu|debian)
            run_cmd sudo apt-get install -y \
                mesa-vulkan-drivers libva-mesa-driver mesa-vdpau-drivers
            ;;
        *) log_error "No AMD install method for: $DISTRO_FAMILY"; return 1 ;;
    esac

    log_success "AMD Mesa stack installed"
}

# ==============================================================================
# INTEL
# ==============================================================================
# The i915 driver (older GPUs) and xe driver (Intel Arc) are built into Linux.
# We install Mesa for OpenGL/Vulkan and intel-media-driver for hardware video
# decode via VA-API. intel-media-driver requires Gen 8+ (Broadwell, 2014+).
# Older hardware uses i965-va-driver instead.

_install_intel() {
    log_info "Intel GPU — installing Mesa + VA-API userspace stack"
    log_info "(i915/xe kernel driver is already built into Linux)"

    case "$DISTRO_FAMILY" in
        arch)
            local pkgs=(
                mesa                    # OpenGL
                lib32-mesa              # 32-bit OpenGL for Steam/Wine
                vulkan-intel            # Intel Vulkan driver (ANV) — requires Broadwell+
                lib32-vulkan-intel      # 32-bit Vulkan
                intel-media-driver      # VA-API hardware video decode (Gen 8+ / Broadwell+)
                lib32-libva-intel-driver # 32-bit VA-API fallback for older hardware
            )
            run_cmd sudo pacman -S --needed --noconfirm "${pkgs[@]}"
            ;;
        fedora)
            run_cmd sudo dnf install -y \
                mesa-dri-drivers mesa-vulkan-drivers intel-media-driver
            ;;
        ubuntu|debian)
            # intel-media-va-driver = Gen 8+ (Broadwell+)
            # i965-va-driver         = Gen 4-7 (older, pre-2014)
            run_cmd sudo apt-get install -y \
                mesa-vulkan-drivers intel-media-va-driver i965-va-driver
            ;;
        *) log_error "No Intel GPU install method for: $DISTRO_FAMILY"; return 1 ;;
    esac

    log_success "Intel Mesa + VA-API stack installed"
}

# ==============================================================================
# MAIN
# ==============================================================================

main() {
    log_section "Module 12: Hardware"

    echo ""
    log_info "GPU vendor : $GPU_VENDOR"
    log_info "Bootloader : $BOOTLOADER"
    echo ""

    # macOS manages GPU drivers through Software Update.
    if [[ "$DISTRO_FAMILY" == "macos" ]]; then
        log_info "macOS: hardware firmware managed by Apple Software Update — skipping"
        log_info "Keep your Mac up to date via: System Settings → General → Software Update"
        return 0
    fi

    # GPU drivers are optional — prompted because the correct choice varies
    # by hardware, and getting it wrong (e.g. nvidia-open on a pre-Turing card)
    # can leave you without a working display after reboot.
    echo ""
    if [[ "$GPU_VENDOR" == "unknown" ]]; then
        log_warn "No GPU detected — skipping GPU driver install"
        log_warn "Run 'lspci | grep -iE \"display|vga|3d\"' to check your GPU"
    else
        log_info "Detected GPU vendor: $GPU_VENDOR"
        echo ""

        if ask "Install GPU drivers for $GPU_VENDOR GPU?" y; then
            install_gpu_drivers
        else
            log_info "GPU driver install skipped"
            log_info "Re-run at any time: bash ~/unix_setup/modules/12-hardware.sh"
        fi
    fi

    echo ""
    log_success "Module 12 complete"
    log_warn "Reboot to activate changes: sudo reboot"
}

main "$@"
