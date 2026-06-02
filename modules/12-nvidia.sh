#!/usr/bin/env bash
# ==============================================================================
# modules/12-nvidia.sh — Nvidia driver installation
# ==============================================================================
# OPTIONAL MODULE — only run this on machines with an Nvidia GPU.
# NOT included in the default setup.sh run.
#
# Usage:
#   bash ~/unix_setup/modules/12-nvidia.sh
#   # or via setup.sh:
#   bash ~/unix_setup/setup.sh --only 12
#
# Run AFTER the main setup (modules 01-09) has completed, so the base system
# and kernel are fully in place before drivers are added.
#
# What this module does:
#   1. Detects whether an Nvidia GPU is present — exits cleanly if not
#   2. Identifies the running kernel to pick the right driver package:
#        - Stock Arch kernel     → nvidia-open        (pre-built module)
#        - CachyOS / lts / zen   → nvidia-open-dkms   (builds against any kernel)
#        - Fedora                → akmod-nvidia        (RPM Fusion, DKMS-based)
#        - Ubuntu / Debian       → ubuntu-drivers      (automatic driver selection)
#   3. Installs the driver, utilities, and 32-bit libs (needed for Steam/Wine)
#   4. Enables DRM kernel mode setting — required for Wayland/SwayFX
#   5. Adds Nvidia modules to the initramfs so the GPU is available early in boot
#   6. Rebuilds the initramfs to apply the changes
#
# WHY nvidia-open vs nvidia-open-dkms:
#   nvidia-open is a pre-compiled module built against the stock Arch kernel.
#   It installs instantly but only works with that exact kernel. CachyOS and
#   other distros with custom kernels (linux-lts, linux-zen, linux-hardened)
#   need nvidia-open-dkms instead — it compiles the module against whichever
#   kernel you're running, which takes a few minutes on first install.
#
# REQUIREMENTS:
#   - Turing or newer GPU (RTX 20xx+) for nvidia-open / nvidia-open-dkms
#   - For older cards (GTX 10xx and below), change nvidia-open to nvidia in
#     the ARCH_STOCK_PKGS list below
#
# Depends on: 03-packages.sh (base-devel must be installed for DKMS builds)
# ==============================================================================

[[ -n "${_MODULE_NVIDIA_LOADED:-}" ]] && return
_MODULE_NVIDIA_LOADED=1

# ------------------------------------------------------------------------------
# Package lists per distro and kernel type.
# Edit these if you need a different driver variant (e.g. proprietary instead
# of open-source, or without 32-bit libs).
# ------------------------------------------------------------------------------

# Arch — stock kernel (linux). Pre-built module, no compilation needed.
ARCH_STOCK_PKGS=(nvidia-open nvidia-utils nvidia-settings lib32-nvidia-utils)

# Arch — custom kernel (CachyOS, linux-lts, linux-zen, linux-hardened, etc.)
# DKMS builds the module from source against the running kernel.
ARCH_DKMS_PKGS=(nvidia-open-dkms nvidia-utils nvidia-settings lib32-nvidia-utils)

# Fedora — from RPM Fusion (enabled by module 02-repos.sh)
# akmod-nvidia automatically rebuilds the module on kernel updates.
FEDORA_PKGS=(akmod-nvidia xorg-x11-drv-nvidia-cuda)

# ------------------------------------------------------------------------------
# detect_gpu
# Checks whether an Nvidia GPU is present using lspci. Exits the module
# gracefully if no Nvidia hardware is found so this can be safely run on any
# machine without knowing in advance whether it has an Nvidia card.
# ------------------------------------------------------------------------------
detect_gpu() {
    log_section "GPU detection"

    if ! cmd_exists lspci; then
        log_warn "lspci not found — installing pciutils to detect GPU..."
        pkg_install pciutils
    fi

    if lspci | grep -qi "nvidia"; then
        local gpu_name
        gpu_name=$(lspci | grep -i nvidia | head -1 | sed 's/.*: //')
        log_success "Nvidia GPU detected: $gpu_name"
        return 0
    else
        log_info "No Nvidia GPU detected — skipping Nvidia driver setup"
        return 1
    fi
}

# ------------------------------------------------------------------------------
# detect_kernel_type
# Reads `uname -r` to determine whether the running kernel is the stock Arch
# kernel or a custom one. Sets KERNEL_TYPE to "stock" or "custom".
#
# Custom kernels known to need DKMS:
#   - cachyos / cachyos-lts / cachyos-hardened  (CachyOS)
#   - lts                                        (linux-lts)
#   - zen                                        (linux-zen)
#   - hardened                                   (linux-hardened)
#
# If the kernel name doesn't match any of these, it's assumed to be stock.
# You can override by setting KERNEL_TYPE=custom before running the module.
# ------------------------------------------------------------------------------
detect_kernel_type() {
    local kernel
    kernel=$(uname -r)
    log_info "Running kernel: $kernel"

    KERNEL_TYPE="stock"
    if echo "$kernel" | grep -qiE "cachyos|lts|zen|hardened|xanmod|tkg"; then
        KERNEL_TYPE="custom"
        log_info "Custom kernel detected — will use DKMS driver (nvidia-open-dkms)"
    else
        log_info "Stock kernel detected — will use pre-built driver (nvidia-open)"
    fi

    export KERNEL_TYPE
}

