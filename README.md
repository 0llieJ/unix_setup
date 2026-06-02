# unix_setup

Modular system setup script for fresh Linux installs. Supports Arch (and derivatives), Fedora, Ubuntu, and Debian. Installs packages, configures the system, sets up the SwayFX desktop, mounts Proton Drive, and applies dotfiles.

---

## Quick start

```bash
git clone git@github.com:0llieJ/unix_setup.git ~/unix_setup
bash ~/unix_setup/setup.sh
```

Preview what it would do without changing anything:

```bash
DRY_RUN=true bash ~/setup/setup.sh
```

Run a single module:

```bash
bash ~/setup/setup.sh --only 05
```

Skip a module:

```bash
bash ~/setup/setup.sh --skip 07
```

---

## What it does

| Module | Name | What it does |
|--------|------|-------------|
| 01 | system | Firewall, user groups, sudo feedback, ClamAV, Podman socket |
| 02 | repos | Third-party repos — paru (Arch), RPM Fusion + COPRs (Fedora), Brave/NetBird (Ubuntu/Debian) |
| 03 | packages | System packages via pacman/dnf/apt, AUR packages, Sway ecosystem |
| 04 | userland | mise tools, Flatpak apps, Homebrew formulae |
| 05 | github | Tools from GitHub/install scripts — Claude Code, DevPod, OpenAI Codex, Nerd Fonts |
| 06 | atomic | Snapper snapshots, Timeshift, boot menu integration (GRUB / systemd-boot / Limine) |
| 07 | proton | Proton Drive via rclone, mounted as `~/ProtonDrive` on login |
| 08 | dotfiles | SSH key setup, chezmoi init + apply |
| 09 | done | Summary and follow-up actions |

Optional modules (not in the default run):

| Module | Name | What it does |
|--------|------|-------------|
| 10 | sway-config | Configures SDDM/greetd, writes minimal Sway config, applies Flameshot Wayland fix |
| 11 | remove | Cleanly removes a tool and its config files (see below) |
| 12 | nvidia | Nvidia driver install — auto-detects GPU and kernel, handles stock vs DKMS |

---

## Package lists

All package decisions live in `packages/` as plain text files — one package per line, comments with `#`. Edit these to add or remove software without touching any script logic.

| File | What it controls |
|------|-----------------|
| `common.txt` | Packages with identical names on all distros |
| `arch.txt` | Arch-specific package names + Podman runtime deps |
| `arch-aur.txt` | AUR packages (paru) — SwayFX, Ghostty, greetd greeters |
| `fedora.txt` | Fedora-specific package names + COPRs |
| `ubuntu.txt` | Ubuntu-specific package names |
| `debian.txt` | Debian-specific package names |
| `sway.txt` | Sway desktop ecosystem — compositor, bar, lock screen, SDDM |
| `flatpak.txt` | Flatpak GUI apps — Zed, Bitwarden, Signal, Obsidian, etc. |
| `mise.txt` | CLI tools and language runtimes via mise |
| `homebrew.txt` | Homebrew formulae — tools not available in mise |
| `github.txt` | Tools installed from GitHub releases or install scripts |

### Package install priority

Tools are installed in this order, with earlier sources preferred:

1. **mise** — language runtimes and CLI tools (no root, user-level)
2. **Flatpak** — GUI applications (sandboxed, distro-agnostic)
3. **Homebrew** — CLI tools not in mise
4. **AUR** — Arch only, via paru
5. **System repos** — pacman / dnf / apt (root required)
6. **GitHub / install scripts** — tools not available anywhere else

---

## Recommended partition layout

For snapshots and rollbacks to work safely, `/boot` must be on a **separate partition** from Btrfs. If `/boot` is inside Btrfs, a rollback will revert your kernel and bootloader config alongside the OS — which can leave the system unbootable.

```
/dev/nvme0n1p1   fat32   /boot/efi    512MB   EFI system partition
/dev/nvme0n1p2   ext4    /boot        1GB     Kernel and initramfs (separate, not in Btrfs)
/dev/nvme0n1p3   btrfs   /            rest
  subvol @        →  /
  subvol @home    →  /home
  subvol @snapshots → /.snapshots
```

With this layout, rolling back `/` never touches `/boot` — the bootloader always reflects the current kernel and stays bootable. Module 06 will warn you at runtime if `/boot` doesn't appear to be on a separate partition.

`archinstall` can set this layout up automatically during installation.

---

## Snapshotting and rollback

