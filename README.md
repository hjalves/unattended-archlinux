# Unattended Arch Linux PXE Installer

This repository provides scripts for preparing an Arch Linux PXE boot image that automatically installs Arch Linux on a client machine.

The workflow is:

1. Extract an Arch Linux ISO into `/srv/tftp/archiso`.
2. Modify the extracted `airootfs.sfs` with an automatic installer.
3. Boot the modified image using an existing GRUB PXE entry.
4. The client partitions `/dev/sda`, formats it, installs Arch with `archinstall`, and reboots.

> **Warning:** The generated installer erases the entire `/dev/sda` disk on the client. Use it only on a disposable or correctly identified machine. Back up any data before booting it.

## Requirements

### PXE server

- Linux host with root or `sudo` access
- `bash`
- `unsquashfs`
- `mksquashfs`
- `openssl`
- `python3`
- `sfdisk`
- An Arch Linux ISO
- A writable PXE/HTTP/TFTP tree at `/srv/tftp/archiso`
- An existing GRUB PXE configuration that boots the Arch image

### PXE client

The client must:

- Boot the Arch image through PXE
- Have the target disk available as `/dev/sda`
- Have network connectivity during installation

## Usage

### 1. Extract the Arch ISO

Run:

```bash
./extract-archiso.sh /path/to/archlinux-x86_64.iso
```

The script mounts the ISO read-only, copies its contents to `/srv/tftp/archiso`, and unmounts it when finished.

### 2. Configure the unattended installer

Run as root:

```bash
sudo ./make-pxe-unattended.sh
```

The script:

- Reads `/srv/tftp/archiso/arch/x86_64/airootfs.sfs`
- Prompts for the new user's password
- Adds Archinstall configuration and credentials
- Installs a systemd service that starts the installer automatically
- Rebuilds the SquashFS image
- Saves the original image as `airootfs.sfs.original`
- Replaces the PXE image with the modified image

After it completes, boot the client using the existing GRUB PXE entry.

## Default installation settings

The generated installation uses:

- Target disk: `/dev/sda`
- Partition table: MBR/DOS
- Partition 1: 512 MiB, ext4, mounted at `/boot`
- Partition 2: remaining space, ext4, mounted at `/`
- Bootloader: GRUB for BIOS
- Kernel: `linux`
- Hostname: `arch`
- User: `dk`
- Locale: `en_US.UTF-8`
- Keyboard layout: `us`
- Time zone: `Europe/Lisbon`
- NTP: enabled
- Swap: disabled
- Additional package: `git`

These values are defined near the top of `make-pxe-unattended.sh` and in the generated installer/configuration. Review and change them before running the script if they do not match your environment.

## Restoring the original image

The preparation script refuses to overwrite an existing backup. To restore the original image:

```bash
sudo mv /srv/tftp/archiso/arch/x86_64/airootfs.sfs.original \
  /srv/tftp/archiso/arch/x86_64/airootfs.sfs
```

Only remove or replace the backup after verifying that the modified image is no longer needed.

## Safety notes

- The installer waits for network connectivity before modifying the disk.
- The target disk is not discovered automatically; `/dev/sda` is hard-coded.
- The installation runs automatically from a systemd `oneshot` service.
- The temporary build directory is `/var/tmp/arch-pxe-build`; an existing directory causes the preparation script to stop.
- The generated credentials are placed inside the image. Protect the PXE image and PXE network accordingly.