# ------------------------------------------------------------------------------
# check_gpu_generation
# Warns if the GPU might be too old for nvidia-open (requires Turing / RTX 20xx+).
# nvidia-open doesn't support Kepler, Maxwell, Pascal, or Volta architectures.
# If you have an older card, you'll need to change nvidia-open to nvidia in the
# package lists at the top of this file.
# ------------------------------------------------------------------------------
check_gpu_generation() {
    local gpu_name
    gpu_name=$(lspci | grep -i nvidia | head -1)

    # Very rough check — if the model number is < 2000 it's likely pre-Turing.
    # This catches GTX 10xx, 9xx, 7xx etc. but isn't exhaustive.
    if echo "$gpu_name" | grep -qiE "GTX [0-9]{3}[^0-9]|GTX [0-9]{4}[^0-9]|GT [0-9]|Quadro|Tesla|NVS"; then
        echo ""
        log_warn "Your GPU may be too old for nvidia-open (requires Turing / RTX 20xx+)."
        log_warn "Detected: $gpu_name"
        log_warn "If install fails, edit ARCH_STOCK_PKGS and ARCH_DKMS_PKGS in this"
        log_warn "module to use 'nvidia' instead of 'nvidia-open'."
        echo ""
        if ! ask "Continue with nvidia-open anyway?" n; then
            log_info "Aborted — edit the package lists and re-run."
            exit 0
        fi
    fi
}

# ------------------------------------------------------------------------------
# install_arch
# Installs the correct Nvidia driver for Arch and its derivatives based on the
# detected kernel type. Also handles the mkinitcpio and DRM configuration.
# ------------------------------------------------------------------------------
install_arch() {
    log_section "Installing Nvidia drivers (Arch)"

    detect_kernel_type
    check_gpu_generation

    if [[ "$KERNEL_TYPE" == "custom" ]]; then
        log_info "Installing DKMS drivers: ${ARCH_DKMS_PKGS[*]}"
        log_info "(DKMS will compile the kernel module — this takes a few minutes)"
        run_cmd sudo pacman -S --needed --noconfirm "${ARCH_DKMS_PKGS[@]}"
    else
        log_info "Installing pre-built drivers: ${ARCH_STOCK_PKGS[*]}"
        run_cmd sudo pacman -S --needed --noconfirm "${ARCH_STOCK_PKGS[@]}"
    fi

    _configure_drm_arch
    _configure_initramfs_arch
}

# ------------------------------------------------------------------------------
# _configure_drm_arch
# Enables Nvidia DRM (Direct Rendering Manager) kernel mode setting.
# Required for Wayland compositors including SwayFX — without it, SwayFX
# either won't start or will fall back to software rendering.
#
# Sets two kernel parameters:
#   nvidia-drm.modeset=1  — enables DRM modesetting
#   nvidia-drm.fbdev=1    — enables the Nvidia framebuffer device (needed for
#                           TTY console and some Wayland compositors)
#
# Written to /etc/kernel/cmdline which is used by systemd-boot and mkinitcpio.
# For GRUB users this file is not used — GRUB reads /etc/default/grub instead,
# so we update both.
# ------------------------------------------------------------------------------
_configure_drm_arch() {
    log_info "Enabling Nvidia DRM kernel mode setting..."

    if [[ "$DRY_RUN" != true ]]; then
        # /etc/kernel/cmdline — used by systemd-boot via mkinitcpio
        if [[ -f /etc/kernel/cmdline ]]; then
            if ! grep -q "nvidia-drm.modeset" /etc/kernel/cmdline; then
                sudo sed -i 's/$/ nvidia-drm.modeset=1 nvidia-drm.fbdev=1/' /etc/kernel/cmdline
                log_info "Updated /etc/kernel/cmdline"
            else
                log_info "DRM modeset already set in /etc/kernel/cmdline"
            fi
        fi

        # /etc/default/grub — used by GRUB
        if [[ -f /etc/default/grub ]]; then
            if ! grep -q "nvidia-drm.modeset" /etc/default/grub; then
                sudo sed -i \
                    's/GRUB_CMDLINE_LINUX_DEFAULT="\(.*\)"/GRUB_CMDLINE_LINUX_DEFAULT="\1 nvidia-drm.modeset=1 nvidia-drm.fbdev=1"/' \
                    /etc/default/grub
                log_info "Updated /etc/default/grub"
            else
                log_info "DRM modeset already set in /etc/default/grub"
            fi
        fi
    else
        log_info "[DRY-RUN] Would add nvidia-drm.modeset=1 nvidia-drm.fbdev=1 to kernel cmdline"
    fi

    log_success "DRM kernel mode setting enabled"
}

