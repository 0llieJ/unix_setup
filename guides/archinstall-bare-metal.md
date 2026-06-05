# Arch Linux — Legacy Separate-Swap Install Guide

> Do not use this layout for a new installation. It keeps swap in a second
> LUKS container and module 13 must embed its key in the unencrypted initramfs.
> Follow [`encrypted-installation.md`](encrypted-installation.md) for the
> preferred single-LUKS, LVM-root-and-swap Archinstall checklist.

Step-by-step archinstall walkthrough for a full bare metal setup with:
- LUKS2 full disk encryption
- Btrfs with subvolumes (required for snapshotting)
- Separate `/boot` partition (required for safe rollbacks)
- Encrypted swap sized for hibernation
- systemd-boot bootloader
- PipeWire audio
- NetworkManager

After this guide completes, run `unix_setup` to install everything else.

> For the preferred single-LUKS encrypted-LVM layout, bootloader recovery
> design, and current hibernation guidance, see
> [`encrypted-installation.md`](encrypted-installation.md). This older guide
> documents a separate encrypted swap partition.

---

## Before you start

**Know your disk name.** Run `lsblk` after booting the live ISO to find it.
NVMe drives are `/dev/nvme0n1`. SATA/SSD drives are `/dev/sda`.
This guide uses `/dev/nvme0n1` — substitute your actual disk name throughout.

**Know your RAM size.** The swap partition must be at least this large for
hibernation to work. Run `free -h` to check.

---

## Partition layout

```
nvme0n1p1   1 GiB      FAT32    /boot        Unencrypted — bootloader and kernel live here
nvme0n1p2   = your RAM  —       [swap]        LUKS2 encrypted swap (needed for hibernation)
nvme0n1p3   rest        —       /             LUKS2 encrypted Btrfs with subvolumes
```

**Why `/boot` is unencrypted:**
systemd-boot runs before any decryption happens. It needs to read the kernel
and initramfs from `/boot` — so `/boot` must be readable by the firmware.
Encrypting `/boot` would mean nothing can boot. The rest of the disk
(swap and root) is fully encrypted.

**Why this walkthrough uses a separate swap partition:**
Module 13 supports swap partitions and LVM logical volumes directly. Btrfs
swap files can support hibernation, but need special creation and a correct
`resume_offset`, which this module intentionally does not manage.

---

## Step 1 — Boot and connect to the internet

Boot the Arch ISO. At the live shell:

**Ethernet** — connected automatically, skip to step 2.

**WiFi:**
```bash
iwctl
device list                        # find your wireless device name (e.g. wlan0)
station wlan0 scan
station wlan0 get-networks
station wlan0 connect "NetworkName"
exit
ping archlinux.org                 # verify connectivity
```

---

## Step 2 — Launch archinstall

```bash
archinstall
```

---

## Step 3 — Work through the archinstall menu

Go through each item in order. Settings not listed here can be left at
their defaults.

---

### Archinstall language
Leave as **English** unless you need otherwise.

---

### Mirrors
Select **Mirror region** → choose your country. This makes package downloads
faster by using geographically closer servers.

---

### Locales
- **Locale language** — your language (e.g. `en_GB`)
- **Locale encoding** — `UTF-8`

---

### Disk configuration → **Manual partitioning**

Select **Manual partitioning** (not best-effort — we need full control for
the three-partition layout).

Select your disk (`/dev/nvme0n1`), then create three partitions:

**Partition 1 — /boot (EFI)**
```
Type       : primary
Start      : 1 MiB
End        : 1025 MiB  (1 GiB)
FS type    : fat32
Mountpoint : /boot
Flags      : boot, esp
Encrypt    : No
```

**Partition 2 — swap**
```
Type       : primary
Start      : 1025 MiB
End        : 1025 MiB + [your RAM in MiB]
             e.g. for 16 GiB RAM: end at 17409 MiB
FS type    : linux-swap
Mountpoint : (none)
Encrypt    : Yes  ← LUKS2
```

> When prompted for an encryption passphrase, you can use the same
> passphrase as your root partition or a different one. Using the same
> passphrase is simpler — the system will only prompt once at boot.
> Using a keyfile (configured post-install) is more elegant but requires
> extra steps covered in the hibernation section below.

**Partition 3 — root (Btrfs)**
```
Type       : primary
Start      : (after swap partition ends)
End        : 100%
FS type    : btrfs
Mountpoint : /
Encrypt    : Yes  ← LUKS2 (same passphrase as swap)
Mount opts : compress=zstd  ← saves significant disk space, negligible CPU cost
```

---

### Disk encryption
archinstall will ask for an encryption passphrase. This passphrase
unlocks your root partition at boot. Choose a strong passphrase —
this is the only thing protecting your data if the machine is stolen.

> Write it down and store it somewhere safe. There is no recovery if
> you forget it.

---

### Btrfs subvolumes — **Yes**

When archinstall asks:
> "Would you like to use BTRFS subvolumes with a default structure?"

Answer **Yes**.

This creates the subvolumes Snapper expects:
```
@         →  /
@home     →  /home
@log      →  /var/log
@pkg      →  /var/cache/pacman/pkg
```

> `@snapshots` (for `/.snapshots`) is not created here — Snapper creates
> it automatically when module 06 of unix_setup runs. This is expected.

---

