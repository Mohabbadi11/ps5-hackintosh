#!/bin/bash
#
# PS5 Hackintosh — Instalar macOS en QEMU (en tu Mac)
#
# Lanza QEMU con OpenCore + recovery para instalar macOS
# en la imagen de disco. Esto se ejecuta en tu Mac, NO en PS5.
#
# Uso: ./tools/install_macos_qemu.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD="$PROJECT_DIR/build"

MACOS_IMG="$BUILD/macOS.img"
RECOVERY_IMG="$BUILD/macOS-recovery.img"
OC_IMG="$BUILD/OpenCore.img"
OVMF_CODE="$BUILD/OVMF_CODE.fd"
OVMF_VARS="$BUILD/OVMF_VARS.fd"
OVMF_VARS_TMP="/tmp/ps5-hackintosh-OVMF_VARS.fd"

echo "╔══════════════════════════════════════════════╗"
echo "║  PS5 Hackintosh — Instalar macOS (QEMU)     ║"
echo "╚══════════════════════════════════════════════╝"
echo ""

# ── Verificar artefactos ──────────────────────────────
MISSING=""
[ ! -f "$OC_IMG" ]      && MISSING="$MISSING OpenCore.img"
[ ! -f "$OVMF_CODE" ]   && MISSING="$MISSING OVMF_CODE.fd"
[ ! -f "$OVMF_VARS" ]   && MISSING="$MISSING OVMF_VARS.fd"
[ ! -f "$MACOS_IMG" ]    && MISSING="$MISSING macOS.img"

if [ -n "$MISSING" ]; then
    echo "Faltan:$MISSING"
    echo "Ejecuta primero: ./tools/create_macos_img.sh"
    exit 1
fi

# Copia temporal de OVMF_VARS (QEMU escribe en él)
cp "$OVMF_VARS" "$OVMF_VARS_TMP"

# ── Determinar aceleración ────────────────────────────
ACCEL=""
if [ "$(uname -m)" = "arm64" ]; then
    # macOS ARM — usamos HVF (Hypervisor.framework)
    ACCEL="-accel hvf -cpu host"
    CPU_MODEL="host"
    echo "  Aceleración: HVF (Apple Silicon)"
elif [ "$(uname -m)" = "x86_64" ]; then
    ACCEL="-accel hvf -cpu Penryn,+ssse3,+sse4.2,+popcnt,+avx,+aes,+xsave,+xsaveopt,vendor=GenuineIntel"
    echo "  Aceleración: HVF (Intel)"
else
    ACCEL="-accel tcg -cpu Penryn,+ssse3,+sse4.2,+popcnt,+avx,+aes,+xsave,+xsaveopt,vendor=GenuineIntel"
    echo "  Aceleración: TCG (emulación, será lento)"
fi

echo "  macOS.img:    $MACOS_IMG"
echo "  OpenCore:     $OC_IMG"
echo ""

# ── Construir argumentos QEMU ─────────────────────────
QEMU_ARGS=(
    -machine q35
    $ACCEL
    -smp 4,cores=4,threads=1
    -m 8G

    # UEFI firmware
    -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE"
    -drive "if=pflash,format=raw,file=$OVMF_VARS_TMP"

    # OpenCore (disco de boot)
    -drive "id=OpenCore,if=none,format=qcow2,file=$OC_IMG"
    -device ide-hd,bus=sata.0,drive=OpenCore,bootindex=1

    # Disco macOS
    -drive "id=MacHDD,if=none,format=qcow2,file=$MACOS_IMG"
    -device ide-hd,bus=sata.1,drive=MacHDD

    # Display
    -device virtio-vga
    -display default,show-cursor=on

    # Red (SSH en puerto 2222)
    -device virtio-net-pci,netdev=net0
    -netdev user,id=net0,hostfwd=tcp::2222-:22

    # USB
    -device qemu-xhci
    -device usb-kbd
    -device usb-tablet

    # Audio (opcional)
    -device ich9-intel-hda
    -device hda-duplex
)

# Añadir recovery si existe
if [ -f "$RECOVERY_IMG" ]; then
    QEMU_ARGS+=(
        -drive "id=Recovery,if=none,format=raw,file=$RECOVERY_IMG"
        -device ide-hd,bus=sata.2,drive=Recovery
    )
    echo "  Recovery:     $RECOVERY_IMG"
fi

echo ""
echo "  Lanzando QEMU..."
echo "  (La ventana de QEMU se abrirá con OpenCore)"
echo ""
echo "  Instrucciones de instalación:"
echo "    1. En OpenCore, selecciona 'macOS Base System'"
echo "    2. Abre Disk Utility, formatea el disco de 64GB como APFS"
echo "    3. Sal de Disk Utility e instala macOS"
echo "    4. La instalación reiniciará varias veces"
echo "    5. Cuando termine, apaga la VM (Cmd+Q en QEMU)"
echo ""
echo "  SSH disponible en: ssh localhost -p 2222"
echo "  Ctrl+Alt+G para liberar el ratón"
echo ""

qemu-system-x86_64 "${QEMU_ARGS[@]}"

echo ""
echo "═══════════════════════════════════════════════"
echo "Instalación completada."
echo ""
echo "  macOS.img listo: $(du -h "$MACOS_IMG" | cut -f1)"
echo ""
echo "  Siguiente paso: copiar todo al USB"
echo "    ./tools/create_usb.sh /dev/diskN"
echo "═══════════════════════════════════════════════"
