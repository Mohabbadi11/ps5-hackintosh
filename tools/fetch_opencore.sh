#!/bin/bash
#
# PS5 Hackintosh — Descargar OpenCore + kexts + drivers
#
# Descarga todos los componentes necesarios de OpenCore para el Hackintosh.
# Los kexts y drivers se colocan en el directorio de build.
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD="$PROJECT_DIR/build"
OC_DIR="$BUILD/opencore"

mkdir -p "$OC_DIR/EFI/OC/"{ACPI,Drivers,Kexts,Tools}
mkdir -p "$OC_DIR/EFI/BOOT"
mkdir -p "$BUILD/downloads"

DL="$BUILD/downloads"

echo "╔══════════════════════════════════════════════════╗"
echo "║  PS5 Hackintosh — Descargar OpenCore + Kexts    ║"
echo "╚══════════════════════════════════════════════════╝"
echo ""

# ── Función para descargar release de GitHub ───────────
gh_latest() {
    local repo="$1"
    local pattern="$2"
    local out="$3"

    if [ -f "$out" ]; then
        echo "  [✓] $(basename "$out") ya descargado"
        return 0
    fi

    echo "  [↓] Descargando $(basename "$out") de $repo..."
    local url
    url=$(curl -sL "https://api.github.com/repos/$repo/releases/latest" \
        | grep -o "\"browser_download_url\": *\"[^\"]*${pattern}[^\"]*\"" \
        | head -1 \
        | sed 's/"browser_download_url": *"//;s/"//')

    if [ -z "$url" ]; then
        echo "  [!] No se pudo encontrar $pattern en $repo"
        return 1
    fi

    curl -sL -o "$out" "$url"
    echo "  [✓] $(basename "$out") ($(du -h "$out" | cut -f1))"
}

# ── OpenCore ───────────────────────────────────────────
echo "OpenCore bootloader:"
gh_latest "acidanthera/OpenCorePkg" "RELEASE.zip" "$DL/OpenCore-RELEASE.zip"

if [ -f "$DL/OpenCore-RELEASE.zip" ]; then
    OC_TMP=$(mktemp -d)
    unzip -qo "$DL/OpenCore-RELEASE.zip" -d "$OC_TMP"

    # Bootloader
    cp "$OC_TMP/X64/EFI/BOOT/BOOTx64.efi" "$OC_DIR/EFI/BOOT/" 2>/dev/null || true
    cp "$OC_TMP/X64/EFI/OC/OpenCore.efi" "$OC_DIR/EFI/OC/" 2>/dev/null || true

    # Drivers
    for drv in OpenRuntime.efi OpenHfsPlus.efi ResetNvramEntry.efi OpenUsbKbDxe.efi; do
        find "$OC_TMP" -name "$drv" -exec cp {} "$OC_DIR/EFI/OC/Drivers/" \; 2>/dev/null
    done

    rm -rf "$OC_TMP"
    echo "  [✓] OpenCore extraído"
fi

# Build DEBUG (OC_DEBUG=1: clean_run.sh and ktty_run.sh use it, it logs the memory map and the ExitBootServices steps)
gh_latest "acidanthera/OpenCorePkg" "DEBUG.zip" "$DL/OpenCore-DEBUG.zip"
if [ -f "$DL/OpenCore-DEBUG.zip" ]; then
    rm -rf "$BUILD/opencore-debug" && mkdir -p "$BUILD/opencore-debug"
    unzip -qo "$DL/OpenCore-DEBUG.zip" -d "$BUILD/opencore-debug"
    echo "  [✓] OpenCore DEBUG extraído"
fi

# ── Kexts ──────────────────────────────────────────────
echo ""
echo "Kexts:"