On any system with a **Btrfs root filesystem**, module 06 sets up:

- **Snapper** — timeline snapshots (5 hourly, 7 daily)
- **Timeshift** — daily backup at 21:00
- **Boot menu integration** — snapshots appear as bootable entries

Boot menu tool depends on your bootloader:

| Bootloader | Tool |
|------------|------|
| GRUB | grub-btrfs + grub-btrfsd |
| systemd-boot | systemd-boot-btrfs |
| Limine | limine-snapper-sync |

To roll back:

```bash
snapper list
sudo snapper rollback <number>
```

Or select a snapshot from the boot menu at startup.

---

## Bootloader recovery

Snapshots protect your system state. They do **not** protect against the bootloader itself getting corrupted. If GRUB, systemd-boot, or Limine breaks, you won't reach the boot menu at all — the fix is a live USB.

Keep a live USB of your distro on your desk. Every recovery below takes under 10 minutes.

---

### Step 1 — boot and mount (all bootloaders)

Boot your distro's live USB, open a terminal, then mount your partitions:

```bash
# Find your partitions
lsblk

# Mount the Btrfs root subvolume
mount -o subvol=@ /dev/nvme0n1p3 /mnt

# Mount the separate /boot and EFI partitions
mount /dev/nvme0n1p2 /mnt/boot
mount /dev/nvme0n1p1 /mnt/boot/efi

# Chroot into your system
arch-chroot /mnt        # Arch / CachyOS / EndeavourOS
# or
chroot /mnt             # Fedora / Ubuntu / Debian
```

> Replace `/dev/nvme0n1p1/2/3` with your actual partition names from `lsblk`.
> If you followed the recommended layout, p1 = EFI, p2 = /boot, p3 = Btrfs root.

---

### GRUB recovery

**Reinstall GRUB and regenerate config:**

```bash
# Arch / CachyOS / EndeavourOS
grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB
grub-mkconfig -o /boot/grub/grub.cfg

# Fedora
grub2-install --target=x86_64-efi --efi-directory=/boot/efi
grub2-mkconfig -o /boot/grub2/grub.cfg

# Ubuntu / Debian
grub-install --target=x86_64-efi --efi-directory=/boot/efi
update-grub
```

**If only the config is broken** (GRUB loads but fails to find entries):

```bash
# Arch
grub-mkconfig -o /boot/grub/grub.cfg

# Fedora
grub2-mkconfig -o /boot/grub2/grub.cfg

# Ubuntu / Debian
update-grub
```

**If GRUB loads but drops to a rescue shell**, you can boot manually from there:

```
# In the GRUB rescue shell — find your root partition
ls
ls (hd0,gpt3)/          # look for @ subvolume
set root=(hd0,gpt3)
set prefix=(hd0,gpt3)/@/boot/grub
insmod normal
normal
```

---

### systemd-boot recovery

systemd-boot is simpler than GRUB — the EFI binary is small and reinstalling it is one command:

```bash
# Reinstall the systemd-boot EFI binary
bootctl install

# Verify it's working
bootctl status
```

**If boot entries are missing** (systemd-boot loads but shows no OS):

```bash
# List what entries exist
ls /boot/loader/entries/

# Regenerate entries if using systemd-boot-btrfs
systemd-boot-btrfs

# Or manually create a minimal entry
cat > /boot/loader/entries/arch.conf << 'EOF'
title   Arch Linux
linux   /vmlinuz-linux
initrd  /initramfs-linux.img
options root=LABEL=ROOT rootflags=subvol=@ rw
EOF
```

