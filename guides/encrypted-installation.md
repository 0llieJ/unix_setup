# Encrypted Linux Installation and Hibernation

This guide describes a portable storage design for Archinstall, Fedora
Anaconda, Ubuntu's installer, and Debian Installer. Installer labels change
between releases, so verify the final partition summary before writing changes.

## Goals

- Encrypt the operating system, home directories, and hibernation image.
- Keep boot files separate from the encrypted root so they can be repaired.
- Keep Btrfs snapshots away from the kernel and bootloader.
- Hibernate automatically after 20 minutes of suspend.
- Preserve enough recovery information to repair the machine from live media.

## Recommended Layout

Use GPT on UEFI systems:

```text
Disk
├─ EFI System Partition    1 GiB FAT32, unencrypted
├─ /boot                   1-2 GiB ext4, unencrypted (GRUB layouts)
└─ LUKS2 container         remaining space
   └─ LVM volume group
      ├─ root              Btrfs or ext4
      └─ swap              RAM size plus 10-20% headroom
```

For systemd-boot, mount the EFI System Partition directly at `/boot`; a second
`/boot` partition is normally unnecessary. For GRUB, use the ESP at `/boot/efi`
and a separate ext4 `/boot`.

Putting root and swap inside the same LUKS container means one passphrase
unlocks both. The swap logical volume remains readable during early boot, so
resume does not require a second LUKS key embedded in the initramfs.

Do not use randomly encrypted swap for hibernation. Its key is intentionally
discarded at shutdown, so the next boot cannot restore the memory image.

## Swap Size

For predictable hibernation, allocate at least the installed RAM size:

```text
swap size = RAM + 10-20%
```

Examples:

| RAM | Suggested swap |
|---:|---:|
| 8 GiB | 10 GiB |
| 16 GiB | 20 GiB |
| 32 GiB | 36-40 GiB |
| 64 GiB | 72 GiB |

The hibernation image must fit entirely in one persistent swap device. zram
cannot hold an image across power-off.

## Installer Mapping

### Archinstall

Use these settings:

| Archinstall option | Selection |
|---|---|
| Boot mode | UEFI, not legacy BIOS/CSM |
| Disk layout | Manual or pre-mounted |
| Bootloader | systemd-boot |
| Profile | Minimal |
| Root filesystem | Btrfs with default subvolumes and zstd compression |
| Audio | PipeWire, or leave unset because the bootstrap installs it |
| Network | NetworkManager |
| User | Normal user with sudo access |
| Additional packages | `git base-devel` |
| Secure Boot | Leave disabled until it is configured after installation |

For storage:

1. Create a 1 GiB FAT32 ESP and mount it at `/boot`.
2. Use the remaining space as one LUKS2 container.
3. Inside it, create LVM logical volumes for root and swap.
4. Size swap to RAM plus 10-20% for hibernation.
5. Format root as Btrfs and enable the default subvolume layout.
6. Format the swap LV as Linux swap.

If the installed Archinstall version cannot express LVM-on-LUKS with the
required sizes, prepare the LUKS/LVM layout manually before starting
Archinstall. Mount it under `/mnt/archinstall` and select the pre-mounted
configuration, or assign the existing volumes through manual partitioning.

Do not select a desktop profile, GRUB, PulseAudio, randomly encrypted swap, or
a separate encrypted swap partition for this layout. Do not install CPU
microcode manually; module 03 detects and installs it after the first update.

After the first boot, clone over HTTPS because the new machine does not have a
GitHub SSH key yet:

```bash
git clone https://github.com/0llieJ/unix_setup.git ~/unix_setup
bash ~/unix_setup/setup.sh
```

The dotfiles module creates the SSH key later.

### Fedora Anaconda

1. Open **Installation Destination**.
2. Choose **Custom** or **Advanced Custom / Blivet-GUI**.
3. Create the ESP and separate `/boot`.
4. Create an encrypted LVM physical volume in the remaining space.
5. Create root and swap logical volumes inside it.
6. Manually increase swap for hibernation; automatic layouts commonly choose
   a smaller swap allocation.

On Fedora Atomic desktops, keep the installer's deployment layout and use its
native rollback system. Do not add Snapper to the immutable root.

### Ubuntu Desktop

The guided encrypted-disk option is suitable for general encryption, but its
swap allocation may not be large enough for hibernation.

For hibernation:

