#!/usr/bin/env bash
# ==============================================================================
# modules/13-hibernate.sh — Hibernation setup
# ==============================================================================
# OPTIONAL MODULE — run after the main setup on bare metal machines that need
# hibernation (suspend-to-disk). Not needed on VMs or machines without swap.
#
# Usage:
#   bash ~/unix_setup/modules/13-hibernate.sh
#   bash ~/unix_setup/setup.sh --only 13
#
# Prerequisites:
#   - A dedicated swap partition or LVM logical volume
#   - The swap partition should be at least as large as your RAM
#
# What this module does:
#   1. Detects the swap partition and whether it is LUKS encrypted
#   2. If encrypted: generates a keyfile, adds it to the LUKS keyslots,
#      configures /etc/crypttab so swap is unlocked automatically at boot
#   3. Adds the `resume` hook to /etc/mkinitcpio.conf in the correct position
#   4. Adds resume= to the kernel cmdline
#   5. Rebuilds the initramfs
#   6. Updates the bootloader config
#
# After running, test with: sudo systemctl hibernate
# The machine should power off and restore on next boot.
# ==============================================================================

[[ -n "${_MODULE_HIBERNATE_LOADED:-}" ]] && return
_MODULE_HIBERNATE_LOADED=1

if [[ -z "${SETUP_DIR:-}" ]]; then
    SETUP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    source "$SETUP_DIR/lib/log.sh"
    source "$SETUP_DIR/lib/detect.sh"
    source "$SETUP_DIR/lib/utils.sh"
    detect_all
fi

# Only supported on Linux — hibernation on macOS is managed by the OS
if [[ "$DISTRO_FAMILY" == "macos" ]]; then
    log_info "macOS: hibernation managed by the OS — nothing to configure"
    exit 0
fi

# Paths for the encrypted swap keyfile
KEYFILE_DIR="/etc/cryptsetup-keys.d"
KEYFILE="${KEYFILE_DIR}/swap.key"

# ==============================================================================
# DETECTION
# ==============================================================================

# ------------------------------------------------------------------------------
# find_swap_partition
# Looks for a swap partition using lsblk. Sets SWAP_DEVICE to the full
# device path (e.g. /dev/nvme0n1p2) and SWAP_UUID to its UUID.
# Returns 1 if no swap partition is found.
# ------------------------------------------------------------------------------
find_swap_partition() {
    log_section "Detecting swap partition"

    # Match by filesystem type so both partitions and LVM logical volumes work.
    local swap_line
    swap_line=$(lsblk -rno PATH,FSTYPE,UUID | awk '$2=="swap"{print}' | head -1)

    if [[ -z "$swap_line" ]]; then
        log_error "No swap partition found."
        log_error "Hibernation requires a dedicated swap partition sized >= your RAM."
        log_error "See guides/encrypted-installation.md for the correct partition layout."
        return 1
    fi

    local path uuid
    path=$(echo "$swap_line" | awk '{print $1}')
    uuid=$(echo "$swap_line" | awk '{print $3}')

    SWAP_DEVICE="$path"
    SWAP_UUID="$uuid"

    log_success "Found swap partition: $SWAP_DEVICE (UUID: $SWAP_UUID)"
    export SWAP_DEVICE SWAP_UUID
}

# ------------------------------------------------------------------------------
# check_swap_size
# Compares the swap partition size to available RAM and warns if swap is
# smaller than RAM. Hibernation will fail if the swap cannot hold all of RAM.
# ------------------------------------------------------------------------------
check_swap_size() {
    local ram_kb swap_kb
    ram_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    swap_kb=$(lsblk -rnbo SIZE "$SWAP_DEVICE" 2>/dev/null | head -1)
    # Convert bytes to KB
    swap_kb=$(( swap_kb / 1024 ))

    local ram_gb=$(( ram_kb / 1024 / 1024 ))
    local swap_gb=$(( swap_kb / 1024 / 1024 ))

    log_info "RAM:  ${ram_gb} GiB"
    log_info "Swap: ${swap_gb} GiB"

    if (( swap_kb < ram_kb )); then
        log_warn "Swap (${swap_gb} GiB) is smaller than RAM (${ram_gb} GiB)."
        log_warn "Hibernation may fail if RAM usage exceeds swap size at sleep time."
        log_warn "This is only a problem if you have a lot open when hibernating."
        echo ""
        if ! ask "Continue anyway?" n; then
            log_info "Aborted. Resize the swap partition to at least ${ram_gb} GiB and re-run."
            exit 0
        fi
    else
        log_success "Swap is large enough for hibernation"
    fi
}

