#!/usr/bin/env bash
set -euo pipefail

if [[ $# -gt 1 ]]; then
    echo "Usage: $0 [output-iso]" >&2
    exit 1
fi

OUTPUT="${1:-archlinux-x86_64.iso}"
ISO_NAME="archlinux-x86_64.iso"
CHECKSUM_URL="https://archlinux.org/iso/latest/sha256sums.txt"
ISO_URL="https://fastly.mirror.pkgbuild.com/iso/latest/$ISO_NAME"

if [[ -e "$OUTPUT" || -L "$OUTPUT" ]]; then
    echo "Error: output already exists: $OUTPUT" >&2
    exit 1
fi

for cmd in curl sha256sum mktemp ln; do
    command -v "$cmd" >/dev/null || {
        echo "Missing dependency: $cmd" >&2
        exit 1
    }
done

CHECKSUMS=$(curl -fsSL "$CHECKSUM_URL")
EXPECTED=""
while IFS= read -r line; do
    if [[ "$line" =~ ^([[:xdigit:]]{64})[[:space:]]+[*]?archlinux-x86_64\.iso$ ]]; then
        if [[ -n "$EXPECTED" ]]; then
            echo "Error: multiple ISO checksums found." >&2
            exit 1
        fi
        EXPECTED="${BASH_REMATCH[1],,}"
    fi
done <<< "$CHECKSUMS"

if [[ -z "$EXPECTED" ]]; then
    echo "Error: ISO checksum not found." >&2
    exit 1
fi

OUTPUT_DIR=$(dirname -- "$OUTPUT")
TEMP_ISO=$(mktemp "$OUTPUT_DIR/.archlinux-iso.XXXXXXXX")
cleanup() {
    rm -f -- "$TEMP_ISO"
}
trap cleanup EXIT

echo "Downloading the latest Arch Linux ISO..."
curl -fL --output "$TEMP_ISO" "$ISO_URL"

ACTUAL=$(sha256sum < "$TEMP_ISO")
ACTUAL="${ACTUAL%% *}"
if [[ "$ACTUAL" != "$EXPECTED" ]]; then
    echo "Error: ISO SHA-256 checksum mismatch." >&2
    exit 1
fi

ln -T -- "$TEMP_ISO" "$OUTPUT"
echo "Verified ISO saved to: $OUTPUT"
