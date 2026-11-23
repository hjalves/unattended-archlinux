#!/usr/bin/env bash
set -Eeuo pipefail

ISO_ROOT="/srv/tftp/archiso"
SFS="$ISO_ROOT/arch/x86_64/airootfs.sfs"

DISK="/dev/sda"
USERNAME="dk"
HOSTNAME="arch"

WORK="/var/tmp/arch-pxe-build"
ROOTFS="$WORK/rootfs"

# ---------------------------------------------------------
# Host-side checks
# ---------------------------------------------------------

if [[ $EUID -ne 0 ]]; then
    echo "Run as root: sudo $0" >&2
    exit 1
fi

for cmd in unsquashfs mksquashfs openssl python3 sfdisk; do
    command -v "$cmd" >/dev/null || {
        echo "Missing dependency: $cmd" >&2
        exit 1
    }
done

[[ -f "$SFS" ]] || {
    echo "Cannot find: $SFS" >&2
    exit 1
}

[[ -w "$ISO_ROOT" ]] || {
    echo "Destination is not writable: $ISO_ROOT" >&2
    exit 1
}

if [[ -e "$SFS.original" ]]; then
    echo "Backup already exists: $SFS.original"
    echo "Refusing to overwrite it."
    exit 1
fi

if [[ -e "$WORK" ]]; then
    echo "Temporary directory already exists: $WORK"
    echo "Remove it manually before running this script again."
    exit 1
fi

echo
echo "========================================"
echo " Arch Linux unattended PXE installer"
echo "========================================"
echo
echo "ISO directory: $ISO_ROOT"
echo "Target disk:   $DISK"
echo "Partitioning:  MBR"
echo "Filesystem:    ext4"
echo "Bootloader:    GRUB (BIOS)"
echo "Hostname:      $HOSTNAME"
echo "User:          $USERNAME"
echo

read -rsp "Password for $USERNAME: " PASSWORD
echo
read -rsp "Confirm password: " PASSWORD_CONFIRM
echo

if [[ -z "$PASSWORD" || "$PASSWORD" != "$PASSWORD_CONFIRM" ]]; then
    echo "Passwords do not match or are empty." >&2
    exit 1
fi

PASSWORD_HASH=$(printf '%s' "$PASSWORD" | openssl passwd -6 -stdin)
unset PASSWORD PASSWORD_CONFIRM

# ---------------------------------------------------------
# Prepare workspace
# ---------------------------------------------------------

mkdir -p "$ROOTFS"

cleanup() {
    rm -rf "$WORK"
}

trap cleanup EXIT

# ---------------------------------------------------------
# Extract original SquashFS
# ---------------------------------------------------------

echo
echo "Extracting airootfs.sfs..."

unsquashfs -d "$ROOTFS" "$SFS"

if [[ ! -f "$ROOTFS/usr/share/kbd/consolefonts/ter-132b.psf.gz" ]]; then
    echo "The ISO does not contain the ter-132b console font." >&2
    exit 1
fi

if [[ -f "$ROOTFS/etc/vconsole.conf" ]]; then
    sed -i '/^[[:space:]]*FONT[[:space:]]*=/d' "$ROOTFS/etc/vconsole.conf"
fi
printf '\nFONT=ter-132b\n' >> "$ROOTFS/etc/vconsole.conf"

# ---------------------------------------------------------
# Archinstall configuration
# ---------------------------------------------------------

CONFIG_DIR="$ROOTFS/root/pxe-install"

mkdir -p "$CONFIG_DIR"

# IMPORTANT:
# Export ROOTFS so Python writes into the extracted
# filesystem, not the host's actual /root directory.

export PASSWORD_HASH USERNAME ROOTFS HOSTNAME

echo
echo "Generating Archinstall configuration..."

python3 <<'PY'
import json
import os
from pathlib import Path

directory = Path(os.environ["ROOTFS"]) / "root/pxe-install"
directory.mkdir(parents=True, exist_ok=True)

config = {
    "archinstall-language": "English",

    "bootloader": "Grub",

    "hostname": os.environ["HOSTNAME"],

    "kernels": ["linux"],

    "locale_config": {
        "kb_layout": "us",
        "sys_enc": "UTF-8",
        "sys_lang": "en_US",
        "console_font": "ter-132b"
    },

    "mirror_config": {
        "mirror_regions": {
            "Portugal": []
        }
    },

    "ntp": True,

    "packages": ["git", "htop", "less", "openssh", "terminus-font"],

    "profile_config": None,

    "services": ["sshd", "systemd-networkd", "systemd-resolved"],

    "silent": True,

    "swap": False,

    "timezone": "Europe/Lisbon",

    "disk_config": {
        "config_type": "pre_mounted_config",
        "mountpoint": "/mnt/archinstall"
    }
}

credentials = {
    "users": [
        {
            "username": os.environ["USERNAME"],
            "enc_password": os.environ["PASSWORD_HASH"],
            "sudo": True
        }
    ]
}

(directory / "user_configuration.json").write_text(
    json.dumps(config, indent=2) + "\n"
)

(directory / "user_credentials.json").write_text(
    json.dumps(credentials, indent=2) + "\n"
)

print("Configuration files created:")
print(directory / "user_configuration.json")
print(directory / "user_credentials.json")
PY

[[ -s "$CONFIG_DIR/user_configuration.json" ]]
[[ -s "$CONFIG_DIR/user_credentials.json" ]]

# ---------------------------------------------------------
# Automatic installer
# ---------------------------------------------------------

echo
echo "Creating automatic installer..."

