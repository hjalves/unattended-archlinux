#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
    echo "Usage: $0 <path-to-iso>" >&2
    exit 1
fi

ISO="$1"
DEST="/srv/tftp/archiso"

if [[ ! -f "$ISO" ]]; then
    echo "Error: ISO not found: $ISO" >&2
    exit 1
fi

MOUNT=$(mktemp -d)

cleanup() {
    sudo umount "$MOUNT" 2>/dev/null || true
    rmdir "$MOUNT"
}
trap cleanup EXIT

echo "Creating destination directory..."
sudo mkdir -p "$DEST"

echo "Mounting ISO: $ISO"
sudo mount -o loop,ro "$ISO" "$MOUNT"

echo "Extracting into $DEST..."
sudo cp -a "$MOUNT/." "$DEST/"

echo "Extraction complete!"
