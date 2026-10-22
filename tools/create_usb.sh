#!/bin/bash
#
# PS5 Hackintosh — Preparar USB de arranque
#
# Crea la estructura completa del USB que el ps5-linux-loader leerá.
# El loader busca bzImage e initrd.img en /mnt/usb[0-3]/ o /PS5/Linux/
#
# Uso: ./tools/create_usb.sh /Volumes/PS5HACK
#

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
    echo "El USB debe estar formateado como FAT32 o exFAT."
    exit 1
fi

[ ! -d "$USB" ] && { echo "Error: $USB no es un directorio"; exit 1; }

echo "╔══════════════════════════════════════════════════╗"
echo "║  PS5 Hackintosh — Preparación del USB           ║"
echo "╚══════════════════════════════════════════════════╝"
echo ""
echo "Destino: $USB"
echo ""

# ── Estructura del USB ─────────────────────────────────
# El loader busca en /mnt/usb[N]/ y /mnt/usb[N]/PS5/Linux/
# Ponemos todo en la raíz para máxima compatibilidad.
mkdir -p "$USB/macos/EFI/OC/ACPI"
mkdir -p "$USB/macos/EFI/OC/Drivers"
mkdir -p "$USB/macos/EFI/OC/Kexts"
mkdir -p "$USB/macos/EFI/BOOT"

# ── bzImage ────────────────────────────────────────────
if [ -f "$BUILD/bzImage" ]; then
    cp "$BUILD/bzImage" "$USB/bzImage"
    echo "  ✓ bzImage copiado ($(du -h "$BUILD/bzImage" | cut -f1))"
else
    echo "  ✗ bzImage NO ENCONTRADO"
    echo "    Necesitas un kernel Linux con KVM habilitado para PS5."
    echo "    Ver: kernel/README.md"
fi

# ── initrd.img ─────────────────────────────────────────
if [ -f "$BUILD/initrd.img" ]; then
    cp "$BUILD/initrd.img" "$USB/initrd.img"
    echo "  ✓ initrd.img copiado ($(du -h "$BUILD/initrd.img" | cut -f1))"
else
    echo "  ✗ initrd.img NO ENCONTRADO — ejecuta: make initramfs"
fi

# ── cmdline.txt ────────────────────────────────────────
cp "$PROJECT_DIR/usb/cmdline.txt" "$USB/cmdline.txt"
echo "  ✓ cmdline.txt (con flags KVM/VFIO)"

# ── vram.txt ───────────────────────────────────────────
cp "$PROJECT_DIR/usb/vram.txt" "$USB/vram.txt" 2>/dev/null && \
    echo "  ✓ vram.txt" || true

# ── OpenCore config ────────────────────────────────────
cp "$PROJECT_DIR/opencore/config.plist" "$USB/macos/EFI/OC/config.plist"
echo "  ✓ config.plist (OpenCore para PS5)"

# ── ACPI compiladas ────────────────────────────────────
if ls "$BUILD/acpi/"*.aml 1>/dev/null 2>&1; then
    cp "$BUILD/acpi/"*.aml "$USB/macos/EFI/OC/ACPI/"
    echo "  ✓ Tablas ACPI compiladas"
else
    echo "  ✗ Tablas ACPI no compiladas — ejecuta: make acpi"
fi

# ── OVMF ───────────────────────────────────────────────
if [ -f "$BUILD/bin/OVMF_CODE.fd" ]; then
    cp "$BUILD/bin/OVMF_CODE.fd" "$USB/macos/OVMF_CODE.fd"
    echo "  ✓ OVMF_CODE.fd"
else
    echo "  ✗ OVMF no encontrado — ejecuta: ./tools/fetch_binaries.sh"
fi

echo ""
echo "═══════════════════════════════════════════════════"
echo ""
echo "Todavía necesitas añadir manualmente:"
echo ""
echo "  1. macOS disk image → $USB/macos/macOS.img"
echo "     Crea con: qemu-img create -f raw macOS.img 64G"
echo "     Instala macOS usando un Mac o VM primero."
echo ""
echo "  2. OpenCore.img → $USB/macos/OpenCore.img"
echo "     Crea con: ./tools/build_opencore_img.sh <dir-EFI> OpenCore.img"
echo ""
echo "  3. Kexts en EFI/OC/Kexts/:"
echo "     Lilu, VirtualSMC, WhateverGreen, AppleALC, NVMeFix,"
echo "     AMDRyzenCPUPowerManagement, SMCAMDProcessor, RestrictEvents"
echo ""
echo "  4. Drivers en EFI/OC/Drivers/:"
echo "     OpenHfsPlus.efi, OpenRuntime.efi, OpenUsbKbDxe.efi"
echo ""
echo "  5. Bootloader en EFI/BOOT/:"
echo "     BOOTx64.efi, OpenCore.efi"
echo ""
echo "  6. Seriales SMBIOS (GenSMBIOS → config.plist)"
echo ""
echo "═══════════════════════════════════════════════════"
