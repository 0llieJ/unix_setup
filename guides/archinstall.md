# Archinstall and unix_setup Guide

This is the recommended path for installing Arch Linux before running this
repository. It targets a modern UEFI machine with:

- systemd-boot
- one LUKS2 container
- LVM root and swap logical volumes
- Btrfs root with subvolumes
- encrypted hibernation swap
- NetworkManager
- a minimal installation that `unix_setup` turns into a SwayFX desktop

Keep the Arch ISO available until the installed system has booted successfully
more than once.

## Before Starting

Back up everything on the target disk. The partitioning step destroys existing
data.

From the Arch ISO, confirm that it was booted in UEFI mode:

```bash
test -d /sys/firmware/efi/efivars \
    && echo "UEFI mode" \
    || echo "Reboot the ISO in UEFI mode"
```

Identify the target disk and installed RAM:

```bash
lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINTS,MODEL
free -h
```

This guide uses `/dev/nvme0n1` as an example. Replace it with the actual disk.
SATA disks commonly use names such as `/dev/sda`.

Connect to the network:

```bash
# Ethernet normally works automatically.
ping -c 3 archlinux.org

# For Wi-Fi, if required:
iwctl
device list
station wlan0 scan
station wlan0 get-networks
station wlan0 connect "NetworkName"
exit
```

## Storage Layout

Use this GPT layout:

```text
/dev/nvme0n1p1   1 GiB FAT32   EFI System Partition, mounted at /boot
/dev/nvme0n1p2   remaining     LUKS2 container
└─ LVM volume group
   ├─ root                      Btrfs
   └─ swap                      RAM plus 10-20%
```

Suggested swap sizes:

| RAM | Swap |
|---:|---:|
| 8 GiB | 10 GiB |
| 16 GiB | 20 GiB |
| 32 GiB | 36-40 GiB |
| 64 GiB | 72 GiB |

Root and swap inside one LUKS container are preferable to separate encrypted
partitions. One passphrase unlocks both, and no separate swap key needs to be
embedded in the unencrypted initramfs.

Do not use randomly encrypted swap. Its key is discarded and cannot restore a
hibernation image after power-off.

## Run Archinstall

Start the installer:

```bash
archinstall
```

Menu names can change between Archinstall releases. Review the final summary
instead of relying only on the labels below.

Select:

| Option | Selection |
|---|---|
| Language and locale | Your preference, UTF-8 |
| Mirrors | A nearby region |
| Disk configuration | Manual partitioning or pre-mounted configuration |
| Bootloader | systemd-boot |
| Profile | Minimal |
| Audio | PipeWire, or leave unset |
| Network | NetworkManager |
| Kernel | `linux` |
| Timezone | Your local timezone |
| NTP | Enabled |
| Additional packages | `git base-devel` |

Create a normal user and grant it sudo access. Do not plan to run the bootstrap
as root.

Set a strong LUKS passphrase and store a recovery copy securely. Losing every
valid passphrase and key means losing the encrypted data.

Leave Secure Boot disabled for the first installation. Configure and test it
separately after the machine boots reliably.

## Configure The Disk

The final result must be:

1. A GPT partition table.
2. A 1 GiB FAT32 EFI System Partition mounted at `/boot`.
3. One LUKS2 partition using the rest of the disk.
4. An LVM volume group inside LUKS.
5. A Btrfs root logical volume.
6. A persistent swap logical volume sized for hibernation.
7. Btrfs default subvolumes with zstd compression.

If the installed Archinstall version can create this layout directly, use its
manual partitioning interface.

If it cannot create LVM inside LUKS, stop rather than accepting a different
layout accidentally. Prepare and mount the layout manually, then use
Archinstall's pre-mounted configuration. The exact pre-mounted workflow can
change between Archinstall versions; confirm it against the current official
Archinstall documentation before writing the disk.

Before selecting **Install**, verify the summary shows:

```text
UEFI/GPT
ESP mounted at /boot
systemd-boot
encrypted root
Btrfs root
persistent swap
NetworkManager
normal sudo user
Minimal profile
```

## Do Not Select

Avoid these choices:

- A desktop environment or Sway profile. The bootstrap installs SwayFX.
- GRUB, unless the machine specifically requires it.
- PulseAudio. Use PipeWire.
- A separate encrypted swap partition.
- Randomly encrypted swap.
- A Btrfs swap file. Module 13 intentionally supports swap partitions and LVM
  logical volumes.
- CPU microcode packages. The bootstrap detects Intel or AMD and installs the
  correct package after the full system update.
- A firewall. The bootstrap offers firewalld, UFW, nftables, or none.
- Secure Boot during the initial installation.

## First Boot

