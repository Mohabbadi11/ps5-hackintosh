#!/bin/bash
#
# PS5 Hackintosh — Create bootable USB drive (3 partitions)
#
# Interactive wizard that lists external disks, lets you choose,
# and creates the USB with the required layout.
#
# USB layout:
#   Partition 1 (FAT32, ~500MB): bzImage, initrd.img, cmdline.txt
#   Partition 2 (ext4, ~1.2GB):  Alpine rootfs with QEMU
#   Partition 3 (exFAT, rest):   macos/ with OpenCore.img, OVMF, macOS.img
#
# Usage: ./tools/create_usb.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD="$PROJECT_DIR/build"

echo ""
echo "╔══════════════════════════════════════════════════╗"
echo "║  PS5 Hackintosh — USB Drive Setup               ║"
echo "╚══════════════════════════════════════════════════╝"
echo ""

# ── Check build artifacts ────────────────────────────
echo "Checking build artifacts..."
echo ""
MISSING=""
ALL_OK=true
for f in bzImage initrd.img OpenCore.img OVMF_CODE.fd OVMF_VARS.fd rootfs.img macOS.img; do
    if [ -f "$BUILD/$f" ]; then
        printf "  %-20s %s\n" "$f" "$(du -h "$BUILD/$f" | cut -f1)"
    else
        printf "  %-20s MISSING\n" "$f"
        MISSING="$MISSING $f"
        ALL_OK=false
    fi
done
echo ""

if [ "$ALL_OK" = false ]; then
    echo "ERROR: Missing artifacts:$MISSING"
    echo ""
    echo "Build them first:"
    echo "  ./tools/build_kernel.sh      # bzImage"
    echo "  make initramfs               # initrd.img"
    echo "  ./tools/fetch_opencore.sh    # kexts + drivers"
    echo "  ./tools/build_opencore_img.sh # OpenCore.img"
    echo "  ./tools/create_rootfs.sh     # rootfs.img"
    echo "  ./tools/create_macos_img.sh  # macOS.img"
    exit 1
fi

# ── List external disks ─────────────────────────────
echo "Scanning for external disks..."
echo ""

DISKS=()
DISK_INFO=()

while IFS= read -r line; do
    disk=$(echo "$line" | awk '{print $1}')
    [ -z "$disk" ] && continue

    # Only accept "external" disks — skip internal, synthesized, disk images
    case "$line" in
        *external*) ;;
        *) continue ;;
    esac

    info=$(diskutil info "$disk" 2>/dev/null) || continue

    disk_size=$(echo "$info" | grep "Disk Size:" | sed 's/.*:[ ]*//' | sed 's/ (.*//' || true)
    disk_name=$(echo "$info" | grep "Media Name:" | sed 's/.*:[ ]*//' || true)
    [ -z "$disk_name" ] && disk_name="(unnamed)"

    DISKS+=("$disk")
    DISK_INFO+=("$(printf "%-12s  %-10s  %s" "$disk" "$disk_size" "$disk_name")")

done < <(diskutil list 2>/dev/null | grep "^/dev/disk")

