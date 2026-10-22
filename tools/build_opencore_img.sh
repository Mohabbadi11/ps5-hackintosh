#!/bin/bash
#
# PS5 Hackintosh — Build OpenCore disk image (qcow2)
#
# Creates a FAT32 disk image with the OpenCore EFI, then converts
# to qcow2 for QEMU. Works on macOS (hdiutil) and Linux (losetup).
#
# Usage: ./tools/build_opencore_img.sh [EFI_DIR] [output.img]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD="$PROJECT_DIR/build"

EFI_DIR="${1:-$BUILD/opencore}"
OUTPUT="${2:-$BUILD/OpenCore.img}"

if [ ! -d "$EFI_DIR/EFI" ]; then
    echo "Error: $EFI_DIR/EFI no existe."
    echo "Ejecuta primero: ./tools/fetch_opencore.sh"
    exit 1
fi

echo "Construyendo imagen OpenCore..."
echo "  EFI: $EFI_DIR"
echo "  Output: $OUTPUT"

DMG_TMP=$(mktemp /tmp/oc_XXXXXX.dmg)
RAW_TMP=$(mktemp /tmp/oc_XXXXXX.raw)
trap "rm -f '$DMG_TMP' '$RAW_TMP'" EXIT

if command -v hdiutil &>/dev/null; then
    # macOS: crear DMG con hdiutil
    hdiutil create -size 256m -fs FAT32 -volname OPENCORE \
        -layout GPTSPUD -ov "$DMG_TMP" >/dev/null

    MOUNT_INFO=$(hdiutil attach "$DMG_TMP" -nobrowse -noverify 2>/dev/null)
    DISK=$(echo "$MOUNT_INFO" | grep '/dev/disk' | head -1 | awk '{print $1}')
    VOL=$(echo "$MOUNT_INFO" | grep '/Volumes/' | sed 's/.*\/Volumes\//\/Volumes\//')

    cp -R "$EFI_DIR/EFI" "$VOL/"
    echo "  Contenido copiado a imagen"

    sync
    hdiutil detach "$DISK" -quiet 2>/dev/null || diskutil unmountDisk "$DISK" >/dev/null 2>&1

    # Convertir DMG → raw → qcow2
    hdiutil convert "$DMG_TMP" -format UDTO -o "${RAW_TMP%.raw}" >/dev/null 2>&1 || true

    if [ -f "${RAW_TMP%.raw}.cdr" ]; then
        qemu-img convert -f raw -O qcow2 "${RAW_TMP%.raw}.cdr" "$OUTPUT"
        rm -f "${RAW_TMP%.raw}.cdr"
    else
        # Alternativa directa
        qemu-img convert -f dmg -O qcow2 "$DMG_TMP" "$OUTPUT"
    fi
else
    # Linux
    qemu-img create -f raw "$RAW_TMP" 256M
    LOOP=$(losetup -f --show "$RAW_TMP")
    parted -s "$LOOP" mklabel gpt
    parted -s "$LOOP" mkpart EFI fat32 1MiB 100%
    parted -s "$LOOP" set 1 esp on
    partprobe "$LOOP"
    mkfs.vfat -F32 "${LOOP}p1"

    MNT=$(mktemp -d)
    mount "${LOOP}p1" "$MNT"
    cp -R "$EFI_DIR/EFI" "$MNT/"
    umount "$MNT"
    losetup -d "$LOOP"
    rmdir "$MNT"

    qemu-img convert -f raw -O qcow2 "$RAW_TMP" "$OUTPUT"
fi

echo ""
echo "OpenCore.img creado: $OUTPUT ($(du -h "$OUTPUT" | cut -f1))"
echo ""
echo "Contenido del EFI:"
ls -la "$EFI_DIR/EFI/BOOT/" 2>/dev/null | tail -n+2 | sed 's/^/  /'
echo "  ---"
ls "$EFI_DIR/EFI/OC/Kexts/" 2>/dev/null | sed 's/^/  /'