### Btrfs compression — **yes, zstd**

If archinstall asks about compression, select **zstd**. It's already
set as a mount option if you used `compress=zstd` above.

---

### Bootloader — **systemd-boot**

Select **systemd-boot**. It's simpler and more reliable than GRUB on
UEFI systems, has fewer moving parts that can break, and is what the
unix_setup atomic module configures snapshot boot entries for.

> Only choose GRUB if you know you need it (e.g. legacy BIOS machine,
> multiboot setup). On a modern machine with UEFI, systemd-boot is
> the better choice.

---

### Hostname
Set to whatever you want your machine to be called on the network.
e.g. `battlestation`, `thinkpad`, `desktop`

---

### Root password
Set a strong root password. This is separate from your user password
and from the disk encryption passphrase.

---

### User account
Create your user account:
- **Username** — your username
- **Password** — your user password
- **sudo** — **Yes** (add to wheel group)

---

### Profile — **Minimal**

Select **Minimal** (or nothing). Do not install a desktop environment
from here — unix_setup installs SwayFX and everything else. Installing
a DE from archinstall would conflict.

---

### Audio — **PipeWire**

Select **PipeWire**. Do not select PulseAudio.

---

### Network configuration — **NetworkManager**

Select **NetworkManager**. This is what unix_setup expects and what
most desktop tools (nm-applet, waybar network module) use.

---

### Timezone
Set your timezone (e.g. `Europe/London`).

---

### NTP — **Yes**

Leave NTP enabled. This keeps the system clock accurate.

---

### Additional packages

Add these so you can clone and run unix_setup immediately after install
without needing to install anything first:

```
git
base-devel
```

---

### Install

Review the summary and press **Install**. The install takes 5–15 minutes
depending on your internet speed and disk.

When prompted to chroot into the installed system — **No**. Reboot directly.

---

## Step 4 — First boot

On first boot, systemd-boot will ask for your disk encryption passphrase.
Enter it and the system will boot to a TTY login prompt.

Log in as your user. You should now have a minimal Arch system with
NetworkManager running.

Verify you're online:
```bash
ping archlinux.org
```

---

## Step 5 — Clone and run unix_setup

```bash
git clone https://github.com/0llieJ/unix_setup.git ~/unix_setup
bash ~/unix_setup/setup.sh
```

Run optional hardware/hibernation modules afterwards:
```bash
bash ~/unix_setup/modules/12-hardware.sh      # optional GPU drivers
bash ~/unix_setup/modules/13-hibernate.sh     # configure hibernation (see below)
```

---

## Step 6 — Hibernation setup (module 13)

Hibernation requires three things configured after install:

1. The kernel must know where swap is (`resume=` kernel parameter)
2. The initramfs must include the `resume` hook so the kernel can
   restore from swap during early boot
3. If swap is LUKS encrypted, it must be decrypted before resume runs

Module 13 handles all of this automatically:

```bash
bash ~/unix_setup/modules/13-hibernate.sh
```

After it runs, test hibernation:
```bash
sudo systemctl hibernate
```

The machine should power off. Press the power button — it should
restore exactly where you left off.

> **If hibernation fails** (boots fresh instead of restoring):
> The most common cause is the `resume=` parameter pointing at the
> wrong device. Run `lsblk -o NAME,UUID` to find your swap partition
> UUID and compare it to what module 13 configured.

---

## Encrypted swap and hibernation — how it works

The swap partition is LUKS encrypted. For hibernation to work, the
kernel needs to decrypt swap during early boot (before the root
filesystem is even mounted) so it can read the hibernation image.

Module 13 sets this up using a **keyfile**:

> This is less secure than placing swap inside the same encrypted LVM
> container as root. If `/boot` is unencrypted, the initramfs keyfile can be
> recovered by someone with physical access. Prefer the layout in
> [`encrypted-installation.md`](encrypted-installation.md).

1. A random keyfile is generated and stored in `/etc/cryptsetup-keys.d/swap.key`
2. The keyfile is added to the swap partition's LUKS keyslots
   (`cryptsetup luksAddKey`)
3. `/etc/crypttab` is updated to unlock swap using the keyfile at boot
4. The keyfile is added to the initramfs so it's available during early boot
5. `resume=` is set to point at the decrypted swap device

This means:
- You still only enter one passphrase at boot (for the root partition)
- The swap partition is unlocked automatically using the keyfile
- Hibernation can then read/write the swap partition

---

## Troubleshooting

**Black screen after entering passphrase**
The DRM/KMS drivers may not be loading correctly. Boot to a TTY
(Ctrl+Alt+F2) and check `journalctl -b -p err`.

**"Failed to resume from hibernation"**
Check that the `resume` hook is in `/etc/mkinitcpio.conf` after
`encrypt` and before `filesystems`. Run `sudo mkinitcpio -P` to rebuild.

**Swap not encrypted after install**
If you forgot to set encryption on the swap partition during archinstall,
module 13 will warn you. You'll need to reformat the swap partition
with LUKS — back up anything important first.

**Can't boot after running module 06 (snapper)**
Use [`bootloader-recovery.md`](bootloader-recovery.md) to unlock the encrypted
root, mount the correct Btrfs subvolume, and repair the detected bootloader.
Do not create or delete subvolumes until the system boots normally and the
actual cause has been identified.
