# Unattended Arch Linux PXE Installer

This repository provides scripts for preparing an Arch Linux PXE boot image that automatically installs Arch Linux on a client machine.

The workflow is:

1. Download an Arch Linux ISO.
2. Extract the ISO into `/srv/tftp/archiso`.
3. Modify the extracted `airootfs.sfs` with an automatic installer.
4. Boot the modified image using an existing GRUB PXE entry.
5. The client partitions `/dev/sda`, formats it, installs Arch with `archinstall`, and reboots.

> **Warning:** The generated installer erases the entire `/dev/sda` disk on the client. Use it only on a disposable or correctly identified machine. Back up any data before booting it.

## Requirements

### PXE server

- Linux host with root or `sudo` access
- `bash`
- `curl` and `sha256sum` (for downloading the ISO)
- `unsquashfs`
- `mksquashfs`
- `openssl`
- `python3`
- `sha512sum`
- An Arch Linux ISO
- The ISO must contain the `ter-132b` console font (provided by `terminus-font`)
- A writable PXE/HTTP/TFTP tree at `/srv/tftp/archiso`
- An existing GRUB PXE configuration that boots the Arch image

### PXE client

The client must:

- Boot the Arch image through PXE
- Have the target disk available at the path set by `DISK` in `make-pxe-unattended.sh` (default `/dev/sda`)
- Have network connectivity during installation

## Usage

### 1. Download the Arch ISO

```bash
./download-archiso.sh
```

This downloads the latest x86_64 ISO with its original, dated filename (for example, `archlinux-2026.11.01-x86_64.iso`) in the current directory and checks its SHA-256 checksum against Arch Linux's published checksum. An optional output path can be supplied; existing files are not overwritten.

### 2. Extract the Arch ISO

Run:

```bash
./extract-archiso.sh archlinux-YYYY.MM.DD-x86_64.iso
```

The script mounts the ISO read-only, copies its contents into a fresh `/srv/tftp/archiso.new`, and then swaps it in as `/srv/tftp/archiso`. Files from an older ISO are never mixed with the new one. The tree being replaced (including any `airootfs.sfs.original` backup from `make-pxe-unattended.sh`) is kept as `/srv/tftp/archiso.previous` until the next extraction, which deletes it.

After extracting a new ISO, run `make-pxe-unattended.sh` again.

### GRUB PXE menuentry

Add entries like these to the GRUB PXE configuration (BIOS netboot GRUB):

```grub
insmod biosdisk
insmod part_msdos
insmod ext2
insmod search_fs_file
insmod regexp
set timeout=5

# Machines installed by the unattended Arch installer have
# /etc/pxe-installed on their root partition. If a local disk has it, boot
# that disk by default instead of reinstalling (which would wipe it again).
set disk=hd0
if search --no-floppy --file --set=found /etc/pxe-installed; then
    regexp --set=1:disk '^(hd[0-9]+)' "$found"
    set default=local
else
    set default=arch-install
fi

menuentry "Boot from hard drive" --id local {
    set root=($disk)
    chainloader +1
}

menuentry "Arch Linux - Automated Installation (WIPES DISK)" --id arch-install {
    linux (tftp)/archiso/arch/boot/x86_64/vmlinuz-linux \
        archisobasedir=arch \
        archiso_http_srv=http://192.168.10.2:8888/archiso/ \
        ip=:::::eth0:dhcp
    initrd (tftp)/archiso/arch/boot/x86_64/initramfs-linux.img
}
```

The kernel and initramfs are loaded from TFTP. The `archiso_http_srv` URL must serve the extracted image over HTTP, with the `arch` directory beneath `/archiso/`. Replace `192.168.10.2:8888` with the PXE server's HTTP address and port, and change `eth0` if the client uses a different interface name.

The installer writes `/etc/pxe-installed` to the new system, so after installation every PXE boot of that machine defaults to its local disk instead of reinstalling. To reinstall, pick the installation entry in the menu. The netboot GRUB must be 2.12 or newer: older versions cannot read the ext4 filesystems current `mkfs.ext4` creates (`metadata_csum_seed`), so they never find the marker.

### 3. Configure the unattended installer

Run as root:

```bash
sudo ./make-pxe-unattended.sh
```

The script:

- Reads `/srv/tftp/archiso/arch/x86_64/airootfs.sfs`
- Prompts for the new user's password
- Adds Archinstall configuration and credentials
- Configures the live console to use `ter-132b`
- Installs a systemd service that starts the installer automatically
- Rebuilds the SquashFS image next to the original
- Saves the original image as `airootfs.sfs.original`
- Atomically replaces the PXE image with the modified image
- Regenerates `airootfs.sha512` and moves the original `airootfs.sha512` and the signatures (`airootfs.sfs.sig`, `airootfs.sfs.cms.sig`) aside with an `.original` suffix

The signatures cannot be regenerated for the modified image, so do not boot it with `verify=y` or `cms_verify=y`. `checksum=y` works.

After it completes, boot the client using the existing GRUB PXE entry.

## Default installation settings

The generated installation uses:

- Target disk: `/dev/sda`
- Partition table: MBR/DOS
- Partition 1: 512 MiB, ext4, mounted at `/boot`
- Partition 2: remaining space, ext4, mounted at `/`
- Bootloader: GRUB for BIOS
- Kernel: `linux`
- Hostname: `dell`
- User: `dk`, with passwordless `sudo` (`/etc/sudoers.d/90_dk`)
- Locale: `en_US.UTF-8`
- Keyboard layout: `uk`
- Console font: `ter-132b`
- Time zone: `Europe/Lisbon`
- NTP: enabled
- Swap: disabled
- Additional packages: `git`, `htop`, `less`, `openssh`, `terminus-font`
- SSH server: `sshd` enabled on boot
- Networking: systemd-networkd with IPv4 DHCP on physical Ethernet interfaces; IPv6 disabled
- DNS: systemd-resolved with multicast DNS enabled
- Kernel command line: `quiet` removed so boot messages are shown; `consoleblank=600` blanks the console (and powers off the display) after 10 minutes of inactivity

These values are defined near the top of `make-pxe-unattended.sh` and in the generated installer/configuration. Review and change them before running the script if they do not match your environment.

Ethernet connectivity requires a DHCP server. Wi-Fi is not configured.

## Restoring the original image

The preparation script refuses to overwrite an existing backup. To restore the original image, checksum and signatures:

```bash
cd /srv/tftp/archiso/arch/x86_64
for f in airootfs.sfs airootfs.sha512 airootfs.sfs.sig airootfs.sfs.cms.sig; do
    [[ -e "$f.original" ]] && sudo mv -T "$f.original" "$f"
done
```

Only remove or replace the backup after verifying that the modified image is no longer needed.

## Safety notes

- The installer waits for network connectivity before modifying the disk.
- The target disk is not discovered automatically; it is set by `DISK` at the top of `make-pxe-unattended.sh` (default `/dev/sda`).
- The installation runs automatically from a systemd `oneshot` service.
- The temporary build directory is `/var/tmp/arch-pxe-build`; an existing directory causes the preparation script to stop.
- The generated credentials are placed inside the image. Protect the PXE image and PXE network accordingly.
