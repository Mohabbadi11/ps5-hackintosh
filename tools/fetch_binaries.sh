#!/bin/bash
#
# PS5 Hackintosh — Descarga binarios estáticos para el initramfs
#
# Descarga busybox y QEMU estáticos (x86_64 Linux) necesarios para
# el initramfs que arranca macOS en la PS5.
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD="$PROJECT_DIR/build"
BIN="$BUILD/bin"

mkdir -p "$BIN"

echo "╔══════════════════════════════════════════════╗"
echo "║  PS5 Hackintosh — Descarga de binarios      ║"
echo "╚══════════════════════════════════════════════╝"
echo ""

# ── BusyBox estático (x86_64) ──────────────────────────
BUSYBOX_URL="https://busybox.net/downloads/binaries/1.35.0-x86_64-linux-musl/busybox"
BUSYBOX_BIN="$BIN/busybox"

if [ -f "$BUSYBOX_BIN" ]; then
    echo "[✓] BusyBox ya descargado"
else
    echo "[↓] Descargando BusyBox estático..."
    curl -L -o "$BUSYBOX_BIN" "$BUSYBOX_URL"
    chmod +x "$BUSYBOX_BIN"
    echo "[✓] BusyBox descargado"
fi

# ── QEMU estático (x86_64) ────────────────────────────
# Necesitamos QEMU compilado estáticamente para x86_64 Linux.
# Opciones:
#   1. Compilar QEMU --static en una máquina Linux
#   2. Usar un build pre-compilado
#   3. Usar el QEMU del sistema de archivos de la distro Linux del PS5
QEMU_BIN="$BIN/qemu-system-x86_64"

if [ -f "$QEMU_BIN" ]; then
    echo "[✓] QEMU ya presente"
else
    echo ""
    echo "[!] QEMU estático no encontrado en $QEMU_BIN"
    echo ""
    echo "QEMU necesita ser compilado estáticamente para Linux x86_64."
    echo "No se puede cross-compilar fácilmente desde macOS."
    echo ""
    echo "Opciones para obtener QEMU estático:"
    echo ""
    echo "  Opción 1 — Compilar en Linux (recomendado):"
    echo "    git clone https://github.com/qemu/qemu.git"
    echo "    cd qemu && mkdir build && cd build"
    echo "    ../configure --target-list=x86_64-softmmu --static \\"
    echo "                 --disable-tools --disable-guest-agent"
    echo "    make -j\$(nproc)"
    echo "    cp build/qemu-system-x86_64 $QEMU_BIN"
    echo ""
    echo "  Opción 2 — Usar Docker desde macOS:"
    echo "    docker run --rm -v $BIN:/out alpine:latest sh -c '"
    echo "      apk add qemu-system-x86_64 && cp /usr/bin/qemu-system-x86_64 /out/'"
    echo ""
    echo "  Opción 3 — Incluir QEMU en el rootfs de Linux:"
    echo "    En vez de initramfs, usar un rootfs completo con QEMU instalado."
    echo "    Montar el rootfs desde la partición USB."
    echo ""
fi

# ── OVMF (firmware UEFI para QEMU) ───────────────────
OVMF_CODE="$BIN/OVMF_CODE.fd"
if [ -f "$OVMF_CODE" ]; then
    echo "[✓] OVMF ya presente"
else
    echo "[↓] Descargando OVMF (firmware UEFI)..."
    # OVMF de EDK2 para macOS
    OVMF_URL="https://github.com/kholia/OSX-KVM/raw/master/OVMF_CODE.fd"
    curl -L -o "$OVMF_CODE" "$OVMF_URL" 2>/dev/null || {
        echo "[!] No se pudo descargar OVMF automáticamente."
        echo "    Descarga manualmente de: https://github.com/kholia/OSX-KVM"
        echo "    y copia OVMF_CODE.fd a $OVMF_CODE"
    }
    [ -f "$OVMF_CODE" ] && echo "[✓] OVMF descargado"
fi

echo ""
echo "═══════════════════════════════════════════════"
echo "Estado de binarios:"
[ -f "$BUSYBOX_BIN" ] && echo "  ✓ BusyBox: $(du -h "$BUSYBOX_BIN" | cut -f1)" || echo "  ✗ BusyBox"
[ -f "$QEMU_BIN" ] && echo "  ✓ QEMU: $(du -h "$QEMU_BIN" | cut -f1)" || echo "  ✗ QEMU (necesita compilación manual)"
[ -f "$OVMF_CODE" ] && echo "  ✓ OVMF: $(du -h "$OVMF_CODE" | cut -f1)" || echo "  ✗ OVMF"
echo "═══════════════════════════════════════════════"
