#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
    echo "Usage: $0 <path-to-iso>" >&2
    exit 1
fi

ISO="$1"
DEST="/srv/tftp/archiso"
# The new tree is assembled here and swapped in, so files from an older
# ISO (including .original backups made by make-pxe-unattended.sh) are
# never mixed with the new one. The tree it replaces is kept as
# $PREVIOUS until the next extraction.
STAGING="$DEST.new"
PREVIOUS="$DEST.previous"

if [[ ! -f "$ISO" ]]; then
    echo "Error: ISO not found: $ISO" >&2
    exit 1
fi

if [[ -e "$STAGING" ]]; then
    echo "Error: leftover staging directory from an interrupted run: $STAGING" >&2
    echo "Remove it manually before running this script again." >&2
    exit 1
fi

MOUNT=$(mktemp -d)

cleanup() {
    sudo umount "$MOUNT" 2>/dev/null || true
    rmdir "$MOUNT"
    # Only present if the run failed before the final swap.
    sudo rm -rf -- "$STAGING"
}
trap cleanup EXIT

echo "Mounting ISO: $ISO"
sudo mount -o loop,ro "$ISO" "$MOUNT"

echo "Extracting into $STAGING..."
sudo mkdir -p "$STAGING"
sudo cp -a "$MOUNT/." "$STAGING/"
# ISO 9660 trees are read-only; let the owner (root) modify the copy.
sudo chmod -R u+w "$STAGING"

if [[ -e "$DEST" ]]; then
    if [[ -e "$PREVIOUS" ]]; then
        echo "Removing older tree: $PREVIOUS"
        sudo rm -rf -- "$PREVIOUS"
    fi
    echo "Keeping current tree as: $PREVIOUS"
    sudo mv -T -- "$DEST" "$PREVIOUS"
fi

sudo mv -T -- "$STAGING" "$DEST"

echo "Extraction complete!"
