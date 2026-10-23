#!/bin/bash
#
# PS5 Hackintosh — Create Alpine rootfs with QEMU
#
# Creates an ext4 rootfs containing minimal Alpine Linux + QEMU + KVM.
# This rootfs goes on the second USB partition (ext4).
#
# Requires Docker to build the rootfs (cross-compile for x86_64).
#
# Usage: ./tools/create_rootfs.sh [output-dir]
#   output-dir: directory for rootfs.img (default: build/)
#
# Output: rootfs.img (~500MB) ready to dd onto an ext4 USB partition.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD="${1:-$PROJECT_DIR/build}"
ROOTFS_IMG="$BUILD/rootfs.img"
ROOTFS_DIR="$BUILD/rootfs"
ROOTFS_SIZE="1G"

mkdir -p "$BUILD"

echo "╔══════════════════════════════════════════════╗"
echo "║  PS5 Hackintosh — Create rootfs with QEMU   ║"
echo "╚══════════════════════════════════════════════╝"
echo ""

# ── Check Docker ─────────────────────────────────────
if ! command -v docker >/dev/null 2>&1; then
    echo "ERROR: Docker not found."
    echo "Install Docker Desktop: https://docker.com"
    exit 1
fi

if ! docker info >/dev/null 2>&1; then
    echo "ERROR: Docker is not running."
    echo "Start Docker Desktop and run this script again."
    exit 1
fi

# ── Create rootfs with Docker (Alpine x86_64) ───────
echo "[1/4] Creating Alpine x86_64 rootfs with QEMU..."

mkdir -p "$ROOTFS_DIR"

docker run --rm --platform linux/amd64 \
    -v "$ROOTFS_DIR:/rootfs" \
    -v "$PROJECT_DIR/initramfs/scripts:/scripts:ro" \
    alpine:3.20 sh -c '
    set -e

    # Compile ds-mouse (DualSense -> mouse/keyboard mapper)
    echo "Compiling ds-mouse..."
    apk add --no-cache gcc musl-dev linux-headers >/dev/null 2>&1
    gcc -O2 -static -o /tmp/ds-mouse /scripts/ds-mouse.c
    echo "ds-mouse compiled"

    set -e

    echo "Installing packages..."
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

    echo "Preparing rootfs..."
    mkdir -p /rootfs/bin /rootfs/sbin /rootfs/usr/bin /rootfs/usr/sbin \
             /rootfs/usr/lib /rootfs/usr/share /rootfs/lib /rootfs/lib64 \
             /rootfs/etc /rootfs/dev /rootfs/proc /rootfs/sys /rootfs/tmp \
             /rootfs/run /rootfs/var /rootfs/mnt/macos /rootfs/hackintosh

    # Copy QEMU and dependencies
    cp /usr/bin/qemu-system-x86_64 /rootfs/usr/bin/
    cp /usr/bin/qemu-img /rootfs/usr/bin/
    cp -a /usr/lib/qemu/ /rootfs/usr/lib/qemu/ 2>/dev/null || true
    cp -a /usr/share/qemu/ /rootfs/usr/share/qemu/ 2>/dev/null || mkdir -p /rootfs/usr/share/qemu

    # Copy OVMF
    if [ -d /usr/share/OVMF ]; then
        cp -a /usr/share/OVMF /rootfs/usr/share/
    fi

    # Copy basic tools
    for bin in bash sh mount umount blkid lsblk findmnt modprobe lsmod lspci lsusb \
               ls cat cp mv rm mkdir echo grep sed awk sleep clear dmesg \
               ip ifconfig route; do
        src=$(which "$bin" 2>/dev/null || true)
        [ -n "$src" ] && [ -f "$src" ] && cp "$src" /rootfs/usr/bin/ 2>/dev/null || true
    done

    # Copy required libraries
    for lib in /lib/ld-musl-*.so.1 /usr/lib/lib*.so* /lib/lib*.so*; do
        [ -f "$lib" ] && cp -a "$lib" /rootfs/lib/ 2>/dev/null || true
    done
    ln -sf /lib/ld-musl-x86_64.so.1 /rootfs/lib/ld-linux-x86-64.so.2 2>/dev/null || true

    # Basic config
    echo "root:x:0:0:root:/root:/bin/bash" > /rootfs/etc/passwd
    echo "root:x:0:" > /rootfs/etc/group
    echo "ps5-hackintosh" > /rootfs/etc/hostname
    echo "nameserver 8.8.8.8" > /rootfs/etc/resolv.conf

    # Copy boot script and ds-mouse
    cp /scripts/boot-macos.sh /rootfs/hackintosh/ 2>/dev/null || true
    chmod +x /rootfs/hackintosh/boot-macos.sh 2>/dev/null || true
    cp /tmp/ds-mouse /rootfs/hackintosh/ds-mouse
    chmod +x /rootfs/hackintosh/ds-mouse

    echo "Rootfs created successfully."
    du -sh /rootfs/
'

echo "[2/4] Alpine rootfs created."

# ── Copy our boot script ─────────────────────────────
echo "[3/4] Adding Hackintosh scripts..."
cp "$PROJECT_DIR/initramfs/scripts/boot-macos.sh" "$ROOTFS_DIR/hackintosh/boot-macos.sh"
chmod +x "$ROOTFS_DIR/hackintosh/boot-macos.sh"

# ── Create ext4 image ────────────────────────────────
echo "[4/4] Creating ext4 image ($ROOTFS_SIZE)..."

# Create sparse image
dd if=/dev/zero of="$ROOTFS_IMG" bs=1 count=0 seek="$ROOTFS_SIZE" 2>/dev/null

# Format as ext4 and copy contents
if command -v mkfs.ext4 >/dev/null 2>&1; then
    mkfs.ext4 -q -d "$ROOTFS_DIR" "$ROOTFS_IMG"
else
    # On macOS without fuse-ext2: use Docker
    docker run --rm --platform linux/amd64 \
        -v "$BUILD:/build" \
        alpine:3.20 sh -c "
        apk add --no-cache e2fsprogs
        mkfs.ext4 -q -d /build/rootfs /build/rootfs.img
    "
fi

echo ""
echo "═══════════════════════════════════════════════"
echo "Rootfs created: $ROOTFS_IMG"
echo "Size: $(du -h "$ROOTFS_IMG" | cut -f1)"
echo ""
echo "To write to USB (partition 2):"
echo "  sudo dd if=$ROOTFS_IMG of=/dev/sdX2 bs=4M status=progress"
echo ""
echo "Or mount and inspect:"
echo "  sudo mount $ROOTFS_IMG /mnt"
echo "  ls /mnt/usr/bin/qemu-system-x86_64"
echo "═══════════════════════════════════════════════"
