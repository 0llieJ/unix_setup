# unix_setup

Modular system setup script for fresh Linux installs. Supports Arch (and derivatives), Fedora, Ubuntu, and Debian. Installs packages, configures the system, sets up the SwayFX desktop, mounts Proton Drive, and applies dotfiles.

---

## Quick start

```bash
git clone https://github.com/0llieJ/unix_setup.git ~/unix_setup
bash ~/unix_setup/setup.sh
```

Preview what it would do without changing anything:

```bash
DRY_RUN=true bash ~/unix_setup/setup.sh
```

Run a single module:

```bash
bash ~/unix_setup/setup.sh --only 05
```

Skip a module:

```bash
bash ~/unix_setup/setup.sh --skip 07
```

Run the bootstrap as your normal user, not with `sudo`. The script requests
privileges for individual system operations. Firewall setup prompts for
`firewalld`, `ufw`, `nftables`, or no firewall. Set `FIREWALL=firewalld`,
`FIREWALL=ufw`, `FIREWALL=nftables`, or `FIREWALL=none` to select
non-interactively.

---

## What it does

| Module | Name | What it does |
|--------|------|-------------|
| 01 | system | Base package-manager configuration and full system upgrade |
| 02 | repos | Third-party repos — paru (Arch), RPM Fusion + COPRs (Fedora), Brave/NetBird (Ubuntu/Debian) |
| 03 | packages | CPU microcode, applications, firewall, groups, ClamAV and Podman |
| 10 | sway-config | Configures the login manager and Sway before userland and dotfiles |
| 04 | userland | mise tools, Flatpak apps, Homebrew formulae |
| 05 | github | Tools from GitHub/install scripts — Claude Code, DevPod, OpenAI Codex, Nerd Fonts |
| 06 | atomic | Snapper snapshots, Timeshift, boot menu integration (GRUB / systemd-boot / Limine) |
| 07 | proton | Proton Drive via rclone, mounted as `~/ProtonDrive` on login |
| 08 | dotfiles | SSH key setup, chezmoi init/update + apply |
| 09 | updates/done | Weekly automatic updates, summary and follow-up actions |

Additional modules:

| Module | Name | What it does |
|--------|------|-------------|
| 11 | remove | Cleanly removes a tool and its config files (see below) |
| 12 | hardware | Optional GPU drivers and userspace acceleration packages |
| 13 | hibernate | Hibernation setup — encrypted swap keyfile, resume= kernel param, initramfs hooks |

---

## Install guide

For a fresh Arch installation, follow
[`guides/archinstall.md`](guides/archinstall.md). It covers Archinstall,
encrypted LVM, the first bootstrap run, verification, hibernation, and recovery
backups.

See [`guides/encrypted-installation.md`](guides/encrypted-installation.md) for
the equivalent storage design across other common installers.

The older [`guides/archinstall-bare-metal.md`](guides/archinstall-bare-metal.md)
documents the legacy separate-swap layout and is not recommended for new
installations.

---

## Package lists

All package decisions live in `packages/` as plain text files — one package per line, comments with `#`. Edit these to add or remove software without touching any script logic.

| File | What it controls |
|------|-----------------|
| `common.txt` | Packages with identical names on all distros |
| `arch.txt` | Arch-specific package names + Podman runtime deps |
| `arch-aur.txt` | AUR packages installed through paru |
| `fedora.txt` | Fedora-specific package names + COPRs |
| `ubuntu.txt` | Ubuntu-specific package names |
| `debian.txt` | Debian-specific package names |
| `sway.txt` | Sway desktop ecosystem — compositor, bar, lock screen, SDDM |
| `flatpak.txt` | Flatpak GUI apps — Zed, Bitwarden, Signal, Obsidian, etc. |
| `mise.txt` | Default CLI tools and language runtimes via mise |
| `mise-atomic.txt` | Complete user-level tool set for OSTree/rpm-ostree desktops |
| `homebrew.txt` | Homebrew formulae — tools not available in mise |
| `github.txt` | Tools installed from GitHub releases or install scripts |

### mise manifests

Module 04 selects one complete mise manifest in this order:

1. `MISE_PACKAGES_FILE=/path/to/file`
2. `packages/mise-atomic.txt` on OSTree/rpm-ostree systems
3. `packages/mise-<distro>.txt`, such as `mise-arch.txt`
4. `packages/mise.txt`

This allows mutable Arch systems to use a reduced `mise-arch.txt` while atomic
desktops keep the complete tool set in mise.

On atomic desktops the bootstrap also skips native repository changes, package
layering, AUR installation, and Snapper setup. Flatpak, mise, user-level GitHub
tools, and chezmoi continue normally.

