# Linux Bootloader Recovery

This guide repairs the boot files without reinstalling Linux or formatting the
encrypted system volume. It assumes the recommended UEFI layout from
[Encrypted Linux Installation and Hibernation](encrypted-installation.md):

```text
EFI System Partition    FAT32
/boot                   ext4, GRUB only
LUKS2 container
└─ LVM
   ├─ root
   └─ swap
```

Read the commands before running them. Device names in this guide are examples.
Never run `mkfs`, `wipefs`, `fdisk`, or `parted` during bootloader recovery.

## Prepare Live Media

Use a current live image for the installed distribution and boot it in the
same firmware mode as the installation. For the recommended UEFI setup, verify:

```bash
test -d /sys/firmware/efi/efivars && echo "Booted in UEFI mode"
```

Connect to the network if packages may need to be reinstalled. Become root:

```bash
sudo -i
```

Inspect the storage before mounting anything:

```bash
lsblk -f
blkid
```

Identify:

- The FAT32 EFI System Partition (ESP).
- The separate ext4 `/boot` partition, if GRUB is used.
- The `crypto_LUKS` partition containing the operating system.
- The root logical volume after LVM is activated.

The examples below use:

```text
/dev/nvme0n1p1       ESP
/dev/nvme0n1p2       GRUB /boot
/dev/nvme0n1p3       LUKS2 container
/dev/mapper/vg-root  root logical volume
```

## Unlock And Mount The System

Open the LUKS container and activate LVM:

```bash
cryptsetup open /dev/nvme0n1p3 cryptroot
vgchange -ay
lvs -o lv_name,vg_name,lv_path,lv_size
```

### Ext4 Root

```bash
mount /dev/mapper/vg-root /mnt
```

### Btrfs Root

First inspect the subvolumes:

```bash
mount -o subvolid=5 /dev/mapper/vg-root /mnt
btrfs subvolume list /mnt
umount /mnt
```

Mount the root subvolume reported by that command. Archinstall commonly calls
it `@`:

```bash
mount -o subvol=@ /dev/mapper/vg-root /mnt
```

Do not assume the name is `@` on Fedora or Ubuntu. Their Btrfs layouts may use
different subvolume names.

### Mount Boot Partitions

Check the installed mount layout:

```bash
cat /mnt/etc/fstab
```

For GRUB with a separate `/boot`:

```bash
mount /dev/nvme0n1p2 /mnt/boot
mkdir -p /mnt/boot/efi
mount /dev/nvme0n1p1 /mnt/boot/efi
```

For systemd-boot with the ESP mounted directly at `/boot`:

```bash
mount /dev/nvme0n1p1 /mnt/boot
```

Before continuing, confirm that the expected kernel, initramfs, or EFI files
are visible:

```bash
find /mnt/boot -maxdepth 3 -type f | sort
```

If `/mnt/etc` does not contain the installed system configuration, or `/boot`
is unexpectedly empty, stop and correct the mounts.

## Enter The Installed System

On Arch-based live media:

```bash
arch-chroot /mnt
```

On Fedora, Ubuntu, Debian, or other live media:

```bash
for path in /dev /dev/pts /proc /sys /run; do
    mount --rbind "$path" "/mnt$path"
    mount --make-rslave "/mnt$path"
done
chroot /mnt /bin/bash
```

Inside the chroot, confirm the installed system and mounts:

```bash
cat /etc/os-release
findmnt --target /
findmnt --target /boot
findmnt --target /boot/efi 2>/dev/null
```

## Rebuild The Initramfs

If the bootloader is intact but the system cannot unlock root, find LVM, or
resume correctly, rebuild the initramfs before repairing the bootloader:

```bash
# Arch and derivatives
mkinitcpio -P

# Fedora
dracut --regenerate-all --force

# Ubuntu and Debian
update-initramfs -u -k all
```

Run only the command for the installed distribution.

## Repair GRUB

These commands assume UEFI and an ESP mounted at `/boot/efi`.

### Arch And Derivatives

```bash
pacman -S --needed grub efibootmgr
grub-install --target=x86_64-efi \
    --efi-directory=/boot/efi \
    --bootloader-id=GRUB
grub-mkconfig -o /boot/grub/grub.cfg
```

### Ubuntu And Debian

```bash
apt-get update
apt-get install --reinstall grub-efi-amd64
grub-install --target=x86_64-efi \
    --efi-directory=/boot/efi \
    --bootloader-id=GRUB
update-grub
```

On a Secure Boot installation, also reinstall the distribution's signed shim
package rather than replacing it with an unsigned EFI executable.

### Fedora Workstation

Fedora's UEFI installation uses shim and packaged GRUB EFI files. Reinstall the
packages rather than running `grub2-install`:

```bash
dnf reinstall grub2-efi-x64 shim-x64 grub2-common
grub2-mkconfig -o /boot/grub2/grub.cfg
```

For legacy BIOS installations only, the GRUB installation target is the whole
disk, not a partition:

