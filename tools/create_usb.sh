#!/bin/bash
#
# PS5 Hackintosh — Prepare USB boot drive
#
# Creates the USB directory structure needed for the PS5 Hackintosh loader.
# The user must provide their own macOS disk image and OVMF firmware.
#
# Usage: ./tools/create_usb.sh /Volumes/PS5_HACK
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

USB_ROOT="${1:-}"

if [ -z "$USB_ROOT" ]; then
    echo "Usage: $0 <usb-mount-point>"
    echo ""
    echo "Example: $0 /Volumes/PS5_HACK"
    echo ""
    echo "The USB drive should be formatted as FAT32 or exFAT."
    exit 1
fi

if [ ! -d "$USB_ROOT" ]; then
    echo "Error: $USB_ROOT is not a directory"
    exit 1
fi

echo "╔══════════════════════════════════════════════╗"
echo "║  PS5 Hackintosh — USB Drive Preparation     ║"
echo "╚══════════════════════════════════════════════╝"
echo ""
echo "Target: $USB_ROOT"
echo ""

# ── Create directory structure ─────────────────────
echo "Creating directory structure..."
mkdir -p "$USB_ROOT/macos/EFI/OC/ACPI"
mkdir -p "$USB_ROOT/macos/EFI/OC/Drivers"
mkdir -p "$USB_ROOT/macos/EFI/OC/Kexts"
mkdir -p "$USB_ROOT/macos/EFI/BOOT"

# ── Copy boot files ───────────────────────────────
echo "Copying boot files..."

# bzImage and initramfs (must be built separately)
if [ -f "$PROJECT_DIR/build/bzImage" ]; then
    cp "$PROJECT_DIR/build/bzImage" "$USB_ROOT/bzImage"
    echo "  ✓ bzImage"
else
    echo "  ✗ bzImage (not found — build the kernel first)"
fi

if [ -f "$PROJECT_DIR/build/initramfs.cpio.gz" ]; then
    cp "$PROJECT_DIR/build/initramfs.cpio.gz" "$USB_ROOT/initramfs.cpio.gz"
    echo "  ✓ initramfs.cpio.gz"
else
    echo "  ✗ initramfs.cpio.gz (run: make initramfs)"
fi

# ── Copy OpenCore config ─────────────────────────
echo "Copying OpenCore configuration..."
cp "$PROJECT_DIR/opencore/config.plist" "$USB_ROOT/macos/EFI/OC/config.plist"
echo "  ✓ config.plist"

# Copy ACPI tables (compiled .aml files)
for aml in "$PROJECT_DIR/opencore/ACPI/"*.aml; do
    if [ -f "$aml" ]; then
        cp "$aml" "$USB_ROOT/macos/EFI/OC/ACPI/"
        echo "  ✓ $(basename "$aml")"
    fi
done

# ── Write cmdline ─────────────────────────────────
cat > "$USB_ROOT/cmdline.txt" << 'EOF'
console=tty0 earlyprintk=ttyS0,115200 root=/dev/ram0 rdinit=/init amdgpu.dpm=0 amdgpu.runpm=0 amdgpu.force_1080p=1 video=DP-1:1920x1080@60 iommu=pt amd_iommu=on kvm_amd.nested=1 default_hugepagesz=2M hugepages=4096 ps5_hackintosh=1
EOF
echo "  ✓ cmdline.txt"

# ── Report status ─────────────────────────────────
echo ""
echo "═══════════════════════════════════════════════"
echo ""
echo "USB structure created. You still need to provide:"
echo ""
echo "  1. macOS disk image:"
echo "     $USB_ROOT/macos/macOS.img"
echo "     (Create with: qemu-img create -f raw macOS.img 64G)"
echo "     (Install macOS into it using a Mac or VM first)"
echo ""
echo "  2. OVMF UEFI firmware:"
echo "     $USB_ROOT/macos/OVMF_CODE.fd"
echo "     (Download from: https://github.com/kholia/OSX-KVM)"
echo ""
echo "  3. OpenCore bootloader image:"
echo "     $USB_ROOT/macos/OpenCore.img"
echo "     (Create with the OpenCore offline installer)"
echo ""
echo "  4. Required kexts in EFI/OC/Kexts/:"
echo "     - Lilu.kext"
echo "     - VirtualSMC.kext"
echo "     - WhateverGreen.kext"
echo "     - AppleALC.kext"
echo "     - NVMeFix.kext"
echo "     - AMDRyzenCPUPowerManagement.kext"
echo "     - SMCAMDProcessor.kext"
echo "     - RestrictEvents.kext"
echo ""
echo "  5. OpenCore drivers in EFI/OC/Drivers/:"
echo "     - OpenHfsPlus.efi"
echo "     - OpenRuntime.efi"
echo "     - OpenUsbKbDxe.efi"
echo "     - ResetNvramEntry.efi"
echo ""
echo "  6. OpenCore bootloader:"
echo "     $USB_ROOT/macos/EFI/BOOT/BOOTx64.efi"
echo "     $USB_ROOT/macos/EFI/OC/OpenCore.efi"
echo ""
echo "  7. Generate SMBIOS serials with GenSMBIOS and"
echo "     update config.plist (MLB, ROM, Serial, UUID)"
echo ""
echo "  8. Compile ACPI tables:"
echo "     cd $PROJECT_DIR/opencore/ACPI"
echo "     iasl -tc DSDT-PS5.dsl"
echo "     iasl -tc SSDT-PS5-CPU.dsl"
echo "     iasl -tc SSDT-PS5-GPU.dsl"
echo "     iasl -tc SSDT-PS5-USB.dsl"
echo "     cp *.aml $USB_ROOT/macos/EFI/OC/ACPI/"
echo ""
echo "═══════════════════════════════════════════════"
