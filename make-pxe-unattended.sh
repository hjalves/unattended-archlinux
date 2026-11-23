#!/usr/bin/env bash
set -Eeuo pipefail

ISO_ROOT="/srv/tftp/archiso"
SFS="$ISO_ROOT/arch/x86_64/airootfs.sfs"
DISK="/dev/sda"
USERNAME="dk"
HOSTNAME="arch"
WORK="/var/tmp/arch-pxe-build"

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

echo "========================================"
echo " Arch Linux unattended PXE installer"
echo "========================================"
echo
echo "Target disk: $DISK"
echo "Partitioning: MBR"
echo "Filesystem: ext4"
echo "Bootloader: GRUB (BIOS)"
echo "User: $USERNAME"
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
# Prepare temporary workspace
# ---------------------------------------------------------

cleanup() {
    rm -rf "$WORK"
}

trap cleanup EXIT

mkdir -p "$WORK"

ROOTFS="$WORK/rootfs"
mkdir -p "$ROOTFS"

echo
echo "Extracting airootfs.sfs..."

unsquashfs -d "$ROOTFS" "$SFS"

# ---------------------------------------------------------
# Archinstall configuration
# ---------------------------------------------------------

CONFIG_DIR="$ROOTFS/root/pxe-install"
mkdir -p "$CONFIG_DIR"

export PASSWORD_HASH USERNAME

python3 <<'PY'
import json
import os
from pathlib import Path

directory = Path("/root/pxe-install")

config = {
    "archinstall-language": "English",

    "bootloader": "Grub",
    "bootloader_config": {
        "bootloader": "Grub",
        "uki": False,
        "removable": False
    },

    "disk_config": {
        "config_type": "pre_mounted_config",
        "mountpoint": "/mnt/archinstall"
    },

    "hostname": "arch",
    "kernels": ["linux"],

    "locale_config": {
        "kb_layout": "us",
        "sys_enc": "UTF-8",
        "sys_lang": "en_US"
    },

    "mirror_config": {
        "mirror_regions": {
            "Portugal": []
        }
    },

    "network_config": {
        "type": "manual",
        "nics": [
            {
                "iface": "eth0",
                "dhcp": True
            }
        ]
    },

    "ntp": True,
    "offline": False,
    "packages": ["git"],
    "profile_config": None,
    "script": "guided",
    "silent": True,
    "swap": False,
    "timezone": "Europe/Lisbon"
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

PY

# ---------------------------------------------------------
# Automatic installer
# ---------------------------------------------------------

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

# Unmount any previous mounts.
umount -R "$MOUNT" 2>/dev/null || true

# DESTROYS THE ENTIRE TARGET DISK.
echo "Partitioning $DISK..."

sfdisk --wipe always --wipe-partitions always "$DISK" <<'EOF'
label: dos
unit: sectors

start=2048, size=+512M, type=83, bootable
type=83
EOF

partprobe "$DISK"
udevadm settle

# Format partitions.
echo "Formatting partitions..."

mkfs.ext4 -F "${DISK}1"
mkfs.ext4 -F "${DISK}2"

# Mount target filesystem.
mkdir -p "$MOUNT"

mount "${DISK}2" "$MOUNT"
mkdir -p "$MOUNT/boot"
mount "${DISK}1" "$MOUNT/boot"

echo "Disk layout:"
lsblk -f "$DISK"

# Run Archinstall.
echo "Starting Archinstall..."

archinstall \
    --config /root/pxe-install/user_configuration.json \
    --creds /root/pxe-install/user_credentials.json \
    --silent

echo "Installation completed successfully."

sync

echo "Rebooting..."
systemctl reboot
INSTALLER

chmod 755 "$ROOTFS/usr/local/bin/pxe-install.sh"

# ---------------------------------------------------------
# Systemd service
# ---------------------------------------------------------

mkdir -p "$ROOTFS/etc/systemd/system"

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

mkdir -p "$ROOTFS/etc/systemd/system/multi-user.target.wants"

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

echo "Creating original image backup..."

mv "$SFS" "$SFS.original"
mv "$WORK/airootfs.sfs" "$SFS"

chmod 644 "$SFS"

echo
echo "========================================"
echo " PXE installer successfully configured!"
echo "========================================"
echo
echo "Modified: $SFS"
echo "Backup:   $SFS.original"
echo
echo "Boot your machine using your existing"
echo "Arch Linux - Automated Installation entry."
echo
echo "The installer will start automatically."
