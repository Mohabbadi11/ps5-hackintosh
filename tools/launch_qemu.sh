#!/bin/bash
#
# PS5 Hackintosh — Launch QEMU/KVM for macOS
#
# Runs on the PS5's Arch Linux via SSH.
# Phase 1: VNC display (for installation)
# Phase 2: GPU passthrough (after macOS is installed)
#
# Usage:
#   ./launch_qemu.sh              # VNC mode, boots the installed macOS
#   ./launch_qemu.sh --gpu        # GPU passthrough mode
#   ./launch_qemu.sh --recovery   # also attach BaseSystem.raw (install / repair)

set -euo pipefail

MACOS_DIR="/mnt/macos"
MACOS_IMG="${MACOS_IMG:-$MACOS_DIR/macOS.img}"
OC_IMG="$MACOS_DIR/OpenCore.img"
RECOVERY_IMG="$MACOS_DIR/BaseSystem.raw"
OVMF_CODE="/usr/share/edk2/x64/OVMF_CODE.4m.fd"
OVMF_VARS_ORIG="/usr/share/edk2/x64/OVMF_VARS.4m.fd"
OVMF_VARS="$MACOS_DIR/OVMF_VARS.4m.fd"

GPU_MODE=false
WANT_RECOVERY=false
for arg in "$@"; do
    case "$arg" in
        --gpu) GPU_MODE=true ;;
        --recovery) WANT_RECOVERY=true ;;
        *) echo "Unknown option: $arg"; exit 1 ;;
    esac
done

echo ""
echo " ╔══════════════════════════════════════════════╗"
echo " ║         PS5 Hackintosh — macOS Boot          ║"
echo " ╚══════════════════════════════════════════════╝"
echo ""

# ── Verify files ───────────────────────────────────
echo "[hackintosh] Checking files..."
for f in "$MACOS_IMG" "$OC_IMG" "$OVMF_CODE"; do
    if [ ! -f "$f" ]; then
        echo "ERROR: $f not found"
        exit 1
    fi
done

if [ "$WANT_RECOVERY" = true ] && [ -f "$RECOVERY_IMG" ]; then
    echo "[hackintosh] Recovery image attached"
    HAS_RECOVERY=true
else
    HAS_RECOVERY=false
fi

# ── OVMF vars (persistent, keeps the OpenCore default boot entry) ──
[ -f "$OVMF_VARS" ] || cp "$OVMF_VARS_ORIG" "$OVMF_VARS"

# ── Load kernel modules ──────────────────────────
echo "[hackintosh] Loading KVM modules..."
sudo modprobe kvm ignore_msrs=1 report_ignored_msrs=0
sudo modprobe kvm_amd nested=1
# modprobe options are ignored when kvm is already loaded; set them live too
for p in ignore_msrs:1 report_ignored_msrs:0; do
    echo "${p#*:}" | sudo tee "/sys/module/kvm/parameters/${p%:*}" >/dev/null
done

# ── Hugepages ────────────────────────────────────
echo "[hackintosh] Setting up hugepages (8GB)..."
sudo bash -c 'echo 4096 > /proc/sys/vm/nr_hugepages'
sleep 1
ACTUAL_HP=$(cat /proc/sys/vm/nr_hugepages)
echo "[hackintosh] Hugepages allocated: $ACTUAL_HP (requested 4096)"

# ── CPU topology ─────────────────────────────────
# The total vCPU count must be a power of 2 (2 threads per core): QEMU rounds
# the topology up to one, and macOS libmalloc aborts launchd unless
# logical/physical CPUs is 1, 2 or 4. Use all host threads, up to 16.
HOST_THREADS=$(nproc --all)
CPUS="${VM_CPUS:-16}"
while [ "$CPUS" -gt "$HOST_THREADS" ] && [ "$CPUS" -gt 2 ]; do CPUS=$((CPUS / 2)); done
THREADS=2
CORES=$((CPUS / THREADS))
SOCKETS=1
MEM="8G"
echo "[hackintosh] vCPUs: $CPUS ($CORES cores x $THREADS threads), RAM: $MEM"

# ── Build QEMU command ───────────────────────────
QEMU_CMD="sudo qemu-system-x86_64"
QEMU_CMD="$QEMU_CMD -enable-kvm"
QEMU_CMD="$QEMU_CMD -machine q35,accel=kvm,kernel_irqchip=on"
QEMU_CMD="$QEMU_CMD -cpu host,vendor=GenuineIntel,+invtsc,+ssse3,+sse4.2,+popcnt,+avx,+aes,+xsave,+xsaveopt,kvm=off,vmware-cpuid-freq=on"
QEMU_CMD="$QEMU_CMD -smp cpus=$CPUS,cores=$CORES,threads=$THREADS,sockets=$SOCKETS"
QEMU_CMD="$QEMU_CMD -m $MEM"
QEMU_CMD="$QEMU_CMD -mem-prealloc"
QEMU_CMD="$QEMU_CMD -mem-path /dev/hugepages"

