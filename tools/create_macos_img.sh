#!/bin/bash
#
# PS5 Hackintosh — Descargar macOS y crear imagen de disco
#
# Descarga el installer de macOS desde los servidores de Apple
# usando macrecovery (de OpenCorePkg), crea una imagen qcow2 de 64GB,
# y prepara todo para instalar macOS via QEMU en el Mac.
#
# Uso: ./tools/create_macos_img.sh [version]
#   Versiones: sonoma, ventura, monterey, sequoia
#   Default: sonoma

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD="$PROJECT_DIR/build"
MACOS_DIR="$BUILD/macos-installer"

VERSION="${1:-sonoma}"

# Catalogs de Apple para cada versión
declare -A BOARD_IDS=(
    [sequoia]="Mac-CFF7D910A743CAAF"
    [sonoma]="Mac-827FAC58A8FDFA22"
    [ventura]="Mac-4B682C642B45593E"
    [monterey]="Mac-FFE5EF870D7BA81A"
)

declare -A MLB_SERIALS=(
    [sequoia]="00000000000000000"
    [sonoma]="00000000000000000"
    [ventura]="00000000000000000"
    [monterey]="00000000000000000"
)

BOARD="${BOARD_IDS[$VERSION]:-}"
if [ -z "$BOARD" ]; then
    echo "Error: versión '$VERSION' no soportada."
    echo "  Opciones: sonoma, ventura, monterey, sequoia"
    exit 1
fi

echo "╔══════════════════════════════════════════════╗"
echo "║  PS5 Hackintosh — Crear imagen macOS        ║"
echo "╚══════════════════════════════════════════════╝"
echo ""
echo "  Versión: macOS $VERSION"
echo ""

mkdir -p "$MACOS_DIR"

# ── Descargar macrecovery si no existe ────────────────
MACRECOVERY="$BUILD/macrecovery/macrecovery.py"
if [ ! -f "$MACRECOVERY" ]; then
    echo "[1/4] Descargando macrecovery..."
    mkdir -p "$BUILD/macrecovery"
    curl -sL "https://raw.githubusercontent.com/acidanthera/OpenCorePkg/master/Utilities/macrecovery/macrecovery.py" \
        -o "$MACRECOVERY"
    chmod +x "$MACRECOVERY"
    echo "  macrecovery descargado"
else
    echo "[1/4] macrecovery ya descargado"
fi

# ── Descargar recovery de macOS ───────────────────────
if [ ! -f "$MACOS_DIR/com.apple.recovery.boot/BaseSystem.dmg" ] && [ ! -f "$MACOS_DIR/BaseSystem.dmg" ]; then
    echo "[2/4] Descargando macOS $VERSION recovery desde Apple..."
    echo "  (esto puede tardar unos minutos)"
    cd "$MACOS_DIR"
    python3 "$MACRECOVERY" \
        -b "$BOARD" \
        -m "${MLB_SERIALS[$VERSION]}" \
        download
    cd "$PROJECT_DIR"
    echo "  Recovery descargado"
else
    echo "[2/4] Recovery ya descargado"
fi

# ── Crear imagen de disco para macOS ──────────────────
MACOS_IMG="$BUILD/macOS.img"
if [ ! -f "$MACOS_IMG" ]; then
    echo "[3/4] Creando imagen de disco (64GB, qcow2)..."
    qemu-img create -f qcow2 "$MACOS_IMG" 64G
    echo "  macOS.img creado (64GB sparse)"
else
    echo "[3/4] macOS.img ya existe"
fi

# ── Crear imagen del installer ────────────────────────
RECOVERY_IMG="$BUILD/macOS-recovery.img"
if [ ! -f "$RECOVERY_IMG" ]; then
    echo "[4/4] Creando imagen del recovery..."
    # Buscar el DMG descargado
    DMG_FILE=""
    if [ -f "$MACOS_DIR/com.apple.recovery.boot/BaseSystem.dmg" ]; then
        DMG_FILE="$MACOS_DIR/com.apple.recovery.boot/BaseSystem.dmg"
    elif [ -f "$MACOS_DIR/BaseSystem.dmg" ]; then
        DMG_FILE="$MACOS_DIR/BaseSystem.dmg"
    fi

    if [ -z "$DMG_FILE" ]; then
        echo "  Error: no se encontró BaseSystem.dmg ni RecoveryImage.dmg"
        exit 1
    fi

    # Convertir DMG comprimido a imagen raw (UDRW) que QEMU pueda leer
    if command -v hdiutil &>/dev/null; then
        hdiutil convert "$DMG_FILE" -format UDRW -o "$RECOVERY_IMG" 2>&1 | tail -3
    else
        qemu-img convert -f dmg -O raw "$DMG_FILE" "$RECOVERY_IMG"
    fi
    echo "  Recovery image: $RECOVERY_IMG ($(du -h "$RECOVERY_IMG" | cut -f1))"
else
    echo "[4/4] Recovery image ya existe"
fi

echo ""
echo "═══════════════════════════════════════════════"
echo "Artefactos macOS:"
echo "  macOS.img (disco):    $MACOS_IMG ($(du -h "$MACOS_IMG" | cut -f1))"
echo "  Recovery:             $RECOVERY_IMG ($(du -h "$RECOVERY_IMG" | cut -f1))"
echo ""
echo "Para instalar macOS en la imagen, ejecuta:"
echo "  ./tools/install_macos_qemu.sh"
echo ""
echo "Esto lanza QEMU en tu Mac con OpenCore + recovery."
echo "Sigue la instalación normal de macOS."
echo "═══════════════════════════════════════════════"
