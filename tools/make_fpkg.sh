#!/bin/bash
#
# PS5 Hackintosh — Crear fPKG para instalar en PS5
#
# Crea un fake PKG que aparece como "juego" en el menú de PS5.
# Al lanzarlo ejecuta el loader que arranca Linux → macOS.
#
# Usa LibProsperoPkg (.NET) para generar el paquete nativo en macOS.
#
# Requisitos:
#   - ps5-payload-sdk (para el ELF)
#   - .NET 10 SDK (brew install dotnet)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD="$PROJECT_DIR/build"
FPKG_DIR="$BUILD/fpkg"
ELF="$BUILD/bin/ps5-linux-loader.elf"
CONTENT_ID="IV0000-HACK00001_00-HACKINTOSHPS5000"

echo "╔══════════════════════════════════════════════╗"
echo "║  PS5 Hackintosh — Crear fPKG                ║"
echo "╚══════════════════════════════════════════════╝"
echo ""

# ── Verificar ELF ─────────────────────────────────────
if [ ! -f "$ELF" ]; then
    echo "Error: $ELF no encontrado. Ejecuta: make loader"
    exit 1
fi

# ── Verificar .NET SDK ────────────────────────────────
if ! command -v dotnet >/dev/null 2>&1; then
    echo "Error: .NET SDK no instalado."
    echo "  Instalar: brew install dotnet"
    exit 1
fi

# ── Crear estructura fPKG ─────────────────────────────
echo "[1/3] Creando estructura de paquete..."
rm -rf "$FPKG_DIR"
mkdir -p "$FPKG_DIR/sce_sys"

cp "$ELF" "$FPKG_DIR/eboot.bin"
cp "$PROJECT_DIR/sce_sys/param.json" "$FPKG_DIR/sce_sys/"
cp "$PROJECT_DIR/sce_sys/icon0.png" "$FPKG_DIR/sce_sys/"

echo "  eboot.bin: $(du -h "$FPKG_DIR/eboot.bin" | cut -f1)"
echo "  param.json + icon0.png copiados"

# ── Compilar CLI si no existe ─────────────────────────
CLI_PROJECT="$BUILD/fpkg-builder/cli/cli.csproj"
echo "[2/3] Preparando LibProsperoPkg CLI..."

if [ ! -f "$CLI_PROJECT" ]; then
    echo "  Error: CLI no encontrado en $CLI_PROJECT"
    echo "  Asegúrate de que build/fpkg-builder/ existe"
    exit 1
fi

# ── Crear fPKG ────────────────────────────────────────
echo "[3/3] Creando fPKG con LibProsperoPkg..."

FPKG_OUT_DIR="$BUILD"
export DOTNET_ROOT="${DOTNET_ROOT:-/opt/homebrew/opt/dotnet/libexec}"

dotnet run --project "$CLI_PROJECT" -c Release -- \
    "$FPKG_DIR" "$FPKG_OUT_DIR" "$CONTENT_ID" "Hackintosh" 2>&1 | \
    grep -v "^/opt/homebrew.*warning MSB"

FPKG_FILE=$(find "$FPKG_OUT_DIR" -maxdepth 1 -name "${CONTENT_ID}*.pkg" -print -quit)

if [ -n "$FPKG_FILE" ]; then
    FINAL_NAME="$FPKG_OUT_DIR/Hackintosh-PS5.pkg"
    mv "$FPKG_FILE" "$FINAL_NAME"
    echo ""
    echo "═══════════════════════════════════════════════"
    echo "fPKG creado: $FINAL_NAME"
    echo "  Tamaño: $(du -h "$FINAL_NAME" | cut -f1)"
    echo ""
    echo "Para instalar en PS5:"
    echo "  1. Copia el .pkg a un USB (FAT32/exFAT)"
    echo "  2. Conéctalo a la PS5"
    echo "  3. Instala desde el homebrew store o pkg installer"
    echo "═══════════════════════════════════════════════"
else
    echo "Error: no se generó el archivo .pkg"
    exit 1
fi