1. Choose manual partitioning where the installer supports the required layout.
2. Create the ESP and optional separate `/boot`.
3. Use LUKS2 with LVM for root and a RAM-sized swap LV.
4. If the installer cannot create this nested layout, prepare it from the live
   environment first or create persistent encrypted swap after installation.

Do not assume Ubuntu's default swap file is large enough. Check with:

```bash
swapon --show
free -h
```

### Debian Installer

Choose:

```text
Guided - use entire disk and set up encrypted LVM
```

Debian creates a separate `/boot`; on UEFI it also creates an ESP. Root and
swap are placed inside encrypted LVM. Before confirming, resize the swap LV to
RAM plus headroom if the automatic allocation is too small.

## Why Separate Boot Storage Helps

A separate ESP and `/boot` do not make bootloader corruption impossible.
They establish a repair boundary:

- Reformatting or reinstalling the bootloader need not touch encrypted root.
- Btrfs root snapshots do not roll back kernels or bootloader files.
- Root data remains intact when boot files are rebuilt from live media.

Bootloader tools can still damage other partitions if given the wrong device.
Always verify devices with `lsblk -f` before formatting or installing.

## Recovery Material

After installation, store these on a different encrypted disk:

```bash
# Partition table
sudo sfdisk --dump /dev/nvme0n1 > partition-table.sfdisk

# LUKS header: use the partition containing the LUKS container
sudo cryptsetup luksHeaderBackup /dev/nvme0n1p3 \
  --header-backup-file luks-header.img

# Configuration and boot metadata
sudo cp /etc/fstab /etc/crypttab .
sudo cp -a /boot/loader ./loader-backup 2>/dev/null || true
```

Protect the LUKS header backup like a decryption secret. Never store the only
copy on the disk it protects.

Keep a current live USB. Bootloader recovery normally consists of:

1. Unlocking the LUKS container.
2. Activating LVM.
3. Mounting root, `/boot`, and the ESP.
4. Chrooting into the installation.
5. Reinstalling the bootloader and rebuilding its configuration.

See [Linux Bootloader Recovery](bootloader-recovery.md) for commands covering
encrypted LVM, Btrfs, GRUB, systemd-boot, and Limine.

## Configure Hibernation

On mutable Arch systems, run:

```bash
bash ~/unix_setup/setup.sh --only 13
```

Module 13 detects a swap partition or LVM logical volume, configures resume,
updates GRUB/systemd-boot/Limine, and rebuilds the initramfs.

For other distributions, use their initramfs and bootloader tooling. Verify
that persistent swap is active and test hibernation before enabling automatic
suspend-then-hibernate.

Configure the 20-minute delay:

```ini
# /etc/systemd/sleep.conf.d/hibernate.conf
[Sleep]
HibernateDelaySec=20min
AllowSuspendThenHibernate=yes
```

Make laptop lid closure use suspend-then-hibernate:

```ini
# /etc/systemd/logind.conf.d/lid-hibernate.conf
[Login]
HandleLidSwitch=suspend-then-hibernate
HandleLidSwitchDocked=ignore
HandleLidSwitchExternalPower=suspend-then-hibernate
```

Reboot, then test:

```bash
systemctl hibernate
systemctl suspend-then-hibernate
```

Test direct hibernation first. The machine should power off and restore the
same session after the next boot.

Desktop environments can take control of lid events and override logind. On
Sway, also check that `swayidle` or another power manager is not issuing a
plain `systemctl suspend` command.

## Important Limitations

- Kernel lockdown and some Secure Boot configurations disable hibernation.
- zram alone cannot support hibernation.
- Btrfs swap files can support hibernation, but require special creation and a
  correct `resume_offset`. Module 13 intentionally supports partitions and LVM
  logical volumes only.
- Hibernation writes RAM contents to disk. Swap must be encrypted whenever it
  may contain secrets from an encrypted root filesystem.

## References

- [Arch hibernation documentation](https://wiki.archlinux.org/title/Power_management/Suspend_and_hibernate)
- [Arch LUKS header backup documentation](https://wiki.archlinux.org/title/Dm-crypt/Device_encryption)
- [Debian encrypted LVM installer documentation](https://www.debian.org/releases/stable/amd64/ch06s03.en.html)
- [Fedora Anaconda installation documentation](https://docs.fedoraproject.org/en-US/fedora/latest/install-guide/install/Installing_Using_Anaconda/)