# UEFI firmware (4MB variant)
QEMU_CMD="$QEMU_CMD -drive if=pflash,format=raw,readonly=on,file=$OVMF_CODE"
QEMU_CMD="$QEMU_CMD -drive if=pflash,format=raw,file=$OVMF_VARS"

# OpenCore (boot disk)
QEMU_CMD="$QEMU_CMD -drive id=OpenCore,if=none,format=qcow2,file=$OC_IMG"
QEMU_CMD="$QEMU_CMD -device virtio-blk-pci,drive=OpenCore,bootindex=1"

# macOS disk
QEMU_CMD="$QEMU_CMD -drive id=MacOS,if=none,format=qcow2,file=$MACOS_IMG,cache=writeback,aio=threads"
QEMU_CMD="$QEMU_CMD -device virtio-blk-pci,drive=MacOS"

# Recovery image (for installation)
if [ "$HAS_RECOVERY" = true ]; then
    QEMU_CMD="$QEMU_CMD -drive id=Recovery,if=none,format=raw,file=$RECOVERY_IMG,readonly=on"
    QEMU_CMD="$QEMU_CMD -device virtio-blk-pci,drive=Recovery"
fi

# ── Display ──────────────────────────────────────
if [ "$GPU_MODE" = true ]; then
    echo "[hackintosh] GPU passthrough mode"
    GPU_PCI="0000:20:00.0"

    echo "[hackintosh] Unbinding GPU from amdgpu..."
    echo "$GPU_PCI" | sudo tee /sys/bus/pci/devices/$GPU_PCI/driver/unbind 2>/dev/null || true
    echo "vfio-pci" | sudo tee /sys/bus/pci/devices/$GPU_PCI/driver_override
    echo "$GPU_PCI" | sudo tee /sys/bus/pci/drivers/vfio-pci/bind 2>/dev/null || true
    sudo modprobe vfio_pci

    QEMU_CMD="$QEMU_CMD -device vfio-pci,host=20:00.0,multifunction=on,x-vga=on,rombar=0"
    QEMU_CMD="$QEMU_CMD -nographic -vga none"
else
    echo "[hackintosh] VNC mode — connect from Mac with:"
    echo "    open vnc://192.168.1.200:5900"
    echo ""
    QEMU_CMD="$QEMU_CMD -device vmware-svga,vgamem_mb=128"
    QEMU_CMD="$QEMU_CMD -object secret,id=vnc-pass,data=1234"
    QEMU_CMD="$QEMU_CMD -vnc :0,password-secret=vnc-pass"
fi

# Network (user mode with SSH forwarding)
QEMU_CMD="$QEMU_CMD -netdev user,id=net0,hostfwd=tcp:127.0.0.1:2222-:22"
QEMU_CMD="$QEMU_CMD -device virtio-net-pci,netdev=net0"

# USB + input
QEMU_CMD="$QEMU_CMD -usb"
QEMU_CMD="$QEMU_CMD -device qemu-xhci,id=xhci"
QEMU_CMD="$QEMU_CMD -device usb-kbd"
QEMU_CMD="$QEMU_CMD -device usb-tablet"

# Audio (virtual)
QEMU_CMD="$QEMU_CMD -device intel-hda"
QEMU_CMD="$QEMU_CMD -device hda-duplex"

# macOS specifics
QEMU_CMD="$QEMU_CMD -rtc base=localtime,driftfix=slew"
QEMU_CMD="$QEMU_CMD -global ICH9-LPC.disable_s3=1"
QEMU_CMD="$QEMU_CMD -global ICH9-LPC.disable_s4=1"
QEMU_CMD="$QEMU_CMD -device 'isa-applesmc,osk=ourhardworkbythesewordsguardedpleasedontsteal(c)AppleComputerInc'"
QEMU_CMD="$QEMU_CMD -smbios type=2"

# Debug: serial log + monitor socket
QEMU_CMD="$QEMU_CMD -serial file:/mnt/macos/serial.log"
QEMU_CMD="$QEMU_CMD -monitor unix:/tmp/qemu-monitor.sock,server,nowait"
QEMU_CMD="$QEMU_CMD -debugcon file:/mnt/macos/ovmf-debug.log -global isa-debugcon.iobase=0x402"

echo "[hackintosh] Launching QEMU..."
echo ""
eval "$QEMU_CMD"
