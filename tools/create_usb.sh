#!/bin/bash
#
# PS5 Hackintosh — Preparar USB de arranque
#
# Estructura del USB (3 particiones):
#   Partición 1 (FAT32, ~500MB): bzImage, initrd.img, cmdline.txt
#   Partición 2 (ext4, ~1GB):    rootfs Alpine con QEMU
#   Partición 3 (exFAT, resto):  macos/ con OpenCore.img, OVMF, macOS.img
#
# Este script copia los archivos a una FAT32 ya montada.
# La partición ext4 se crea con: tools/create_rootfs.sh
#
# Uso: ./tools/create_usb.sh /Volumes/PS5HACK

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD="$PROJECT_DIR/build"

USB="${1:-}"

if [ -z "$USB" ]; then
    echo "Uso: $0 <punto-de-montaje-USB>"
    echo ""
    echo "Ejemplo: $0 /Volumes/PS5HACK"
    echo ""
    echo "Estructura del USB (3 particiones):"
    echo "  Part 1 (FAT32): bzImage + initrd.img + cmdline.txt"
    echo "  Part 2 (ext4):  rootfs con QEMU (tools/create_rootfs.sh)"
    echo "  Part 3 (exFAT): macos/ con OpenCore.img + OVMF + macOS.img"
    exit 1
fi

[ ! -d "$USB" ] && { echo "Error: $USB no es un directorio"; exit 1; }

echo "╔══════════════════════════════════════════════════╗"
echo "║  PS5 Hackintosh — Preparación del USB           ║"
echo "╚══════════════════════════════════════════════════╝"
echo ""
echo "Destino: $USB"
echo ""

# ── bzImage ────────────────────────────────────────────
if [ -f "$BUILD/bzImage" ]; then
    cp "$BUILD/bzImage" "$USB/bzImage"
    echo "  [ok] bzImage ($(du -h "$BUILD/bzImage" | cut -f1))"
else
    echo "  [!!] bzImage NO ENCONTRADO"
    echo "       Necesitas un kernel Linux con KVM para PS5."
    echo "       Ver: docs/kernel.md o usar ps5-linux-loader upstream"
fi

# ── initrd.img ────────────────────────────────────────
if [ -f "$BUILD/initrd.img" ]; then
    cp "$BUILD/initrd.img" "$USB/initrd.img"
    echo "  [ok] initrd.img ($(du -h "$BUILD/initrd.img" | cut -f1))"
else
    echo "  [!!] initrd.img no encontrado — ejecuta: make initramfs"
fi

# ── cmdline.txt ───────────────────────────────────────
cp "$PROJECT_DIR/usb/cmdline.txt" "$USB/cmdline.txt"
echo "  [ok] cmdline.txt"

# ── vram.txt ──────────────────────────────────────────
if [ -f "$PROJECT_DIR/usb/vram.txt" ]; then
    cp "$PROJECT_DIR/usb/vram.txt" "$USB/vram.txt"
    echo "  [ok] vram.txt"
fi

echo ""
echo "═══════════════════════════════════════════════════"
echo ""
echo "Partición 1 (FAT32) lista."
echo ""
echo "Todavía necesitas:"
echo ""
echo "  Partición 2 (ext4) — rootfs con QEMU:"
echo "    Ejecuta: ./tools/create_rootfs.sh"
echo "    Luego:   sudo dd if=build/rootfs.img of=/dev/sdX2 bs=4M"
echo ""
echo "  Partición 3 (exFAT) — datos de macOS:"
echo "    Crea directorio macos/ con:"
echo "    - OpenCore.img  (build/OpenCore.img ya creado: $(du -h "$BUILD/OpenCore.img" 2>/dev/null | cut -f1 || echo '?'))"
echo "    - OVMF_CODE.fd  (build/bin/OVMF_CODE.fd)"
echo "    - macOS.img     (imagen de disco macOS — instalar aparte)"
echo ""
echo "  Kernel bzImage:"
echo "    El kernel Linux con KVM viene del ps5-linux-loader o"
echo "    se compila con kernel/config.fragment sobre ps5-linux-patches."
echo ""
echo "═══════════════════════════════════════════════════"