if [ ${#DISKS[@]} -eq 0 ]; then
    echo "  No external disks found."
    echo ""
    echo "  Connect a USB drive (64 GB minimum) and try again."
    exit 1
fi

echo "  External disks found:"
echo ""
printf "  %-4s %-12s  %-10s  %s\n" "#" "Device" "Size" "Name"
echo "  ─────────────────────────────────────────────────"

for i in "${!DISK_INFO[@]}"; do
    printf "  %-4s %s\n" "[$((i+1))]" "${DISK_INFO[$i]}"
done
echo ""

# ── Select disk ──────────────────────────────────────
read -p "  Select disk (1-${#DISKS[@]}) or 'q' to quit: " CHOICE

if [ "$CHOICE" = "q" ] || [ "$CHOICE" = "Q" ]; then
    echo "  Cancelled."
    exit 0
fi

if ! [[ "$CHOICE" =~ ^[0-9]+$ ]] || [ "$CHOICE" -lt 1 ] || [ "$CHOICE" -gt ${#DISKS[@]} ]; then
    echo "  Invalid selection."
    exit 1
fi

DISK="${DISKS[$((CHOICE-1))]}"

# ── Show details and confirm ─────────────────────────
echo ""
echo "  ┌─────────────────────────────────────────────┐"
echo "  │  SELECTED DISK                              │"
echo "  └─────────────────────────────────────────────┘"
diskutil info "$DISK" | grep -E "Device Node:|Media Name:|Disk Size:|Removable|Protocol:" | sed 's/^/  /'
echo ""

echo "  Current partitions:"
diskutil list "$DISK" 2>/dev/null | tail -n+2 | sed 's/^/  /'
echo ""

echo "  WARNING: ALL data on this disk will be ERASED."
echo "  3 partitions will be created for PS5 Hackintosh."
echo ""
read -p "  Are you sure? Type 'ERASE' to confirm: " CONFIRM

if [ "$CONFIRM" != "ERASE" ]; then
    echo "  Cancelled. (Type exactly 'ERASE' to confirm)"
    exit 0
fi

echo ""

# ── Partition ────────────────────────────────────────
echo "[1/7] Unmounting disk..."
diskutil unmountDisk "$DISK" 2>/dev/null || true

echo "[2/7] Creating MBR partition table..."
echo "  Part 1: FAT32  500 MB  (boot: bzImage + initrd)"
echo "  Part 2: FAT32  1.2 GB  (placeholder, will be overwritten with ext4 rootfs)"
echo "  Part 3: exFAT  rest    (macos: OpenCore + macOS.img)"
# MBR instead of GPT: avoids the automatic EFI partition that confuses the loader
diskutil partitionDisk "$DISK" MBR \
    FAT32 PS5BOOT 500MB \
    FAT32 ROOTFS 1200MB \
    ExFAT PS5MACOS R

echo ""
echo "[3/7] Copying boot files to PS5BOOT..."
BOOT_VOL="/Volumes/PS5BOOT"
for i in $(seq 1 5); do [ -d "$BOOT_VOL" ] && break; sleep 1; done
if [ -d "$BOOT_VOL" ]; then
    cp "$BUILD/bzImage" "$BOOT_VOL/"
    cp "$BUILD/initrd.img" "$BOOT_VOL/"
    # usb/cmdline.txt carries the video mode of the author's screen (HDMI-A-1, 2560x1440@60): edit it for yours first, see the README
    cp "$PROJECT_DIR/usb/cmdline.txt" "$BOOT_VOL/"
    [ -f "$PROJECT_DIR/usb/vram.txt" ] && cp "$PROJECT_DIR/usb/vram.txt" "$BOOT_VOL/"
    echo "  bzImage + initrd.img + cmdline.txt copied"
else
    echo "  Error: $BOOT_VOL not mounted"
    exit 1
fi

echo "[4/7] Unmounting all partitions before writing rootfs..."
diskutil unmountDisk "$DISK" 2>/dev/null || true
sleep 1

echo "[5/7] Writing rootfs ext4 image (requires sudo)..."
# Partition 2 (ROOTFS placeholder) is overwritten with the ext4 image
PART2="${DISK}s2"
if [ -e "$PART2" ]; then
    sudo dd if="$BUILD/rootfs.img" of="$PART2" bs=4M 2>&1
    echo "  rootfs ext4 written to $PART2"
else
    echo "  Error: $PART2 not found"
    exit 1
fi

echo "[6/7] Copying macOS files to PS5MACOS..."
# Remount only PS5MACOS (partition 3)
PART3="${DISK}s3"
diskutil mount "$PART3" 2>/dev/null || true
MACOS_VOL="/Volumes/PS5MACOS"
for i in $(seq 1 5); do [ -d "$MACOS_VOL" ] && break; sleep 1; done

if [ -d "$MACOS_VOL" ]; then
    mkdir -p "$MACOS_VOL/macos"
    echo "  Copying OpenCore.img..."
    cp "$BUILD/OpenCore.img" "$MACOS_VOL/macos/"
    echo "  Copying OVMF_CODE.fd..."
    cp "$BUILD/OVMF_CODE.fd" "$MACOS_VOL/macos/"
    echo "  Copying OVMF_VARS.fd..."
    cp "$BUILD/OVMF_VARS.fd" "$MACOS_VOL/macos/"
    echo "  Copying macOS.img ($(du -h "$BUILD/macOS.img" | cut -f1) — this may take a while)..."
    cp "$BUILD/macOS.img" "$MACOS_VOL/macos/"
    echo "  All files copied to PS5MACOS"
else
    echo "  Error: $MACOS_VOL not mounted"
    exit 1
fi

echo "[7/7] Syncing and ejecting..."
sync
diskutil unmountDisk "$DISK" 2>/dev/null || true

echo ""
echo "═══════════════════════════════════════════════════"
echo ""
echo "  USB DRIVE READY"
echo ""
echo "  Partition 1 (FAT32  PS5BOOT):  bzImage + initrd + cmdline"
echo "  Partition 2 (ext4):            Alpine rootfs + QEMU + ds-mouse"
echo "  Partition 3 (exFAT  PS5MACOS): OpenCore + OVMF + macOS.img"
echo ""
echo "  Next steps:"
echo "    1. Connect the USB drive to your PS5"
echo "    2. Activate the jailbreak on the PS5"
echo "    3. Run: ./tools/launch_hackintosh.sh"
echo ""
echo "═══════════════════════════════════════════════════"