declare -A KEXTS=(
    ["acidanthera/Lilu"]="RELEASE.zip"
    ["acidanthera/VirtualSMC"]="RELEASE.zip"
    ["acidanthera/WhateverGreen"]="RELEASE.zip"
    ["acidanthera/AppleALC"]="RELEASE.zip"
    ["acidanthera/NVMeFix"]="RELEASE.zip"
    ["acidanthera/RestrictEvents"]="RELEASE.zip"
    ["trulyspinach/SMCAMDProcessor"]="AMDRyzenCPUPowerManagement.kext.zip"
)

# Descargar también el kext principal de SMCAMDProcessor
gh_latest "trulyspinach/SMCAMDProcessor" "SMCAMDProcessor.kext.zip" "$DL/SMCAMDProcessor-kext.zip"
if [ -f "$DL/SMCAMDProcessor-kext.zip" ]; then
    KEXT_TMP=$(mktemp -d)
    unzip -qo "$DL/SMCAMDProcessor-kext.zip" -d "$KEXT_TMP"
    find "$KEXT_TMP" -name "*.kext" -maxdepth 3 -exec cp -R {} "$OC_DIR/EFI/OC/Kexts/" \; 2>/dev/null
    rm -rf "$KEXT_TMP"
fi

for repo in "${!KEXTS[@]}"; do
    name=$(basename "$repo")
    pattern="${KEXTS[$repo]}"
    dl_file="$DL/${name}.zip"

    gh_latest "$repo" "$pattern" "$dl_file"

    if [ -f "$dl_file" ]; then
        KEXT_TMP=$(mktemp -d)
        unzip -qo "$dl_file" -d "$KEXT_TMP"

        # Copiar .kext encontrados
        find "$KEXT_TMP" -name "*.kext" -maxdepth 3 -exec cp -R {} "$OC_DIR/EFI/OC/Kexts/" \; 2>/dev/null
        rm -rf "$KEXT_TMP"
    fi
done

# ── MetalCyan (GPU acceleration for Oberon / Cyan Skillfish) ──
gh_latest "amethyst8118/MetalCyan" "RELEASE.zip" "$DL/MetalCyan.zip"
if [ -f "$DL/MetalCyan.zip" ]; then
    MC_TMP=$(mktemp -d)
    unzip -qo "$DL/MetalCyan.zip" -d "$MC_TMP"
    mkdir -p "$BUILD/kexts"
    find "$MC_TMP" -name "MetalCyan.kext" -maxdepth 2 -exec cp -R {} "$OC_DIR/EFI/OC/Kexts/" \; 2>/dev/null
    find "$MC_TMP" -name "MetalCyan.kext" -maxdepth 2 -exec cp -R {} "$BUILD/kexts/" \; 2>/dev/null
    rm -rf "$MC_TMP"
    echo "  [✓] MetalCyan.kext extraído"
fi

# AMDRyzenCPUPowerManagement viene dentro de SMCAMDProcessor
echo ""

# ── Copiar config.plist ────────────────────────────────
cp "$PROJECT_DIR/opencore/config.plist" "$OC_DIR/EFI/OC/config.plist"

# ── ACPI ───────────────────────────────────────────────
if ls "$BUILD/acpi/"*.aml 1>/dev/null 2>&1; then
    cp "$BUILD/acpi/"*.aml "$OC_DIR/EFI/OC/ACPI/"
fi

# ── Resumen ────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════════════"
echo "Contenido de OpenCore:"
echo ""
echo "EFI/BOOT/:"
ls "$OC_DIR/EFI/BOOT/" 2>/dev/null | sed 's/^/  /'
echo ""
echo "EFI/OC/Drivers/:"
ls "$OC_DIR/EFI/OC/Drivers/" 2>/dev/null | sed 's/^/  /'
echo ""
echo "EFI/OC/Kexts/:"
ls "$OC_DIR/EFI/OC/Kexts/" 2>/dev/null | sed 's/^/  /'
echo ""
echo "Todo listo en: $OC_DIR/"
echo ""
echo "Para crear la imagen OpenCore:"
echo "  ./tools/build_opencore_img.sh $OC_DIR OpenCore.img"
echo "═══════════════════════════════════════════════════"
