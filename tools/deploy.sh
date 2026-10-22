#!/bin/bash
#
# PS5 Hackintosh — Desplegar payload a PS5
#
# Uso: ./tools/deploy.sh [PS5_IP]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
ELF="$PROJECT_DIR/build/bin/ps5-linux-loader.elf"

PS5_HOST="${1:-${PS5_HOST:-192.168.1.91}}"
PAYLOAD_PORT=9021

if [ ! -f "$ELF" ]; then
    echo "Error: Compila primero: make loader"
    exit 1
fi

echo "╔══════════════════════════════════════════╗"
echo "║    PS5 Hackintosh — Deploy              ║"
echo "╚══════════════════════════════════════════╝"
echo ""
echo "  Target:  $PS5_HOST:$PAYLOAD_PORT"
echo "  Payload: $ELF ($(du -h "$ELF" | cut -f1))"
echo ""

# Verificar conectividad
if ! nc -z -w 3 "$PS5_HOST" "$PAYLOAD_PORT" 2>/dev/null; then
    echo "Error: No se puede conectar a $PS5_HOST:$PAYLOAD_PORT"
    echo ""
    echo "Asegúrate de:"
    echo "  1. PS5 encendida y en la misma red"
    echo "  2. Jailbreak activo (puerto $PAYLOAD_PORT abierto)"
    echo "  3. IP correcta (actual: $PS5_HOST)"
    exit 1
fi

echo "Enviando payload..."
socat -t 99999999 - TCP:"$PS5_HOST":"$PAYLOAD_PORT" < "$ELF"

echo ""
echo "Payload enviado. La PS5:"
echo "  1. Cargará bzImage + initrd.img del USB"
echo "  2. Entrará en rest mode"
echo "  3. Al despertar, arrancará Linux → QEMU/KVM → macOS"
echo ""
echo "NO desconectes el USB hasta que macOS haya arrancado."