# ------------------------------------------------------------------------------
# detect_swap_encryption
# Checks whether the swap partition is LUKS encrypted.
# Sets SWAP_ENCRYPTED=true/false.
# ------------------------------------------------------------------------------
detect_swap_encryption() {
    if cryptsetup isLuks "$SWAP_DEVICE" 2>/dev/null; then
        SWAP_ENCRYPTED=true
        log_info "Swap partition is LUKS encrypted"
    else
        SWAP_ENCRYPTED=false
        log_info "Swap partition is not encrypted"
    fi
    export SWAP_ENCRYPTED
}

# ==============================================================================
# ENCRYPTED SWAP SETUP
# ==============================================================================

# ------------------------------------------------------------------------------
# setup_encrypted_swap
# Configures LUKS-encrypted swap for hibernation using a keyfile.
#
# Why a keyfile rather than a passphrase:
#   The kernel needs to decrypt swap during early boot, before any interactive
#   prompt is possible. A keyfile stored in the initramfs allows the swap
#   partition to be unlocked automatically, immediately after the root
#   partition is decrypted with your passphrase.
#
# Security note:
#   If /boot is unencrypted, embedding this keyfile in the initramfs allows
#   someone with physical access to recover the swap key. Secure Boot protects
#   integrity, not confidentiality. Full protection requires an encrypted boot
#   chain or a TPM-backed design that does not expose a reusable plaintext key.
# ------------------------------------------------------------------------------
setup_encrypted_swap() {
    log_section "Configuring encrypted swap for hibernation"

    log_warn "Encrypted swap hibernation embeds a reusable key in the initramfs."
    log_warn "If /boot is unencrypted, physical access may expose swap contents."
    if [[ "$DRY_RUN" != true ]] && ! ask "Continue with the initramfs keyfile approach?" n; then
        log_info "Encrypted swap hibernation setup skipped"
        return 1
    fi

    # Find what the LUKS mapper name for swap will be.
    # We'll call it "swap" — this becomes /dev/mapper/swap after unlock.
    local mapper_name="swap"
    SWAP_MAPPER="/dev/mapper/${mapper_name}"
    export SWAP_MAPPER

    # Step 1 — generate a random keyfile
    if [[ -f "$KEYFILE" ]]; then
        log_info "Keyfile already exists: $KEYFILE"
    else
        log_info "Generating random keyfile: $KEYFILE"
        if [[ "$DRY_RUN" != true ]]; then
            sudo mkdir -p "$KEYFILE_DIR"
            # dd reads 4096 bytes of randomness from /dev/urandom
            # This is more than enough entropy for a keyfile
            sudo dd bs=512 count=8 if=/dev/urandom of="$KEYFILE" 2>/dev/null
            # Restrict permissions — only root should read this
            sudo chmod 400 "$KEYFILE"
            sudo chown root:root "$KEYFILE"
            log_success "Keyfile generated"
        else
            log_info "[DRY-RUN] Would generate keyfile at $KEYFILE"
        fi
    fi

    # Step 2 — add the keyfile as a LUKS key slot on the swap partition
    # This allows the swap to be unlocked with either the passphrase OR the keyfile
    if [[ "$DRY_RUN" != true ]]; then
        log_info "Adding keyfile to swap LUKS keyslots..."
        log_info "(You will be prompted for the swap partition's LUKS passphrase)"
        echo ""
        sudo cryptsetup luksAddKey "$SWAP_DEVICE" "$KEYFILE" || {
            log_error "Failed to add keyfile to LUKS. Check your passphrase and try again."
            return 1
        }
        log_success "Keyfile added to swap LUKS keyslots"
    else
        log_info "[DRY-RUN] Would add keyfile to LUKS keyslots on $SWAP_DEVICE"
    fi

    # Step 3 — add swap to /etc/crypttab so it's unlocked at boot
    # Format: <name> <device> <keyfile> <options>
    # noauto prevents cryptsetup from trying to open it during normal boot
    # (systemd handles it via the resume mechanism instead)
    local crypttab_entry="${mapper_name}  UUID=${SWAP_UUID}  ${KEYFILE}  luks"

    if grep -q "^${mapper_name}" /etc/crypttab 2>/dev/null; then
        log_info "crypttab entry for swap already exists"
    else
        log_info "Adding swap to /etc/crypttab..."
        if [[ "$DRY_RUN" != true ]]; then
            echo "$crypttab_entry" | sudo tee -a /etc/crypttab > /dev/null
            log_success "Added to /etc/crypttab: $crypttab_entry"
        else
            log_info "[DRY-RUN] Would add to /etc/crypttab: $crypttab_entry"
        fi
    fi

    # Step 4 — add the keyfile to the initramfs
    # The keyfile must be inside the initramfs so it's available during early boot
    # when the swap partition needs to be unlocked for resume.
    local mkinitcpio_conf="/etc/mkinitcpio.conf"
    if [[ -f "$mkinitcpio_conf" ]]; then
        if grep -q "$KEYFILE" "$mkinitcpio_conf"; then
            log_info "Keyfile already in mkinitcpio FILES"
        else
            log_info "Adding keyfile to mkinitcpio FILES array..."
            if [[ "$DRY_RUN" != true ]]; then
                # Add to FILES=() — these get included verbatim in the initramfs
                sudo sed -i "s|^FILES=(|FILES=(${KEYFILE} |" "$mkinitcpio_conf"
                log_success "Keyfile added to initramfs FILES"
            else
                log_info "[DRY-RUN] Would add $KEYFILE to FILES in $mkinitcpio_conf"
            fi
        fi
    fi
}

