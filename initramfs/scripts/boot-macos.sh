#!/bin/sh
#
# PS5 Hackintosh — QEMU/KVM macOS boot script
#
# Launches macOS via QEMU with:
#   - KVM hardware acceleration (AMD-V on Zen 2)
#   - GPU passthrough (RDNA 2 → macOS sees native AMD GPU)
#   - USB passthrough for keyboard/mouse
#   - virtio for disk and network
#

MACOS_IMG="$1"
OVMF_CODE="$2"
OVMF_VARS="$3"
OC_IMG="$4"

# ── CPU topology ──────────────────────────────────────
# PS5: 8 cores / 16 threads — give macOS 6 cores / 12 threads
# Keep 2 cores for Linux host
CPUS=12
CORES=6
THREADS=2
SOCKETS=1

# ── Memory ────────────────────────────────────────────
# PS5: 16 GB GDDR6 unified — give macOS 12 GB
MEM="12G"

# ── GPU passthrough ───────────────────────────────────
# PS5 RDNA 2 GPU PCI address (discovered at runtime)
GPU_PCI=""
GPU_AUDIO_PCI=""

setup_gpu_passthrough() {
    # Find the AMD GPU
    for dev in /sys/bus/pci/devices/*/; do
        vendor=$(cat "$dev/vendor" 2>/dev/null)
        class=$(cat "$dev/class" 2>/dev/null)
        if [ "$vendor" = "0x1002" ] && [ "${class%??}" = "0x0300" ]; then
            GPU_PCI=$(basename "$dev")
            echo "[hackintosh] Found GPU at $GPU_PCI"
            break
        fi
    done

    # Find the GPU's audio function
    if [ -n "$GPU_PCI" ]; then
        gpu_base="${GPU_PCI%.*}"
        for dev in /sys/bus/pci/devices/${gpu_base}.*/; do
            class=$(cat "$dev/class" 2>/dev/null)
            if [ "${class%??}" = "0x0403" ]; then
                GPU_AUDIO_PCI=$(basename "$dev")
                echo "[hackintosh] Found GPU audio at $GPU_AUDIO_PCI"
                break
            fi
        done
    fi

    # Bind GPU to vfio-pci
    if [ -n "$GPU_PCI" ]; then
        echo "[hackintosh] Binding GPU to vfio-pci..."

        local vendor_id=$(cat "/sys/bus/pci/devices/$GPU_PCI/vendor")
        local device_id=$(cat "/sys/bus/pci/devices/$GPU_PCI/device")

        # Unbind from amdgpu
        echo "$GPU_PCI" > /sys/bus/pci/devices/$GPU_PCI/driver/unbind 2>/dev/null || true

        # Bind to vfio-pci
        echo "vfio-pci" > /sys/bus/pci/devices/$GPU_PCI/driver_override
        echo "$GPU_PCI" > /sys/bus/pci/drivers/vfio-pci/bind 2>/dev/null || true

        # Same for audio function
        if [ -n "$GPU_AUDIO_PCI" ]; then
            echo "$GPU_AUDIO_PCI" > /sys/bus/pci/devices/$GPU_AUDIO_PCI/driver/unbind 2>/dev/null || true
            echo "vfio-pci" > /sys/bus/pci/devices/$GPU_AUDIO_PCI/driver_override
            echo "$GPU_AUDIO_PCI" > /sys/bus/pci/drivers/vfio-pci/bind 2>/dev/null || true
        fi

        echo "[hackintosh] GPU bound to vfio-pci"
    fi
}

