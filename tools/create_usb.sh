#!/bin/bash
#
# PS5 Hackintosh — Preparar USB de arranque (3 particiones)
#
# Estructura del USB:
#   Partición 1 (FAT32, ~500MB): bzImage, initrd.img, cmdline.txt
#   Partición 2 (ext4, ~1GB):    rootfs Alpine con QEMU
#   Partición 3 (exFAT, resto):  macos/ con OpenCore.img, OVMF, macOS.img
#
# Uso:
#   ./tools/create_usb.sh /dev/diskN          # Particiona + copia todo
#   ./tools/create_usb.sh /Volumes/PS5BOOT    # Solo copia a FAT32 existente

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD="$PROJECT_DIR/build"

TARGET="${1:-}"

if [ -z "$TARGET" ]; then
    echo "Uso: $0 <dispositivo-o-volumen>"
    echo ""
    echo "  $0 /dev/disk4          Particiona y copia todo (BORRA EL USB)"
    echo "  $0 /Volumes/PS5BOOT   Solo copia boot files a FAT32 existente"
    echo ""
    echo "Artefactos necesarios en build/:"
    for f in bzImage initrd.img OpenCore.img OVMF_CODE.fd OVMF_VARS.fd rootfs.img macOS.img; do
        if [ -f "$BUILD/$f" ]; then
            echo "  [ok] $f ($(du -h "$BUILD/$f" | cut -f1))"
        else
            echo "  [!!] $f — falta"
        fi
    done
    exit 1
fi

echo "╔══════════════════════════════════════════════════╗"
echo "║  PS5 Hackintosh — Preparación del USB           ║"
echo "╚══════════════════════════════════════════════════╝"
echo ""

# ── Modo 1: Solo copiar a volumen montado ─────────────
if [ -d "$TARGET" ]; then
    echo "Copiando boot files a: $TARGET"
    echo ""

    [ -f "$BUILD/bzImage" ]    && cp "$BUILD/bzImage" "$TARGET/" && echo "  [ok] bzImage"
    [ -f "$BUILD/initrd.img" ] && cp "$BUILD/initrd.img" "$TARGET/" && echo "  [ok] initrd.img"
    cp "$PROJECT_DIR/usb/cmdline.txt" "$TARGET/" && echo "  [ok] cmdline.txt"
    [ -f "$PROJECT_DIR/usb/vram.txt" ] && cp "$PROJECT_DIR/usb/vram.txt" "$TARGET/"

    echo ""
    echo "Partición FAT32 lista. Para el resto:"
    echo "  Part 2 (ext4):  sudo dd if=build/rootfs.img of=/dev/diskNs2 bs=4M"
    echo "  Part 3 (exFAT): copia macos/ con OpenCore.img, OVMF, macOS.img"
    exit 0
fi

# ── Modo 2: Particionar disco completo ────────────────
DISK="$TARGET"

if [[ ! "$DISK" =~ ^/dev/disk[0-9]+$ ]]; then
    echo "Error: '$DISK' no parece un dispositivo válido"
    echo "  Formato esperado: /dev/diskN"
    exit 1
fi

# Verificar artefactos
MISSING=""
[ ! -f "$BUILD/bzImage" ]      && MISSING="$MISSING bzImage"
[ ! -f "$BUILD/initrd.img" ]   && MISSING="$MISSING initrd.img"
[ ! -f "$BUILD/rootfs.img" ]   && MISSING="$MISSING rootfs.img"
[ ! -f "$BUILD/OpenCore.img" ] && MISSING="$MISSING OpenCore.img"
[ ! -f "$BUILD/OVMF_CODE.fd" ] && MISSING="$MISSING OVMF_CODE.fd"
[ ! -f "$BUILD/macOS.img" ]    && MISSING="$MISSING macOS.img"

if [ -n "$MISSING" ]; then
    echo "Faltan artefactos:$MISSING"
    echo "Ejecuta primero los scripts de build correspondientes."
    exit 1
fi

DISK_SIZE=$(diskutil info "$DISK" | grep "Disk Size" | awk '{print $3}')
echo "  Disco: $DISK ($DISK_SIZE GB)"
echo ""
echo "  ATENCIÓN: Esto BORRARÁ TODO el contenido del USB."
echo ""
read -p "  ¿Continuar? (s/n): " CONFIRM
[ "$CONFIRM" != "s" ] && { echo "Cancelado."; exit 0; }

echo ""
echo "[1/6] Desmontando disco..."
diskutil unmountDisk "$DISK" 2>/dev/null || true

echo "[2/6] Creando tabla de particiones GPT..."
# Part 1: FAT32 500MB para boot
# Part 2: 1.2GB para rootfs ext4
# Part 3: resto para macos (exFAT)
diskutil partitionDisk "$DISK" GPT \
    FAT32 PS5BOOT 500MB \
    "Free Space" ROOTFS 1200MB \
    ExFAT PS5MACOS R

echo "[3/6] Copiando boot files a PS5BOOT..."
BOOT_VOL="/Volumes/PS5BOOT"
if [ -d "$BOOT_VOL" ]; then
    cp "$BUILD/bzImage" "$BOOT_VOL/"
    cp "$BUILD/initrd.img" "$BOOT_VOL/"
    cp "$PROJECT_DIR/usb/cmdline.txt" "$BOOT_VOL/"
    [ -f "$PROJECT_DIR/usb/vram.txt" ] && cp "$PROJECT_DIR/usb/vram.txt" "$BOOT_VOL/"
    echo "  bzImage + initrd.img + cmdline.txt copiados"
else
    echo "  Error: $BOOT_VOL no montado"
fi

echo "[4/6] Escribiendo rootfs ext4..."
# La segunda partición es "Free Space" — la formateamos como ext4 via dd
PART2="${DISK}s2"
if [ -b "$PART2" ]; then
    sudo dd if="$BUILD/rootfs.img" of="$PART2" bs=4M status=progress 2>&1
    echo "  rootfs escrito en $PART2"
else
    echo "  Advertencia: $PART2 no encontrado. Escribe manualmente:"
    echo "    sudo dd if=build/rootfs.img of=${DISK}s2 bs=4M"
fi

echo "[5/6] Copiando archivos macOS a PS5MACOS..."
MACOS_VOL="/Volumes/PS5MACOS"
if [ -d "$MACOS_VOL" ]; then
    mkdir -p "$MACOS_VOL/macos"
    cp "$BUILD/OpenCore.img" "$MACOS_VOL/macos/"
    cp "$BUILD/OVMF_CODE.fd" "$MACOS_VOL/macos/"
    cp "$BUILD/OVMF_VARS.fd" "$MACOS_VOL/macos/"
    echo "  Copiando macOS.img (esto tarda un rato)..."
    cp "$BUILD/macOS.img" "$MACOS_VOL/macos/"
    echo "  OpenCore + OVMF + macOS.img copiados"
else
    echo "  Error: $MACOS_VOL no montado"
fi

echo "[6/6] Expulsando disco..."
sync
diskutil unmountDisk "$DISK" 2>/dev/null || true

echo ""
echo "═══════════════════════════════════════════════════"
echo "USB listo!"
echo ""
echo "  Partición 1 (FAT32 PS5BOOT): bzImage + initrd + cmdline"
echo "  Partición 2 (ext4):          rootfs Alpine + QEMU"
echo "  Partición 3 (exFAT PS5MACOS): OpenCore + OVMF + macOS"
echo ""
echo "Siguiente paso:"
echo "  1. Conecta el USB a la PS5"
echo "  2. Ejecuta: ./tools/launch_hackintosh.sh"
echo "═══════════════════════════════════════════════════"