# ==============================================================================
# KERNEL CONFIGURATION
# ==============================================================================

# ------------------------------------------------------------------------------
# configure_mkinitcpio_hooks
# Adds the `resume` hook to /etc/mkinitcpio.conf in the correct position.
#
# Hook order matters — resume must come AFTER encrypt (so the swap is
# decrypted before resume tries to read it) and AFTER filesystems.
# The correct order is: ... encrypt filesystems resume fsck
#
# Without this hook, the kernel ignores the resume= parameter and boots
# fresh every time regardless of whether a hibernation image exists.
# ------------------------------------------------------------------------------
configure_mkinitcpio_hooks() {
    log_section "mkinitcpio hooks"

    local conf="/etc/mkinitcpio.conf"

    if ! [[ -f "$conf" ]]; then
        log_error "$conf not found — is this an Arch-based system?"
        return 1
    fi

    if grep -q '^HOOKS=.*\bsystemd\b' "$conf"; then
        log_info "systemd mkinitcpio hook detected — resume support is already included"
        return
    fi

    if grep -q "\bresume\b" "$conf"; then
        log_info "resume hook already present in $conf"
        return
    fi

    log_info "Adding resume hook to $conf..."
    if [[ "$DRY_RUN" != true ]]; then
        # Insert 'resume' after 'filesystems' in the HOOKS line
        # sed looks for 'filesystems' and appends ' resume' after it
        sudo sed -i 's/\(HOOKS=.*filesystems\)/\1 resume/' "$conf"

        # Verify it was added correctly
        if grep -q "\bresume\b" "$conf"; then
            log_success "resume hook added"
            log_info "Current HOOKS line:"
            grep "^HOOKS=" "$conf"
        else
            log_error "Failed to add resume hook — edit $conf manually"
            log_error "Add 'resume' after 'filesystems' in the HOOKS line"
            return 1
        fi
    else
        log_info "[DRY-RUN] Would add 'resume' hook after 'filesystems' in $conf"
    fi
}

