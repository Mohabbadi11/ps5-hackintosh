#!/bin/bash
#
# PS5 Hackintosh — Deploy payload to PS5
#
# Usage: ./tools/deploy.sh [PS5_IP]
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
ELF="$PROJECT_DIR/build/bin/ps5-hackintosh.elf"

PS5_HOST="${1:-${PS5_HOST:-192.168.1.91}}"
PAYLOAD_PORT=9021

if [ ! -f "$ELF" ]; then
    echo "Error: Build the project first: make"
    exit 1
fi

echo "╔══════════════════════════════════════════╗"
echo "║    PS5 Hackintosh — Deploy              ║"
echo "╚══════════════════════════════════════════╝"
echo ""
echo "  Target:  $PS5_HOST:$PAYLOAD_PORT"
echo "  Payload: $ELF ($(du -h "$ELF" | cut -f1))"
echo ""

# Check connectivity
if ! nc -z -w 3 "$PS5_HOST" "$PAYLOAD_PORT" 2>/dev/null; then
    echo "Error: Cannot reach $PS5_HOST:$PAYLOAD_PORT"
    echo ""
    echo "Make sure:"
    echo "  1. PS5 is on and connected to the network"
    echo "  2. Jailbreak is active (port $PAYLOAD_PORT open)"
    echo "  3. IP address is correct"
    exit 1
fi

echo "Sending payload..."
socat -t 99999999 - TCP:"$PS5_HOST":"$PAYLOAD_PORT" < "$ELF"

echo ""
echo "Payload sent. The PS5 will:"
echo "  1. Load the kernel and initramfs from USB"
echo "  2. Enter rest mode"
echo "  3. Resume into macOS"
echo ""
echo "Do NOT unplug the USB drive until macOS boots!"
