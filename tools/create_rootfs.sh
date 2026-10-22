#!/bin/bash
#
# PS5 Hackintosh — Crear rootfs Alpine con QEMU
#
# Crea un rootfs ext4 que contiene Alpine Linux mínimo + QEMU + KVM.
# Este rootfs va en la segunda partición del USB (ext4).
#
# Requiere Docker para crear el rootfs (cross-compile para x86_64).
#
# Uso: ./tools/create_rootfs.sh [output-dir]
#   output-dir: directorio donde se crea rootfs.img (default: build/)
#
# El resultado es un archivo rootfs.img (~500MB) listo para dd a una
# partición ext4 del USB.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD="${1:-$PROJECT_DIR/build}"
ROOTFS_IMG="$BUILD/rootfs.img"
ROOTFS_DIR="$BUILD/rootfs"
ROOTFS_SIZE="1G"

mkdir -p "$BUILD"

echo "╔══════════════════════════════════════════════╗"
echo "║  PS5 Hackintosh — Crear rootfs con QEMU     ║"
echo "╚══════════════════════════════════════════════╝"
echo ""

# ── Verificar Docker ──────────────────────────────────
if ! command -v docker >/dev/null 2>&1; then
    echo "ERROR: Docker no encontrado."
    echo "Instala Docker Desktop: https://docker.com"
    exit 1
fi

if ! docker info >/dev/null 2>&1; then
    echo "ERROR: Docker no está corriendo."
    echo "Abre Docker Desktop y vuelve a ejecutar este script."
    exit 1
fi

# ── Crear rootfs con Docker (Alpine x86_64) ──────────
echo "[1/4] Creando rootfs Alpine x86_64 con QEMU..."

mkdir -p "$ROOTFS_DIR"

docker run --rm --platform linux/amd64 \
    -v "$ROOTFS_DIR:/rootfs" \
    -v "$PROJECT_DIR/initramfs/scripts:/scripts:ro" \
    alpine:3.20 sh -c '
    set -e

    echo "Instalando paquetes..."
    apk add --no-cache \
        qemu-system-x86_64 \
        qemu-img \
        qemu-hw-display-virtio-gpu \
        qemu-hw-usb-host \
        qemu-ui-sdl \
        qemu-audio-sdl \
        ovmf \
        util-linux \
        blkid \
        e2fsprogs \
        dosfstools \
        exfatprogs \
        pciutils \
        usbutils \
        kmod \
        bash \
        coreutils \
        findutils \
        grep \
        sed \
        gawk \
        procps \
        iproute2 \
        bridge-utils

    echo "Preparando rootfs..."
    mkdir -p /rootfs/bin /rootfs/sbin /rootfs/usr/bin /rootfs/usr/sbin \
             /rootfs/usr/lib /rootfs/usr/share /rootfs/lib /rootfs/lib64 \
             /rootfs/etc /rootfs/dev /rootfs/proc /rootfs/sys /rootfs/tmp \
             /rootfs/run /rootfs/var /rootfs/mnt/macos /rootfs/hackintosh

    # Copiar QEMU y dependencias
    cp /usr/bin/qemu-system-x86_64 /rootfs/usr/bin/
    cp /usr/bin/qemu-img /rootfs/usr/bin/
    cp -a /usr/lib/qemu/ /rootfs/usr/lib/qemu/ 2>/dev/null || true
    cp -a /usr/share/qemu/ /rootfs/usr/share/qemu/ 2>/dev/null || mkdir -p /rootfs/usr/share/qemu

    # Copiar OVMF
    if [ -d /usr/share/OVMF ]; then
        cp -a /usr/share/OVMF /rootfs/usr/share/
    fi

    # Copiar herramientas básicas
    for bin in bash sh mount umount blkid lsblk findmnt modprobe lsmod lspci lsusb \
               ls cat cp mv rm mkdir echo grep sed awk sleep clear dmesg \
               ip ifconfig route; do
        src=$(which "$bin" 2>/dev/null || true)
        [ -n "$src" ] && [ -f "$src" ] && cp "$src" /rootfs/usr/bin/ 2>/dev/null || true
    done

    # Copiar bibliotecas necesarias
    for lib in /lib/ld-musl-*.so.1 /usr/lib/lib*.so* /lib/lib*.so*; do
        [ -f "$lib" ] && cp -a "$lib" /rootfs/lib/ 2>/dev/null || true
    done
    ln -sf /lib/ld-musl-x86_64.so.1 /rootfs/lib/ld-linux-x86-64.so.2 2>/dev/null || true

    # Configuración básica
    echo "root:x:0:0:root:/root:/bin/bash" > /rootfs/etc/passwd
    echo "root:x:0:" > /rootfs/etc/group
    echo "ps5-hackintosh" > /rootfs/etc/hostname
    echo "nameserver 8.8.8.8" > /rootfs/etc/resolv.conf

    # Copiar script de boot
    cp /scripts/boot-macos.sh /rootfs/hackintosh/ 2>/dev/null || true
    chmod +x /rootfs/hackintosh/boot-macos.sh 2>/dev/null || true

    echo "Rootfs creado correctamente."
    du -sh /rootfs/
'

echo "[2/4] Rootfs Alpine creado."

# ── Copiar nuestro boot script ────────────────────────
echo "[3/4] Añadiendo scripts del Hackintosh..."
cp "$PROJECT_DIR/initramfs/scripts/boot-macos.sh" "$ROOTFS_DIR/hackintosh/boot-macos.sh"
chmod +x "$ROOTFS_DIR/hackintosh/boot-macos.sh"

# ── Crear imagen ext4 ────────────────────────────────
echo "[4/4] Creando imagen ext4 ($ROOTFS_SIZE)..."

# Crear imagen sparse
dd if=/dev/zero of="$ROOTFS_IMG" bs=1 count=0 seek="$ROOTFS_SIZE" 2>/dev/null

# Formatear con ext4 y copiar contenido
if command -v mkfs.ext4 >/dev/null 2>&1; then
    mkfs.ext4 -q -d "$ROOTFS_DIR" "$ROOTFS_IMG"
else
    # En macOS sin fuse-ext2: crear con Docker
    docker run --rm --platform linux/amd64 \
        -v "$BUILD:/build" \
        alpine:3.20 sh -c "
        apk add --no-cache e2fsprogs
        mkfs.ext4 -q -d /build/rootfs /build/rootfs.img
    "
fi

echo ""
echo "═══════════════════════════════════════════════"
echo "Rootfs creado: $ROOTFS_IMG"
echo "Tamaño: $(du -h "$ROOTFS_IMG" | cut -f1)"
echo ""
echo "Para escribir en el USB (partición 2):"
echo "  sudo dd if=$ROOTFS_IMG of=/dev/sdX2 bs=4M status=progress"
echo ""
echo "O montar y copiar:"
echo "  sudo mount $ROOTFS_IMG /mnt"
echo "  ls /mnt/usr/bin/qemu-system-x86_64"
echo "═══════════════════════════════════════════════"