# ------------------------------------------------------------------------------
# configure_kernel_resume_param
# Adds resume= to the kernel cmdline so the kernel knows which device
# contains the hibernation image.
#
# For unencrypted swap: resume=UUID=<swap-uuid>
# For encrypted swap:   resume=/dev/mapper/swap
#   (the mapper device is what the kernel sees after LUKS decryption)
#
# Also sets HibernateDelaySec in systemd-sleep.conf — this controls how
# long the machine stays suspended before automatically hibernating.
# Default is set to 20 minutes.
# ------------------------------------------------------------------------------
configure_kernel_resume_param() {
    log_section "Kernel resume parameter"

    # Determine which device path to use for resume
    local resume_device
    if [[ "$SWAP_ENCRYPTED" == true ]]; then
        # After LUKS decryption, swap is available at /dev/mapper/swap
        resume_device="$SWAP_MAPPER"
    else
        # Unencrypted — reference by UUID so it works regardless of device name
        resume_device="UUID=${SWAP_UUID}"
    fi

    log_info "Resume device: $resume_device"

    case "$BOOTLOADER" in
        systemd-boot) _set_resume_systemd_boot "$resume_device" ;;
        grub)         _set_resume_grub         "$resume_device" ;;
        limine)       _set_resume_limine       "$resume_device" ;;
        *)
            log_error "Unknown bootloader '$BOOTLOADER' — set resume= manually"
            log_error "Add 'resume=${resume_device}' to your bootloader kernel cmdline"
            ;;
    esac

    # Configure systemd to auto-hibernate after 20 min of suspend and make
    # laptop lid closure request suspend-then-hibernate.
    log_info "Configuring suspend-then-hibernate (hibernates after 20 min of suspend)..."
    if [[ "$DRY_RUN" != true ]]; then
        sudo mkdir -p /etc/systemd/sleep.conf.d
        sudo mkdir -p /etc/systemd/logind.conf.d
        sudo tee /etc/systemd/sleep.conf.d/hibernate.conf > /dev/null << 'EOF'
[Sleep]
# Automatically hibernate after this long in suspend state.
# Protects against battery drain if the lid is closed for a long time.
HibernateDelaySec=20min
AllowSuspendThenHibernate=yes
EOF
        sudo tee /etc/systemd/logind.conf.d/lid-hibernate.conf > /dev/null << 'EOF'
[Login]
HandleLidSwitch=suspend-then-hibernate
HandleLidSwitchDocked=ignore
HandleLidSwitchExternalPower=suspend-then-hibernate
EOF
        log_success "Suspend-then-hibernate configured (hibernates after 20 min)"
    else
        log_info "[DRY-RUN] Would configure HibernateDelaySec=20min"
    fi
}