cat > "$ROOTFS/usr/local/bin/pxe-install.sh" <<'INSTALLER'
#!/usr/bin/bash
set -Eeuo pipefail

LOG="/var/log/pxe-install.log"

exec > >(tee -a "$LOG") 2>&1

DISK="/dev/sda"
MOUNT="/mnt/archinstall"

echo "========================================"
echo " Starting unattended Arch installation"
echo "========================================"

# Wait for network connectivity.

echo "Waiting for network..."

for i in $(seq 1 300); do
    if ip route get 1.1.1.1 >/dev/null 2>&1; then
        break
    fi

    sleep 2
done

ip route get 1.1.1.1 >/dev/null 2>&1 || {
    echo "Network unavailable. Aborting."
    exit 1
}

# Verify target disk.

if [[ ! -b "$DISK" ]]; then
    echo "Target disk not found: $DISK"
    exit 1
fi

echo "Target disk information:"
lsblk "$DISK"

# Unmount previous mounts.

umount -R "$MOUNT" 2>/dev/null || true

# ---------------------------------------------------------
# Partition disk
# ---------------------------------------------------------

echo "Partitioning $DISK..."

# WARNING: THIS ERASES THE ENTIRE DISK.

sfdisk --wipe always --wipe-partitions always "$DISK" <<'EOF'
label: dos
unit: sectors

start=2048, size=+512M, type=83, bootable
type=83
EOF

partprobe "$DISK"
udevadm settle

# ---------------------------------------------------------
# Format partitions
# ---------------------------------------------------------

echo "Formatting partitions..."

mkfs.ext4 -F "${DISK}1"
mkfs.ext4 -F "${DISK}2"

# ---------------------------------------------------------
# Mount target
# ---------------------------------------------------------

mkdir -p "$MOUNT"

mount "${DISK}2" "$MOUNT"

mkdir -p "$MOUNT/boot"

mount "${DISK}1" "$MOUNT/boot"

echo "Disk layout:"
lsblk -f "$DISK"

# ---------------------------------------------------------
# Run Archinstall
# ---------------------------------------------------------

echo "Starting Archinstall..."

archinstall \
    --config /root/pxe-install/user_configuration.json \
    --creds /root/pxe-install/user_credentials.json \
    --silent

if ! mountpoint -q "$MOUNT"; then
    echo "Target filesystem is not mounted: $MOUNT" >&2
    exit 1
fi

if [[ ! -f "$MOUNT/usr/share/kbd/consolefonts/ter-132b.psf.gz" ]]; then
    echo "The target system does not contain the ter-132b console font." >&2
    exit 1
fi

if [[ -f "$MOUNT/etc/vconsole.conf" ]]; then
    sed -i '/^[[:space:]]*FONT[[:space:]]*=/d' "$MOUNT/etc/vconsole.conf"
fi
printf '\nFONT=ter-132b\n' >> "$MOUNT/etc/vconsole.conf"

echo "Configuring target networking..."

mkdir -p "$MOUNT/etc/systemd/network" "$MOUNT/etc/sysctl.d"
cat > "$MOUNT/etc/sysctl.d/90-disable-ipv6.conf" <<'SYSCTL'
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
SYSCTL

cat > "$MOUNT/etc/systemd/network/20-ethernet.network" <<'NETWORK'
[Match]
Kind=!*
Type=ether

[Network]
DHCP=ipv4
IPv6AcceptRA=no
LinkLocalAddressing=ipv4
NETWORK

ln -sfnT /run/systemd/resolve/stub-resolv.conf "$MOUNT/etc/resolv.conf"

echo "Installation completed successfully."

sync

echo "Rebooting..."

systemctl reboot
INSTALLER

chmod 755 "$ROOTFS/usr/local/bin/pxe-install.sh"

# ---------------------------------------------------------
# Systemd service
# ---------------------------------------------------------

echo
echo "Creating systemd service..."

mkdir -p "$ROOTFS/etc/systemd/system"
mkdir -p "$ROOTFS/etc/systemd/system/multi-user.target.wants"

cat > "$ROOTFS/etc/systemd/system/pxe-install.service" <<'SERVICE'
[Unit]
Description=Unattended Arch Linux PXE Installation
After=network.target
Wants=network.target
ConditionPathExists=/root/pxe-install/user_configuration.json

[Service]
Type=oneshot
ExecStart=/usr/local/bin/pxe-install.sh
StandardOutput=journal+console
StandardError=journal+console
TimeoutStartSec=infinity

[Install]
WantedBy=multi-user.target
SERVICE

ln -sfn \
    ../pxe-install.service \
    "$ROOTFS/etc/systemd/system/multi-user.target.wants/pxe-install.service"

# ---------------------------------------------------------
# Rebuild SquashFS
# ---------------------------------------------------------

echo
echo "Rebuilding airootfs.sfs..."

mksquashfs "$ROOTFS" "$WORK/airootfs.sfs" \
    -noappend \
    -comp zstd \
    -b 1M

# ---------------------------------------------------------
# Replace original image
# ---------------------------------------------------------

echo
echo "Backing up original image..."

mv "$SFS" "$SFS.original"

echo "Installing modified image..."

if ! mv "$WORK/airootfs.sfs" "$SFS"; then
    echo "Failed to replace image. Restoring original..."

    mv "$SFS.original" "$SFS"
    exit 1
fi

chmod 644 "$SFS"

echo
echo "========================================"
echo " PXE installer successfully configured!"
echo "========================================"
echo
echo "Modified image:"
echo "  $SFS"
echo
echo "Original backup:"
echo "  $SFS.original"
echo
echo "Boot using your existing GRUB PXE entry."
echo
echo "The unattended installer will start automatically."