# ------------------------------------------------------------------------------
# _configure_initramfs_arch
# Adds the four Nvidia kernel modules to /etc/mkinitcpio.conf and rebuilds
# the initramfs so they're loaded early in the boot process.
#
# Loading Nvidia modules in the initramfs (rather than at userspace startup)
# ensures the GPU is available to the display manager and compositor from the
# moment they start — avoiding a blank screen on login.
#
# The four modules:
#   nvidia          — core driver
#   nvidia_modeset  — mode setting support
#   nvidia_uvm      — unified memory (needed for CUDA / compute workloads)
#   nvidia_drm      — DRM/KMS integration (needed for Wayland)
# ------------------------------------------------------------------------------
_configure_initramfs_arch() {
    log_info "Adding Nvidia modules to initramfs..."

    if [[ "$DRY_RUN" != true ]]; then
        local mkinitcpio_conf="/etc/mkinitcpio.conf"
        if [[ -f "$mkinitcpio_conf" ]]; then
            # Replace the MODULES=() line, preserving any existing modules
            if grep -q "^MODULES=" "$mkinitcpio_conf"; then
                # Add Nvidia modules if not already present
                if ! grep -q "nvidia" "$mkinitcpio_conf"; then
                    sudo sed -i \
                        's/^MODULES=(\(.*\))/MODULES=(\1 nvidia nvidia_modeset nvidia_uvm nvidia_drm)/' \
                        "$mkinitcpio_conf"
                    log_info "Nvidia modules added to $mkinitcpio_conf"
                else
                    log_info "Nvidia modules already present in $mkinitcpio_conf"
                fi
            fi
        fi

        log_info "Rebuilding initramfs (mkinitcpio -P)..."
        run_cmd sudo mkinitcpio -P
    else
        log_info "[DRY-RUN] Would add nvidia modules to /etc/mkinitcpio.conf and rebuild initramfs"
    fi

    log_success "Initramfs updated"
}

# ------------------------------------------------------------------------------
# install_fedora
# Installs Nvidia drivers on Fedora via RPM Fusion (enabled by module 02).
# akmod-nvidia automatically rebuilds the kernel module on every kernel update
# so you don't need to do anything after a kernel upgrade.
#
# akmods takes a few minutes on first install — it builds the module in the
# background. The drivers won't be active until the next reboot.
# ------------------------------------------------------------------------------
install_fedora() {
    log_section "Installing Nvidia drivers (Fedora)"

    log_info "Installing: ${FEDORA_PKGS[*]}"
    log_info "(akmods will build the kernel module in the background — takes a few minutes)"
    run_cmd sudo dnf install -y "${FEDORA_PKGS[@]}"

    # Enable DRM modesetting in GRUB
    if [[ -f /etc/default/grub ]]; then
        if [[ "$DRY_RUN" != true ]]; then
            if ! grep -q "nvidia-drm.modeset" /etc/default/grub; then
                sudo sed -i \
                    's/GRUB_CMDLINE_LINUX="\(.*\)"/GRUB_CMDLINE_LINUX="\1 nvidia-drm.modeset=1"/' \
                    /etc/default/grub
                run_cmd sudo grub2-mkconfig -o /boot/grub2/grub.cfg
            fi
        else
            log_info "[DRY-RUN] Would add nvidia-drm.modeset=1 to /etc/default/grub"
        fi
    fi

    log_success "Nvidia drivers installed — reboot to activate"
}

# ------------------------------------------------------------------------------
# install_ubuntu_debian
# Ubuntu and Debian both ship the ubuntu-drivers tool which detects your GPU
# and installs the recommended driver automatically. This is the safest approach
# on these distros as it picks the right version for your hardware.
# ------------------------------------------------------------------------------
install_ubuntu_debian() {
    log_section "Installing Nvidia drivers (Ubuntu/Debian)"

    if cmd_exists ubuntu-drivers; then
        log_info "Using ubuntu-drivers to auto-select and install recommended driver..."
        run_cmd sudo ubuntu-drivers autoinstall
    else
        # Fallback: install the latest nvidia-driver metapackage
        log_warn "ubuntu-drivers not found — installing nvidia-driver metapackage directly"
        run_cmd sudo apt-get install -y nvidia-driver
    fi

    log_success "Nvidia drivers installed — reboot to activate"
}

# ------------------------------------------------------------------------------
# main
# ------------------------------------------------------------------------------
main() {
    log_section "Module 12: Nvidia drivers (optional)"

    # Exit cleanly if no Nvidia GPU is present
    detect_gpu || return 0

    # Dispatch to the correct install function for this distro
    case "$DISTRO_FAMILY" in
        arch)          install_arch          ;;
        fedora)        install_fedora        ;;
        ubuntu|debian) install_ubuntu_debian ;;
        *)
            log_error "No Nvidia install method for distro family: $DISTRO_FAMILY"
            return 1
            ;;
    esac

    echo ""
    log_success "Module 12 complete"
    log_warn "Reboot required to activate the Nvidia drivers: sudo reboot"
}

main "$@"