_set_resume_systemd_boot() {
    local resume_device="$1"

    # systemd-boot stores kernel parameters in /boot/loader/entries/*.conf
    # We update all non-snapshot entries (snapshots have their own entries)
    local entries_dir="/boot/loader/entries"

    if [[ ! -d "$entries_dir" ]]; then
        log_error "$entries_dir not found — is systemd-boot installed?"
        return 1
    fi

    log_info "Adding resume= to systemd-boot entries..."
    if [[ "$DRY_RUN" != true ]]; then
        local updated=0
        for entry in "$entries_dir"/*.conf; do
            # Skip snapshot entries (generated by systemd-boot-btrfs)
            [[ "$entry" == *"snapshot"* ]] && continue

            if grep -q "resume=" "$entry"; then
                log_info "resume= already set in $(basename "$entry")"
            else
                # Append to the options line
                sudo sed -i "s|^options \(.*\)|options \1 resume=${resume_device}|" "$entry"
                log_info "Updated: $(basename "$entry")"
                (( ++updated ))
            fi
        done
        [[ $updated -gt 0 ]] && log_success "resume= added to $updated boot entries"
    else
        log_info "[DRY-RUN] Would add resume=${resume_device} to entries in $entries_dir"
    fi

    # Also write to /etc/kernel/cmdline so mkinitcpio preset entries pick it up
    if [[ -f /etc/kernel/cmdline ]]; then
        if ! grep -q "resume=" /etc/kernel/cmdline; then
            if [[ "$DRY_RUN" != true ]]; then
                sudo sed -i "s|$| resume=${resume_device}|" /etc/kernel/cmdline
                log_success "Added resume= to /etc/kernel/cmdline"
            fi
        fi
    fi
}

_set_resume_grub() {
    local resume_device="$1"

    if [[ ! -f /etc/default/grub ]]; then
        log_error "/etc/default/grub not found"
        return 1
    fi

    if grep -q "resume=" /etc/default/grub; then
        log_info "resume= already set in /etc/default/grub"
    else
        log_info "Adding resume= to /etc/default/grub..."
        if [[ "$DRY_RUN" != true ]]; then
            sudo sed -i \
                "s|GRUB_CMDLINE_LINUX=\"\(.*\)\"|GRUB_CMDLINE_LINUX=\"\1 resume=${resume_device}\"|" \
                /etc/default/grub

            # Regenerate GRUB config
            case "$DISTRO_FAMILY" in
                arch)          sudo grub-mkconfig -o /boot/grub/grub.cfg   ;;
                fedora)        sudo grub2-mkconfig -o /boot/grub2/grub.cfg ;;
                ubuntu|debian) sudo update-grub                             ;;
            esac
            log_success "GRUB config updated with resume="
        else
            log_info "[DRY-RUN] Would add resume=${resume_device} to /etc/default/grub"
        fi
    fi
}

_set_resume_limine() {
    local resume_device="$1"
    local limine_conf
    limine_conf="$(find /boot -name "limine.conf" 2>/dev/null | head -1)"

    if [[ -z "$limine_conf" ]]; then
        log_error "limine.conf not found — add resume=${resume_device} to your CMDLINE manually"
        return 1
    fi

    if grep -q "resume=" "$limine_conf"; then
        log_info "resume= already set in $limine_conf"
    else
        log_info "Adding resume= to $limine_conf..."
        if [[ "$DRY_RUN" != true ]]; then
            sudo sed -i "s|CMDLINE=\(.*\)|CMDLINE=\1 resume=${resume_device}|" "$limine_conf"
            log_success "Limine config updated with resume="
        else
            log_info "[DRY-RUN] Would add resume=${resume_device} to $limine_conf"
        fi
    fi
}

# ==============================================================================
# REBUILD AND VERIFY
# ==============================================================================

rebuild_initramfs() {
    log_section "Rebuilding initramfs"
    log_info "Running mkinitcpio -P (this may take a minute)..."
    run_cmd sudo mkinitcpio -P
    log_success "Initramfs rebuilt"
}

# ==============================================================================
# MAIN
# ==============================================================================

main() {
    log_section "Module 13: Hibernation"

    if [[ "$DISTRO_FAMILY" != "arch" ]]; then
        log_error "Module 13 currently supports Arch/mkinitcpio systems only"
        return 1
    fi

    if [[ "$SYSTEM_PROFILE" == "atomic" ]]; then
        log_error "Module 13 does not support immutable/OSTree systems"
        return 1
    fi

    echo ""
    log_info "Bootloader : $BOOTLOADER"
    echo ""

    # Detect swap
    find_swap_partition || exit 1
    check_swap_size
    detect_swap_encryption

    echo ""

    # Set up encrypted swap keyfile if needed
    if [[ "$SWAP_ENCRYPTED" == true ]]; then
        setup_encrypted_swap || exit 1
    fi

    # Configure kernel and initramfs
    configure_mkinitcpio_hooks
    configure_kernel_resume_param
    rebuild_initramfs

    echo ""
    log_success "Module 13 complete — hibernation configured"
    echo ""
    log_info "Test hibernation with:    sudo systemctl hibernate"
    log_info "Or suspend-then-hibernate: sudo systemctl suspend-then-hibernate"
    log_warn "A reboot is required first to load the updated initramfs"
    log_warn "Reboot now: sudo reboot"
}

main "$@"