```bash
# Arch, Ubuntu, or Debian
grub-install /dev/nvme0n1

# Fedora
grub2-install /dev/nvme0n1
```

Do not run the BIOS commands on the recommended UEFI layout.

## Repair systemd-boot

systemd-boot requires the ESP to be mounted at `/boot` in this repository's
recommended layout:

```bash
bootctl --esp-path=/boot install
bootctl --esp-path=/boot status
```

A normal `arch-chroot` may prevent `bootctl` from writing UEFI variables. The
EFI files and fallback loader can still be installed. If the firmware entry is
missing, leave the chroot and either use `arch-chroot -S /mnt` or create the
entry from the UEFI-booted live environment.

Inspect the entries and loader configuration:

```bash
cat /boot/loader/loader.conf
find /boot/loader/entries /boot/EFI/Linux -maxdepth 2 -type f 2>/dev/null
```

Do not create a generic entry with only `root=LABEL=ROOT`; encrypted LVM needs
the installation's real LUKS UUID, root mapping, filesystem, and Btrfs options.
Recover the kernel command line from these locations where present:

```bash
cat /etc/kernel/cmdline 2>/dev/null
grep -R "^options " /boot/loader/entries 2>/dev/null
```

`/proc/cmdline` in this recovery environment belongs to the live image, not
the installed system.

On Arch, reinstalling the installed kernel package and running `mkinitcpio -P`
usually regenerates missing kernel or unified kernel image artifacts. Preserve
the existing encryption and hibernation parameters.

## Repair Limine

Limine UEFI installation consists of an EFI executable on the ESP plus
`limine.conf`. Current upstream Limine does not use a `limine uefi-install`
command.

On Arch, reinstall the package and locate its UEFI executable:

```bash
pacman -S limine
pacman -Ql limine | grep -E 'BOOTX64\.EFI|limine.*\.EFI'
```

Copy the packaged `BOOTX64.EFI` to the fallback path on the mounted ESP. The
source path shown by `pacman -Ql` varies by package version:

```bash
install -Dm0644 /path/from/pacman/BOOTX64.EFI \
    /boot/EFI/BOOT/BOOTX64.EFI
```

Find and inspect the active configuration:

```bash
find /boot /boot/efi -iname 'limine.conf' 2>/dev/null
```

Limine checks several possible configuration locations, and newer releases
prioritize a configuration beside the EFI executable. Remove stale duplicate
configurations or make sure they contain the same kernel command line.

For a legacy BIOS Limine installation only:

```bash
limine bios-install /dev/nvme0n1
```

Re-run `limine-snapper-sync` after the main entry boots correctly. Snapshot
integration is not a substitute for a valid normal boot entry.

## Firmware Entry Missing

List UEFI boot entries:

```bash
efibootmgr -v
```

First rerun the bootloader's UEFI installation command while the live media is
booted in UEFI mode. If firmware variables cannot be written, most firmware can
launch the fallback path:

```text
EFI/BOOT/BOOTX64.EFI
```

systemd-boot and the Limine procedure above install that fallback file. With
GRUB, `grub-install --removable` can create it, but may replace another
operating system's fallback loader. Back up the existing file first.

## Fedora Atomic Desktops

Do not apply the mutable Fedora `dnf reinstall` procedure blindly to
Silverblue, Kinoite, or another rpm-ostree system.

1. Try the previous deployment from the boot menu.
2. Use Fedora installer rescue mode and mount the deployment.
3. Check deployments with `ostree admin status`.
4. Repair the ESP or GRUB files using the Fedora Atomic documentation for the
   installed release.

The deployment and `/var` normally remain intact when only the ESP or bootloader
files are damaged.

## Finish And Verify

Check the kernel, initramfs, and bootloader configuration before leaving:

```bash
ls -lh /boot
efibootmgr -v
```

Exit and unmount cleanly:

```bash
exit
swapoff -a 2>/dev/null || true
umount -R /mnt
vgchange -an
cryptsetup close cryptroot
reboot
```

Remove the live USB when the firmware restarts.

After booting the repaired system:

```bash
findmnt --target /
findmnt --target /boot
findmnt --target /boot/efi 2>/dev/null
systemctl --failed
sudo bootctl status              # systemd-boot only
sudo grub-mkconfig -o /boot/grub/grub.cfg  # Arch GRUB only
```

Once normal boot works, regenerate snapshot menu entries separately.

## References

- [Arch chroot documentation](https://wiki.archlinux.org/title/Chroot)
- [Arch systemd-boot documentation](https://wiki.archlinux.org/title/Systemd-boot)
- [Fedora GRUB documentation](https://docs.fedoraproject.org/en-US/quick-docs/grub2-bootloader/)
- [Ubuntu GRUB recovery documentation](https://help.ubuntu.com/community/Grub2/Installing)
- [Upstream Limine documentation](https://github.com/limine-bootloader/limine)