---

## Automatic services and updates

The default run enables NetworkManager, the selected login manager, Bluetooth,
PipeWire/WirePlumber, libvirt, smart-card support, Podman, SSD trimming, power
profiles, the selected firewall, Snapper timers, and bootloader snapshot
integration. Sway session support also includes portals, a polkit agent,
GNOME Keyring, removable-media handling, XWayland, the `wl-copy`/`wl-paste`
utilities, and the Flameshot background process.

Module 09 creates persistent weekly timers:

- System: pacman, dnf, apt, or rpm-ostree on Sunday morning.
- User: Flatpak, mise, and Linux Homebrew on Sunday afternoon.
- AUR: available updates are logged but installation remains manual with
  `paru -Sua`, because unattended PKGBUILD execution bypasses review.

Updates never reboot the machine automatically. Check them with:

```bash
systemctl list-timers unix-setup-system-update.timer
systemctl --user list-timers unix-setup-user-update.timer
```

Proton Drive is enabled on login only after the `proton:` rclone remote has
been configured. Hibernation is intentionally enabled separately with
`bash ~/unix_setup/setup.sh --only 13` after persistent swap has been verified.

---

## Recommended partition layout

Use an unencrypted boot area and one LUKS2 container holding LVM root and swap
volumes. This encrypts the hibernation image and keeps bootloader repair
separate from the operating-system data.

```
/dev/nvme0n1p1   fat32   ESP          1GB
/dev/nvme0n1p2   ext4    /boot        1-2GB    # GRUB; omit for systemd-boot
/dev/nvme0n1p3   LUKS2                rest
  └─ LVM volume group
     ├─ root       btrfs              remaining space
     └─ swap       swap               RAM + 10-20%
```

For systemd-boot, mount the ESP at `/boot`. For GRUB, mount it at `/boot/efi`
and use the separate ext4 `/boot`. Root snapshots then do not modify the kernel
or bootloader files.

See [`guides/archinstall.md`](guides/archinstall.md) for the complete Arch
installation procedure, or
[`guides/encrypted-installation.md`](guides/encrypted-installation.md) for
other distributions.

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

Snapshots do not protect the bootloader itself. Keep current live media and
the storage backups described in the installation guide.

See [`guides/bootloader-recovery.md`](guides/bootloader-recovery.md) for the
complete encrypted-root recovery procedure covering GRUB, systemd-boot,
Limine, Btrfs, LVM, Secure Boot, and Fedora Atomic systems.

---

## Desktop (SwayFX)

SwayFX is a drop-in fork of Sway that adds rounded corners, blur, and shadows. It uses the same config file as Sway.

Run module 10 to set up the login manager and a minimal Sway config before your dotfiles are available:

```bash
bash ~/unix_setup/modules/10-sway-config.sh
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
bash ~/unix_setup/setup.sh --only 07
```

---

## Removing a tool

Module 11 cleanly removes a tool — stops its services, uninstalls packages, and deletes config files:

```bash
# List available removal profiles
bash ~/unix_setup/modules/11-remove.sh --list

# Remove a tool
bash ~/unix_setup/modules/11-remove.sh sddm

# Preview without touching anything
DRY_RUN=true bash ~/unix_setup/modules/11-remove.sh sddm
```

Available profiles: `sddm`, `gdm`, `lightdm`, `greetd`, `greetd-tuigreet`, `greetd-regreet`, `nwg-hello`, `snapper`, `timeshift`, `grub-btrfs`, `systemd-boot-btrfs`, `limine-snapper-sync`, `proton-drive`, `ufw`, `firewalld`, `nftables`, `clamav`, `sway`, `swayfx`, `waybar`, `podman`, `distrobox`, `toolbox`.

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
| macOS | Core — Homebrew formulae, casks, mise, dotfiles. No Sway/Flatpak/Snapper |

### What runs on macOS

| Module | Behaviour |
|--------|-----------|
| 01 system | Application Firewall enabled. Groups skipped (managed via System Settings) |
| 02 repos | Skipped — Homebrew is the only package source |
| 03 packages | Skipped — formulae installed by module 04 instead |
| 04 userland | Homebrew formulae + casks (`packages/macos-casks.txt`) + mise |
| 05 github | Full — Claude Code, DevPod, Nerd Fonts, Codex all work on macOS |
| 06 atomic | Skipped — use Time Machine for backups |
| 07 proton | rclone remote checked; auto-mount skipped (no systemd). Manual mount instructions printed |
| 08 dotfiles | Full — chezmoi works on macOS |
| 12 hardware | Skipped — Apple manages firmware via Software Update |