**If the EFI entry is missing from firmware** (machine doesn't try to boot systemd-boot at all):

```bash
# Re-register the EFI entry
bootctl install

# Or add it manually with efibootmgr
efibootmgr --create --disk /dev/nvme0n1 --part 1 \
    --label "systemd-boot" \
    --loader /EFI/systemd/systemd-bootx64.efi
```

---

### Limine recovery

```bash
# Reinstall Limine to the EFI partition
limine bios-install /dev/nvme0n1        # BIOS/legacy boot
# or
limine uefi-install /boot/efi           # UEFI (most modern machines)

# Regenerate Limine config if using limine-snapper-sync
limine-snapper-sync

# Or verify the config manually
cat /boot/limine.conf
```

**If Limine config is missing or corrupt**, the minimal config to get booting again:

```
TIMEOUT=5
DEFAULT_ENTRY=1

:Arch Linux
    PROTOCOL=linux
    KERNEL_PATH=boot:///vmlinuz-linux
    MODULE_PATH=boot:///initramfs-linux.img
    CMDLINE=root=LABEL=ROOT rootflags=subvol=@ rw
```

---

### Booting directly into a snapshot (any bootloader)

If the bootloader works but you need to boot a specific Snapper snapshot without the boot menu integration:

```bash
# From live USB — list snapshots
ls /mnt/.snapshots/

# Mount a specific snapshot (e.g. number 42)
mount -o subvol=@/.snapshots/42/snapshot /dev/nvme0n1p3 /mnt

# Chroot in and fix whatever broke
arch-chroot /mnt
```

---

### After any recovery — check snapshot boot entries

Once you're back in your system, resync the boot menu entries so snapshots appear again:

```bash
# GRUB
sudo grub-mkconfig -o /boot/grub/grub.cfg        # Arch
sudo grub2-mkconfig -o /boot/grub2/grub.cfg      # Fedora
sudo update-grub                                   # Ubuntu/Debian

# systemd-boot
sudo systemd-boot-btrfs

# Limine
sudo limine-snapper-sync
```

---

## Desktop (SwayFX)

SwayFX is a drop-in fork of Sway that adds rounded corners, blur, and shadows. It uses the same config file as Sway.

Run module 10 to set up the login manager and a minimal Sway config before your dotfiles are available:

```bash
bash ~/setup/modules/10-sway-config.sh
```

This configures SDDM to auto-launch SwayFX on boot and applies the Flameshot Wayland window rule. Once your dotfiles are applied via module 08, chezmoi will replace the minimal config with your full one.

**Flameshot on Wayland** requires this rule in your Sway config:

```
for_window [app_id="flameshot"] border pixel 0, floating enable, fullscreen disable, move absolute position 0 0
```

Module 10 adds this automatically if it isn't already present.

---

## Proton Drive

Proton Drive mounts at `~/ProtonDrive` via rclone as a systemd user service. It requires a one-time manual auth step before module 07 can configure the mount:

```bash
rclone config
# → New remote → name: proton → type: protondrive → follow prompts
```

Then re-run:

```bash
bash ~/setup/setup.sh --only 07
```

---

## Removing a tool

Module 11 cleanly removes a tool — stops its services, uninstalls packages, and deletes config files:

```bash
# List available removal profiles
bash ~/setup/modules/11-remove.sh --list

# Remove a tool
bash ~/setup/modules/11-remove.sh sddm

# Preview without touching anything
DRY_RUN=true bash ~/setup/modules/11-remove.sh sddm
```

Available profiles: `sddm`, `gdm`, `lightdm`, `greetd`, `greetd-tuigreet`, `greetd-regreet`, `nwg-hello`, `snapper`, `timeshift`, `grub-btrfs`, `systemd-boot-btrfs`, `limine-snapper-sync`, `proton-drive`, `ufw`, `firewalld`, `clamav`, `sway`, `swayfx`, `waybar`, `podman`, `distrobox`, `toolbox`.

### Adding a removal profile

Add a function to `modules/11-remove.sh`:

```bash
_profile_mytool() {
    do_remove \
        "package-name"           \   # packages to uninstall
        "mytool.service"         \   # system services to stop/disable
        ""                       \   # user services (empty if none)
        "/etc/mytool ~/.config/mytool"  # config paths to delete
}
```

The function is auto-discovered — no further registration needed.

---

## Adding a GitHub tool

Add the tool name to `packages/github.txt`, then add a matching function to `modules/05-github.sh`:

```bash
_install_mytool() {
    cmd_exists mytool && { log_info "already installed"; return; }
    local version
    version=$(curl -fsSL https://api.github.com/repos/owner/mytool/releases/latest \
        | grep '"tag_name"' | sed 's/.*"v\(.*\)".*/\1/')
    run_cmd curl -fsSL -o /tmp/mytool \
        "https://github.com/owner/mytool/releases/download/v${version}/mytool-linux-amd64"
    run_cmd sudo install -m 0755 /tmp/mytool /usr/local/bin/mytool
    run_cmd rm -f /tmp/mytool
}
```

---

## Distro support

| Distro | Support |
|--------|---------|
| Arch Linux | Full |
| CachyOS / EndeavourOS | Full — treated as Arch |
| Fedora | Full — AUR packages not available |
| Ubuntu | Full — AUR packages not available |
| Debian | Full — AUR packages not available |