Complete the installation and reboot without the ISO.

Log in as the normal user and verify:

```bash
findmnt -no SOURCE,FSTYPE,OPTIONS /
findmnt -no SOURCE,FSTYPE /boot
lsblk -f
swapon --show
systemctl is-active NetworkManager
sudo -v
```

Expected results:

- `/` is Btrfs on an LVM logical volume.
- `/boot` is the FAT32 ESP.
- The outer disk partition reports `crypto_LUKS`.
- Swap is an active LVM logical volume.
- NetworkManager is active.
- The normal user can use sudo.

Do not continue if root, boot, or swap is mounted from an unexpected device.
Correct the installation while it is still empty.

## Run unix_setup

Clone over HTTPS because the new system does not have a GitHub SSH key yet:

```bash
git clone https://github.com/0llieJ/unix_setup.git ~/unix_setup
cd ~/unix_setup
```

Preview the bootstrap:

```bash
bash setup.sh --dry-run
```

Run it as the normal user, without `sudo`:

```bash
bash setup.sh
```

The setup will:

1. Update Arch fully.
2. Install CPU microcode.
3. Install official and AUR packages.
4. Ask for firewalld, UFW, nftables, or no firewall.
5. Permit SSH and LocalSend TCP port `53317`.
6. Install and configure SwayFX and SDDM.
7. Install user tools through mise without npm.
8. Optionally create a GitHub SSH key and apply the chezmoi dotfiles.
9. Configure Btrfs snapshots and boot-menu integration.

The run contains interactive package, firewall, and SSH-key prompts. Do not
leave it unattended.

Weekly native, Flatpak, mise, and Linux Homebrew updates are enabled during the
run. AUR upgrades remain manual so PKGBUILDs can be reviewed. The machine is
never rebooted automatically.

## Reboot And Verify

Reboot after the bootstrap:

```bash
sudo reboot
```

After logging in, check:

```bash
systemctl --failed
systemctl get-default
systemctl status NetworkManager bluetooth --no-pager
systemctl status sddm --no-pager
ls -l /usr/share/wayland-sessions/
systemctl --user status pipewire wireplumber --no-pager
systemctl --user status podman.socket --no-pager
systemctl --user status flameshot --no-pager
systemctl list-timers unix-setup-system-update.timer
systemctl --user list-timers unix-setup-user-update.timer
snapper list
swapon --show
```

If the machine boots to a TTY instead of SDDM, log in and repair the graphical
boot configuration with:

```bash
cd ~/unix_setup
bash setup.sh --only 10
sudo systemctl set-default graphical.target
sudo systemctl enable --now sddm.service
```

Then inspect any remaining failure:

```bash
systemctl status sddm.service --no-pager -l
journalctl -u sddm.service -b --no-pager
ls -l /usr/share/wayland-sessions/
```

Sway does not start independently at boot. SDDM starts first, then launches
SwayFX after the user selects that session and logs in.

Check the selected firewall:

```bash
# firewalld
sudo firewall-cmd --list-all

# UFW
sudo ufw status verbose

# nftables
sudo nft list ruleset
```

Only run the command for the selected firewall.

## Configure Hibernation

After confirming that normal boots work:

```bash
bash ~/unix_setup/setup.sh --only 13
```

Then test direct hibernation:

```bash
sudo systemctl hibernate
```

The computer should power off and restore the same session when powered on.
Only after direct hibernation works should you test:

```bash
systemctl suspend-then-hibernate
```

Module 13 configures the system to hibernate after 20 minutes of suspension.

## Create Recovery Backups

Store these files on a different encrypted disk:

```bash
mkdir -p ~/recovery-backup

sudo sfdisk --dump /dev/nvme0n1 \
    > ~/recovery-backup/partition-table.sfdisk

sudo cryptsetup luksHeaderBackup /dev/nvme0n1p2 \
    --header-backup-file ~/recovery-backup/luks-header.img

sudo cp /etc/fstab ~/recovery-backup/
sudo cp /etc/crypttab ~/recovery-backup/ 2>/dev/null || true
sudo cp -a /boot/loader ~/recovery-backup/loader
```

Replace the example disk and LUKS partition names first. Treat the LUKS header
backup as sensitive recovery material.

Keep a current Arch ISO. See
[Linux Bootloader Recovery](bootloader-recovery.md) before attempting any
bootloader repair.

## Related Guides

- [Encrypted Linux Installation and Hibernation](encrypted-installation.md)
- [Linux Bootloader Recovery](bootloader-recovery.md)
- [Legacy separate-swap guide](archinstall-bare-metal.md)
- [Official Archinstall documentation](https://archinstall.archlinux.page/)