# ── Build QEMU command ────────────────────────────────
build_qemu_cmd() {
    QEMU_CMD="qemu-system-x86_64"

    # Machine type and acceleration
    QEMU_CMD="$QEMU_CMD -enable-kvm"
    QEMU_CMD="$QEMU_CMD -machine q35,accel=kvm,kernel_irqchip=on"

    # CPU: host passthrough with AMD topology
    QEMU_CMD="$QEMU_CMD -cpu host,vendor=AuthenticAMD,+ssse3,+sse4.2,+popcnt,+avx,+aes,+xsave,+xsaveopt,topoext=on,kvm=off"
    QEMU_CMD="$QEMU_CMD -smp cpus=$CPUS,cores=$CORES,threads=$THREADS,sockets=$SOCKETS"

    # Memory with hugepages
    QEMU_CMD="$QEMU_CMD -m $MEM"
    QEMU_CMD="$QEMU_CMD -mem-prealloc"
    QEMU_CMD="$QEMU_CMD -mem-path /dev/hugepages"

    # UEFI firmware (OVMF)
    QEMU_CMD="$QEMU_CMD -drive if=pflash,format=raw,readonly=on,file=$OVMF_CODE"
    if [ -f "$OVMF_VARS" ]; then
        QEMU_CMD="$QEMU_CMD -drive if=pflash,format=raw,file=$OVMF_VARS"
    fi

    # OpenCore EFI image (boot disk)
    if [ -f "$OC_IMG" ]; then
        QEMU_CMD="$QEMU_CMD -drive id=OpenCore,if=none,format=qcow2,file=$OC_IMG"
        QEMU_CMD="$QEMU_CMD -device virtio-blk-pci,drive=OpenCore,bootindex=1"
    fi

    # macOS disk image
    QEMU_CMD="$QEMU_CMD -drive id=MacOS,if=none,format=raw,file=$MACOS_IMG,cache=writeback,aio=threads"
    QEMU_CMD="$QEMU_CMD -device virtio-blk-pci,drive=MacOS"

    # GPU passthrough
    if [ -n "$GPU_PCI" ]; then
        QEMU_CMD="$QEMU_CMD -device vfio-pci,host=$GPU_PCI,multifunction=on,x-vga=on,rombar=0"
        if [ -n "$GPU_AUDIO_PCI" ]; then
            QEMU_CMD="$QEMU_CMD -device vfio-pci,host=$GPU_AUDIO_PCI"
        fi
        QEMU_CMD="$QEMU_CMD -nographic -vga none"
    else
        # Fallback: virtio-gpu (no passthrough)
        echo "[hackintosh] WARNING: No GPU passthrough — using virtio-vga"
        QEMU_CMD="$QEMU_CMD -device virtio-vga"
        QEMU_CMD="$QEMU_CMD -display sdl,gl=on"
    fi

    # Network: user-mode with port forwarding
    QEMU_CMD="$QEMU_CMD -netdev user,id=net0,hostfwd=tcp::2222-:22"
    QEMU_CMD="$QEMU_CMD -device virtio-net-pci,netdev=net0"

    # USB passthrough (keyboard + mouse from PS5 USB ports)
    QEMU_CMD="$QEMU_CMD -usb"
    QEMU_CMD="$QEMU_CMD -device usb-ehci,id=ehci"
    # Pass through all USB HID devices
    for usbdev in /sys/bus/usb/devices/*/bInterfaceClass; do
        class=$(cat "$usbdev" 2>/dev/null)
        if [ "$class" = "03" ]; then
            busdir=$(dirname "$usbdev")
            vendor=$(cat "$busdir/../idVendor" 2>/dev/null)
            product=$(cat "$busdir/../idProduct" 2>/dev/null)
            if [ -n "$vendor" ] && [ -n "$product" ]; then
                QEMU_CMD="$QEMU_CMD -device usb-host,vendorid=0x$vendor,productid=0x$product"
            fi
        fi
    done

    # Audio (virtio)
    QEMU_CMD="$QEMU_CMD -audiodev sdl,id=audio0"
    QEMU_CMD="$QEMU_CMD -device intel-hda"
    QEMU_CMD="$QEMU_CMD -device hda-duplex,audiodev=audio0"

    # RTC and misc
    QEMU_CMD="$QEMU_CMD -rtc base=localtime,driftfix=slew"
    QEMU_CMD="$QEMU_CMD -global ICH9-LPC.disable_s3=1"
    QEMU_CMD="$QEMU_CMD -global ICH9-LPC.disable_s4=1"

    # macOS-specific devices
    QEMU_CMD="$QEMU_CMD -device isa-applesmc,osk=ourhardworkbythesewordsguardedpleasedontsteal(c)AppleComputerInc"
    QEMU_CMD="$QEMU_CMD -smbios type=2"

    echo "$QEMU_CMD"
}

# ── Main ──────────────────────────────────────────────
echo "[hackintosh] Setting up GPU passthrough..."
setup_gpu_passthrough

echo "[hackintosh] Launching macOS..."
QEMU_CMD=$(build_qemu_cmd)

echo "[hackintosh] QEMU command:"
echo "$QEMU_CMD"
echo ""

# Execute — this takes over the display
exec $QEMU_CMD
