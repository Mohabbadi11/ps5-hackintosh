#!/bin/bash
#
# PS5 Hackintosh — Lanzador rápido
#
# Automatiza: verificar → enviar payload → esperar rest mode → boot
#
# Uso: ./tools/launch_hackintosh.sh [PS5_IP]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD="$PROJECT_DIR/build"
ELF="$BUILD/bin/ps5-linux-loader.elf"

[ -f "${PROJECT_DIR:-$(cd "$(dirname "$0")/.." && pwd)}/.env" ] && { set -a; . "${PROJECT_DIR:-$(cd "$(dirname "$0")/.." && pwd)}/.env"; set +a; }
PS5_HOST="${1:-${PS5_HOST:?set PS5_HOST (the console IP while it listens for payloads) in .env}}"
PAYLOAD_PORT=9021

echo ""
echo "  ╔══════════════════════════════════════════╗"
echo "  ║       🍎 PS5 Hackintosh Launcher 🎮     ║"
echo "  ╚══════════════════════════════════════════╝"
echo ""

# ── Verificaciones ────────────────────────────────────
echo "[1/5] Verificando artefactos..."
MISSING=""
[ ! -f "$ELF" ] && MISSING="$MISSING loader.elf"
[ ! -f "$BUILD/bzImage" ] && MISSING="$MISSING bzImage"
[ ! -f "$BUILD/initrd.img" ] && MISSING="$MISSING initrd.img"

if [ -n "$MISSING" ]; then
    echo "  Faltan:$MISSING"
    echo "  Ejecuta: make all"
    exit 1
fi
echo "  Artefactos OK"

# ── Verificar USB ─────────────────────────────────────
echo "[2/5] Verificando USB..."
USB_FOUND=""
for vol in /Volumes/PS5*; do
    if [ -f "$vol/bzImage" ] && [ -f "$vol/initrd.img" ]; then
        USB_FOUND="$vol"
        break
    fi
done

if [ -z "$USB_FOUND" ]; then
    echo "  USB no detectado. Asegúrate de que:"
    echo "    - El USB está conectado al Mac"
    echo "    - Tiene bzImage e initrd.img en la raíz"
    echo "    - Usa FAT32 como sistema de archivos"
    echo ""
    echo "  Preparar USB: ./tools/create_usb.sh /Volumes/TU_USB"
    exit 1
fi
echo "  USB encontrado: $USB_FOUND"

# ── Verificar PS5 ────────────────────────────────────
echo "[3/5] Conectando a PS5 ($PS5_HOST)..."
if ! nc -z -w 3 "$PS5_HOST" "$PAYLOAD_PORT" 2>/dev/null; then
    echo "  No se puede conectar a $PS5_HOST:$PAYLOAD_PORT"
    echo ""
    echo "  1. Enciende la PS5"
    echo "  2. Activa el jailbreak (Y2JB/etahen)"
    echo "  3. Vuelve a ejecutar este script"
    exit 1
fi
echo "  PS5 conectada"

# ── Enviar payload ────────────────────────────────────
echo "[4/5] Enviando payload..."
echo "  (La PS5 entrará en rest mode — NO la toques)"
socat -t 99999999 - TCP:"$PS5_HOST":"$PAYLOAD_PORT" < "$ELF"
echo "  Payload enviado"

# ── Esperar ───────────────────────────────────────────
echo "[5/5] Esperando rest mode..."
echo ""
echo "  La PS5 entrará en rest mode (LED naranja)."
echo "  Cuando el LED sea naranja FIJO (no parpadea),"
echo "  pulsa el botón de encendido."
echo ""
echo "  La PS5 arrancará:"
echo "    Linux → QEMU/KVM → OpenCore → macOS"
echo ""
echo "  Si el LED se pone blanco pero la pantalla está negra,"
echo "  espera 30-60 segundos — macOS puede tardar en iniciar."
echo ""
echo "  ¡NO desconectes el USB!"
