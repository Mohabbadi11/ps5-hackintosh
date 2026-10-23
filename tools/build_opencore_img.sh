#!/bin/bash
#
# PS5 Hackintosh — Build OpenCore disk image (qcow2)
#
# Creates a GPT disk with an ESP FAT32 partition containing the
# OpenCore EFI, then converts to qcow2 for QEMU.
#
# Uses Docker on macOS (hdiutil produces images with wrong partition
# type that OVMF rejects). On Linux, uses parted/losetup directly.
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

build_on_linux() {
    local raw_img="$1"
    local efi_src="$2"

    qemu-img create -f raw "$raw_img" 256M
    LOOP=$(losetup -f --show "$raw_img")
    parted -s "$LOOP" mklabel gpt
    parted -s "$LOOP" mkpart EFI fat32 1MiB 100%
    parted -s "$LOOP" set 1 esp on
    partprobe "$LOOP" 2>/dev/null || sleep 1
    mkfs.vfat -F32 "${LOOP}p1"

    MNT=$(mktemp -d)
    mount "${LOOP}p1" "$MNT"
    cp -R "$efi_src/EFI" "$MNT/"
    sync
    umount "$MNT"
    losetup -d "$LOOP"
    rmdir "$MNT"
}

RAW_TMP="/tmp/ps5-oc-raw-$$.img"
trap "rm -f '$RAW_TMP'" EXIT

if [ "$(uname)" = "Linux" ]; then
    build_on_linux "$RAW_TMP" "$EFI_DIR"
    qemu-img convert -f raw -O qcow2 "$RAW_TMP" "$OUTPUT"
else
    # macOS: usar Docker para crear la imagen con parted (ESP correcto)
    if ! docker info >/dev/null 2>&1; then
        echo "ERROR: Docker necesario en macOS para crear imagen OpenCore."
        echo "hdiutil produce particiones 'Microsoft Basic Data' que OVMF rechaza."
        exit 1
    fi

    echo "  Usando Docker para crear imagen con ESP correcto..."
    docker run --rm --platform linux/amd64 \
        --privileged \
        -v "$EFI_DIR:/efi:ro" \
        -v "$BUILD:/out" \
        alpine:3.20 sh -c '
        set -e
        apk add --no-cache sgdisk dosfstools qemu-img >/dev/null 2>&1

        RAW=/tmp/opencore.raw
        FAT=/tmp/opencore-fat.img

        # Crear imagen raw con GPT + partición ESP (tipo EF00)
        dd if=/dev/zero of="$RAW" bs=1M count=256 2>/dev/null
        sgdisk -n 1:2048:0 -t 1:EF00 "$RAW"

        # Crear FAT32 aparte (254 MiB — espacio dentro de la partición ESP)
        dd if=/dev/zero of="$FAT" bs=1M count=254 2>/dev/null
        mkfs.vfat -F32 "$FAT"

        # Montar FAT32 y copiar EFI
        MNT=$(mktemp -d)
        mount -o loop "$FAT" "$MNT"
        cp -R /efi/EFI "$MNT/"
        sync
        umount "$MNT"
        rmdir "$MNT"

        # Insertar FAT32 en la imagen GPT en el offset correcto
        dd if="$FAT" of="$RAW" bs=512 seek=2048 conv=notrunc 2>/dev/null
        rm "$FAT"

        # Convertir a qcow2
        qemu-img convert -f raw -O qcow2 "$RAW" /out/OpenCore.img
        rm "$RAW"

        echo "OpenCore.img creado en Docker"
    '
fi

echo ""
echo "OpenCore.img creado: $OUTPUT ($(du -h "$OUTPUT" | cut -f1))"
echo ""
echo "Contenido del EFI:"
ls -la "$EFI_DIR/EFI/BOOT/" 2>/dev/null | tail -n+2 | sed 's/^/  /'
echo "  ---"
ls "$EFI_DIR/EFI/OC/Kexts/" 2>/dev/null | sed 's/^/  /'
