#!/bin/bash
#
# PS5 Hackintosh — Build OpenCore disk image
#
# Creates a qcow2 disk image containing the OpenCore EFI
# bootloader, ready to use as the first boot disk in QEMU.
#
# Usage: ./tools/build_opencore_img.sh <EFI_DIR> <output.img>
#

set -euo pipefail

EFI_DIR="${1:-}"
OUTPUT="${2:-OpenCore.img}"

if [ -z "$EFI_DIR" ] || [ ! -d "$EFI_DIR/EFI" ]; then
    echo "Usage: $0 <directory-containing-EFI/> [output.img]"
    echo ""
    echo "The directory must contain an EFI/ folder with:"
    echo "  EFI/BOOT/BOOTx64.efi"
    echo "  EFI/OC/OpenCore.efi"
    echo "  EFI/OC/config.plist"
    echo "  EFI/OC/ACPI/*.aml"
    echo "  EFI/OC/Drivers/*.efi"
    echo "  EFI/OC/Kexts/*.kext"
    exit 1
fi

echo "Building OpenCore disk image..."

# Create a 512 MB raw image
RAW_IMG=$(mktemp /tmp/oc_raw_XXXXXX.img)
qemu-img create -f raw "$RAW_IMG" 512M

# Create GPT partition table with EFI System Partition
# Using hdiutil on macOS
if command -v hdiutil &>/dev/null; then
    # macOS path
    MOUNT_POINT=$(mktemp -d /tmp/oc_mount_XXXXXX)

    hdiutil attach -nomount "$RAW_IMG" 2>/dev/null || {
        # Format as FAT32
        DISK=$(hdiutil attach -nomount "$RAW_IMG" | head -1 | awk '{print $1}')
        diskutil eraseDisk FAT32 OPENCORE GPT "$DISK"
        MOUNT_POINT="/Volumes/OPENCORE"
    }

    # Copy EFI contents
    cp -R "$EFI_DIR/EFI" "$MOUNT_POINT/"

    # Unmount
    hdiutil detach "$DISK" 2>/dev/null || diskutil unmountDisk "$DISK"
else
    # Linux path
    LOOP=$(losetup -f --show "$RAW_IMG")
    parted -s "$LOOP" mklabel gpt
    parted -s "$LOOP" mkpart EFI fat32 1MiB 100%
    parted -s "$LOOP" set 1 esp on
    partprobe "$LOOP"
    mkfs.vfat -F32 "${LOOP}p1"

    MOUNT_POINT=$(mktemp -d)
    mount "${LOOP}p1" "$MOUNT_POINT"
    cp -R "$EFI_DIR/EFI" "$MOUNT_POINT/"
    umount "$MOUNT_POINT"
    losetup -d "$LOOP"
    rmdir "$MOUNT_POINT"
fi

# Convert to qcow2
qemu-img convert -O qcow2 "$RAW_IMG" "$OUTPUT"
rm -f "$RAW_IMG"

echo "OpenCore image created: $OUTPUT ($(du -h "$OUTPUT" | cut -f1))"
