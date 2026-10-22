#!/bin/bash
#
# PS5 Hackintosh — Crear fPKG para instalar en PS5
#
# Crea un fake PKG que aparece como "juego" en el menú de PS5.
# Al lanzarlo ejecuta el loader que arranca Linux → macOS.
#
# Requisitos:
#   - ps5-payload-sdk (para el ELF)
#   - PkgTool.exe (Wine) o pkg_tool de OpenOrbis
#
# Si no tienes PkgTool, este script prepara la estructura para
# que la empaquetes manualmente.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD="$PROJECT_DIR/build"
FPKG_DIR="$BUILD/fpkg"
ELF="$BUILD/bin/ps5-linux-loader.elf"

echo "╔══════════════════════════════════════════════╗"
echo "║  PS5 Hackintosh — Preparar fPKG             ║"
echo "╚══════════════════════════════════════════════╝"
echo ""

# ── Verificar ELF ─────────────────────────────────────
if [ ! -f "$ELF" ]; then
    echo "Error: $ELF no encontrado. Ejecuta: make loader"
    exit 1
fi

# ── Crear estructura fPKG ─────────────────────────────
echo "[1/3] Creando estructura de paquete..."
rm -rf "$FPKG_DIR"
mkdir -p "$FPKG_DIR/sce_sys"

# eboot.bin es el ELF renombrado
cp "$ELF" "$FPKG_DIR/eboot.bin"

# Metadatos
cp "$PROJECT_DIR/sce_sys/param.json" "$FPKG_DIR/sce_sys/"
cp "$PROJECT_DIR/sce_sys/icon0.png" "$FPKG_DIR/sce_sys/"

echo "  eboot.bin: $(du -h "$FPKG_DIR/eboot.bin" | cut -f1)"
echo "  param.json + icon0.png copiados"

# ── Generar GP4 (PlayStation Package Project) ─────────
echo "[2/3] Generando archivo GP4..."

GP4="$BUILD/hackintosh.gp4"
cat > "$GP4" << 'GP4EOF'
<?xml version="1.0" encoding="utf-8"?>
<psproject fmt="gp4" version="1000">
  <volume>
    <volume_type>pkg_ps5_app</volume_type>
    <volume_id>PS5GD</volume_id>
    <volume_ts>2026-10-22 00:00:00</volume_ts>
    <package content_id="IV0000-HACK00001_00-HACKINTOSHPS5000"
            passcode="00000000000000000000000000000000"
            storage_type="digital50"
            app_type="full" />
  </volume>
  <files img_no="0">
    <file targ_path="eboot.bin" orig_path="fpkg/eboot.bin" />
    <file targ_path="sce_sys/param.json" orig_path="fpkg/sce_sys/param.json" />
    <file targ_path="sce_sys/icon0.png" orig_path="fpkg/sce_sys/icon0.png" />
  </files>
  <rootdir>
    <dir targ_name="sce_sys" />
  </rootdir>
</psproject>
GP4EOF

echo "  hackintosh.gp4 generado"

# ── Intentar crear fPKG ───────────────────────────────
echo "[3/3] Creando fPKG..."

FPKG_OUT="$BUILD/Hackintosh-PS5.pkg"

# Opción 1: PkgTool nativo
if command -v PkgTool >/dev/null 2>&1; then
    PkgTool pkg_build "$GP4" "$FPKG_OUT"
    echo "  fPKG creado: $FPKG_OUT"

# Opción 2: prospero-pkg si existe
elif command -v prospero-pkg >/dev/null 2>&1; then
    prospero-pkg create --content-id IV0000-HACK00001_00-HACKINTOSHPS5000 \
        --title "Hackintosh" "$FPKG_DIR" "$FPKG_OUT"
    echo "  fPKG creado: $FPKG_OUT"

# Opción 3: Instrucciones manuales
else
    echo ""
    echo "  No se encontró herramienta de empaquetado fPKG."
    echo ""
    echo "  La estructura del paquete está lista en: $FPKG_DIR/"
    echo "  El archivo GP4 está en: $GP4"
    echo ""
    echo "  Para crear el fPKG, necesitas una de estas herramientas:"
    echo ""
    echo "  Opción A — PkgTool (Windows/Wine):"
    echo "    1. Descarga PkgTool de https://github.com/niclasr/PkgTool"
    echo "    2. PkgTool.exe pkg_build hackintosh.gp4 Hackintosh-PS5.pkg"
    echo ""
    echo "  Opción B — Instalar en PS5 directamente:"
    echo "    El payload no necesita fPKG — se envía por red."
    echo "    Usa: ./tools/deploy.sh"
    echo "    O:   ./tools/launch_hackintosh.sh"
    echo ""
    echo "  Opción C — Homebrew Store de PS5:"
    echo "    Si tienes el homebrew store instalado en la PS5,"
    echo "    puedes subir eboot.bin + sce_sys/ vía FTP."
    echo ""
fi

echo ""
echo "═══════════════════════════════════════════════"
echo "Contenido del paquete:"
find "$FPKG_DIR" -type f | while read f; do
    echo "  $(echo "$f" | sed "s|$FPKG_DIR/||") ($(du -h "$f" | cut -f1))"
done
echo "═══════════════════════════════════════════════"
