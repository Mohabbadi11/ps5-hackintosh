#!/bin/sh
#
# PS5 Hackintosh — QEMU/KVM macOS boot
#
# Runs as PID 1 after switch_root (rootfs mode)
# or invoked from init (embedded mode).
#
# Rootfs mode: auto-detects USB partition with macos/
# Embedded mode: receives paths as arguments

export PATH=/bin:/sbin:/usr/bin:/usr/sbin

# ── Mount filesystems if we are PID 1 ───────────────
if [ $$ -eq 1 ]; then
    mount -t proc proc /proc 2>/dev/null
    mount -t sysfs sysfs /sys 2>/dev/null
    mount -t devtmpfs devtmpfs /dev 2>/dev/null
    mkdir -p /dev/pts /dev/shm /tmp /mnt/macos /dev/hugepages
    mount -t devpts devpts /dev/pts 2>/dev/null
    mount -t tmpfs tmpfs /dev/shm 2>/dev/null
    mount -t tmpfs tmpfs /tmp 2>/dev/null
    mount -t hugetlbfs hugetlbfs /dev/hugepages 2>/dev/null

    echo ""
    echo " ╔══════════════════════════════════════════════╗"
    echo " ║         PS5 Hackintosh — macOS Boot          ║"
    echo " ╚══════════════════════════════════════════════╝"
    echo ""
fi

# ── Load kernel modules ──────────────────────────────
echo "[hackintosh] Loading KVM/VFIO modules..."
for mod in kvm kvm_amd vfio vfio_pci vfio_iommu_type1 loop; do
    modprobe -q $mod 2>/dev/null
done

# ── Configure hugepages ──────────────────────────────
echo "[hackintosh] Configuring hugepages..."
echo 4096 > /proc/sys/vm/nr_hugepages 2>/dev/null

# ── Find USB partition with macos/ ───────────────────
MACOS_IMG="${1:-}"
OVMF_CODE="${2:-}"
OVMF_VARS="${3:-}"
OC_IMG="${4:-}"
USB_MNT="/mnt/macos"

if [ -z "$MACOS_IMG" ]; then
    echo "[hackintosh] Scanning for USB with macOS data..."

    for dev in /dev/sd[a-z]1 /dev/sd[a-z]3 /dev/sd[a-z]2 /dev/sd[a-z]; do
        [ -b "$dev" ] || continue
        for fs in vfat exfat ext4; do
            if mount -t $fs "$dev" "$USB_MNT" 2>/dev/null; then
                if [ -d "$USB_MNT/macos" ]; then
                    echo "[hackintosh] USB found: $dev ($fs)"
                    break 2
                fi
                umount "$USB_MNT" 2>/dev/null
            fi
        done
    done

    if [ ! -d "$USB_MNT/macos" ]; then
        echo "[hackintosh] ERROR: No USB found with macos/ directory"
        echo ""
        echo "  The USB drive needs a macos/ directory containing:"
        echo "    - macOS.img     (macOS virtual disk)"
        echo "    - OVMF_CODE.fd  (UEFI firmware)"
        echo "    - OpenCore.img  (OpenCore EFI disk)"
        echo ""
        [ $$ -eq 1 ] && exec /bin/sh
        exit 1
    fi

    MACOS_IMG="$USB_MNT/macos/macOS.img"
    OC_IMG="$USB_MNT/macos/OpenCore.img"

    # OVMF: check USB first, then Alpine system
    if [ -f "$USB_MNT/macos/OVMF_CODE.fd" ]; then
        OVMF_CODE="$USB_MNT/macos/OVMF_CODE.fd"
    elif [ -f /usr/share/OVMF/OVMF_CODE.fd ]; then
        OVMF_CODE="/usr/share/OVMF/OVMF_CODE.fd"
        echo "[hackintosh] Using system OVMF"
    fi

    # OVMF_VARS: mutable copy (QEMU writes to it)
    OVMF_VARS="/tmp/OVMF_VARS.fd"
    if [ -f "$USB_MNT/macos/OVMF_VARS.fd" ]; then
        cp "$USB_MNT/macos/OVMF_VARS.fd" "$OVMF_VARS"
    elif [ -f /usr/share/OVMF/OVMF_VARS.fd ]; then
        cp /usr/share/OVMF/OVMF_VARS.fd "$OVMF_VARS"
    fi
fi

# ── Verify required files ────────────────────────────
echo "[hackintosh] Verifying files..."
MISSING=""
[ ! -f "$MACOS_IMG" ]  && MISSING="$MISSING macOS.img"
[ ! -f "$OVMF_CODE" ]  && MISSING="$MISSING OVMF_CODE.fd"

if [ -n "$MISSING" ]; then
    echo "[hackintosh] ERROR: Missing files:$MISSING"
    [ $$ -eq 1 ] && exec /bin/sh
    exit 1
fi

echo "[hackintosh] macOS.img: $(du -h "$MACOS_IMG" 2>/dev/null | cut -f1)"
echo "[hackintosh] OVMF: $OVMF_CODE"
[ -f "$OC_IMG" ] && echo "[hackintosh] OpenCore: $OC_IMG"

# Create OVMF_VARS copy if not done (embedded mode)
if [ ! -f "$OVMF_VARS" ] && [ -f "$OVMF_CODE" ]; then
    cp "$OVMF_CODE" "$OVMF_VARS" 2>/dev/null
fi

# ── CPU topology ─────────────────────────────────────
# Total vCPUs must be a power of 2 (2 threads per core): macOS libmalloc
# aborts launchd unless logical/physical CPUs is 1, 2 or 4. PS5: 8C/16T.
HOST_THREADS=$(grep -c ^processor /proc/cpuinfo)
CPUS=16
while [ "$CPUS" -gt "$HOST_THREADS" ] && [ "$CPUS" -gt 2 ]; do CPUS=$((CPUS / 2)); done
THREADS=2
CORES=$((CPUS / THREADS))
SOCKETS=1
MEM="12G"

# ── GPU passthrough ──────────────────────────────────
GPU_PCI=""
GPU_AUDIO_PCI=""

echo "[hackintosh] Configuring GPU passthrough..."

for dev in /sys/bus/pci/devices/*/; do
    vendor=$(cat "$dev/vendor" 2>/dev/null)
    class=$(cat "$dev/class" 2>/dev/null)
    if [ "$vendor" = "0x1002" ] && [ "${class%??}" = "0x0300" ]; then
        GPU_PCI=$(basename "$dev")
        echo "[hackintosh] GPU found: $GPU_PCI"
        break
    fi
done

if [ -n "$GPU_PCI" ]; then
    gpu_base="${GPU_PCI%.*}"
    for dev in /sys/bus/pci/devices/${gpu_base}.*/; do
        class=$(cat "$dev/class" 2>/dev/null)
        if [ "${class%??}" = "0x0403" ]; then
            GPU_AUDIO_PCI=$(basename "$dev")
            echo "[hackintosh] GPU audio: $GPU_AUDIO_PCI"
            break
        fi
    done

    echo "[hackintosh] Binding GPU to vfio-pci..."
    echo "$GPU_PCI" > /sys/bus/pci/devices/$GPU_PCI/driver/unbind 2>/dev/null || true
    echo "vfio-pci" > /sys/bus/pci/devices/$GPU_PCI/driver_override
    echo "$GPU_PCI" > /sys/bus/pci/drivers/vfio-pci/bind 2>/dev/null || true

    if [ -n "$GPU_AUDIO_PCI" ]; then
        echo "$GPU_AUDIO_PCI" > /sys/bus/pci/devices/$GPU_AUDIO_PCI/driver/unbind 2>/dev/null || true
        echo "vfio-pci" > /sys/bus/pci/devices/$GPU_AUDIO_PCI/driver_override
        echo "$GPU_AUDIO_PCI" > /sys/bus/pci/drivers/vfio-pci/bind 2>/dev/null || true
    fi
fi

# ── DualSense -> mouse/keyboard ─────────────────────
DS_MOUSE_EVDEV=""
DS_KBD_EVDEV=""

if [ -x /hackintosh/ds-mouse ]; then
    modprobe -q uinput 2>/dev/null
    echo "[hackintosh] Starting DualSense mapper..."
    /hackintosh/ds-mouse &
    DS_PID=$!
    sleep 1

    if [ -f /tmp/ds-mouse.env ]; then
        . /tmp/ds-mouse.env
        echo "[hackintosh] DualSense mapped as mouse + keyboard"
    else
        echo "[hackintosh] WARNING: ds-mouse did not create devices"
    fi
else
    echo "[hackintosh] ds-mouse not found — DualSense will pass through as gamepad"
fi

# ── Launch QEMU ──────────────────────────────────────
echo ""
echo "[hackintosh] Launching macOS with QEMU/KVM..."
echo ""

QEMU_ARGS=""
QEMU_ARGS="$QEMU_ARGS -enable-kvm"
QEMU_ARGS="$QEMU_ARGS -machine q35,accel=kvm,kernel_irqchip=on"
QEMU_ARGS="$QEMU_ARGS -cpu host,vendor=GenuineIntel,+invtsc,+ssse3,+sse4.2,+popcnt,+avx,+aes,+xsave,+xsaveopt,kvm=off,vmware-cpuid-freq=on"
QEMU_ARGS="$QEMU_ARGS -smp cpus=$CPUS,cores=$CORES,threads=$THREADS,sockets=$SOCKETS"
QEMU_ARGS="$QEMU_ARGS -m $MEM"
QEMU_ARGS="$QEMU_ARGS -mem-prealloc"
QEMU_ARGS="$QEMU_ARGS -mem-path /dev/hugepages"

# UEFI firmware
QEMU_ARGS="$QEMU_ARGS -drive if=pflash,format=raw,readonly=on,file=$OVMF_CODE"
[ -f "$OVMF_VARS" ] && QEMU_ARGS="$QEMU_ARGS -drive if=pflash,format=raw,file=$OVMF_VARS"

# OpenCore (boot disk)
if [ -f "$OC_IMG" ]; then
    QEMU_ARGS="$QEMU_ARGS -drive id=OpenCore,if=none,format=qcow2,file=$OC_IMG"
    QEMU_ARGS="$QEMU_ARGS -device virtio-blk-pci,drive=OpenCore,bootindex=1"
fi

# macOS disk — detect format (qcow2 or raw)
MACOS_FMT="raw"
if command -v qemu-img >/dev/null 2>&1; then
    detected=$(qemu-img info --output=json "$MACOS_IMG" 2>/dev/null | grep -o '"format": *"[^"]*"' | head -1 | sed 's/.*"format": *"//;s/"//')
    [ -n "$detected" ] && MACOS_FMT="$detected"
elif head -c 4 "$MACOS_IMG" 2>/dev/null | grep -q "QFI"; then
    MACOS_FMT="qcow2"
fi
echo "[hackintosh] macOS.img format: $MACOS_FMT"
QEMU_ARGS="$QEMU_ARGS -drive id=MacOS,if=none,format=$MACOS_FMT,file=$MACOS_IMG,cache=writeback,aio=threads"
QEMU_ARGS="$QEMU_ARGS -device virtio-blk-pci,drive=MacOS"

# GPU
if [ -n "$GPU_PCI" ]; then
    QEMU_ARGS="$QEMU_ARGS -device vfio-pci,host=$GPU_PCI,multifunction=on,x-vga=on,rombar=0"
    [ -n "$GPU_AUDIO_PCI" ] && QEMU_ARGS="$QEMU_ARGS -device vfio-pci,host=$GPU_AUDIO_PCI"
    QEMU_ARGS="$QEMU_ARGS -nographic -vga none"
else
    echo "[hackintosh] WARNING: No GPU passthrough — using virtio-vga"
    QEMU_ARGS="$QEMU_ARGS -device virtio-vga"
fi

# Network
QEMU_ARGS="$QEMU_ARGS -netdev user,id=net0,hostfwd=tcp::2222-:22"
QEMU_ARGS="$QEMU_ARGS -device virtio-net-pci,netdev=net0"

# USB
QEMU_ARGS="$QEMU_ARGS -usb"
QEMU_ARGS="$QEMU_ARGS -device qemu-xhci,id=xhci"

# Virtual input devices (QEMU's own USB tablet/kbd, fed by input-linux)
QEMU_ARGS="$QEMU_ARGS -device usb-kbd"
QEMU_ARGS="$QEMU_ARGS -device usb-tablet"

# DualSense mapped input -> QEMU via input-linux
if [ -n "$DS_MOUSE_EVDEV" ] && [ -e "$DS_MOUSE_EVDEV" ]; then
    QEMU_ARGS="$QEMU_ARGS -object input-linux,id=dsmouse,evdev=$DS_MOUSE_EVDEV"
fi
if [ -n "$DS_KBD_EVDEV" ] && [ -e "$DS_KBD_EVDEV" ]; then
    QEMU_ARGS="$QEMU_ARGS -object input-linux,id=dskbd,evdev=$DS_KBD_EVDEV"
fi

# Pass through non-DualSense USB HID devices (keyboards, mice)
for usbdev in /sys/bus/usb/devices/*/bInterfaceClass; do
    class=$(cat "$usbdev" 2>/dev/null)
    if [ "$class" = "03" ]; then
        busdir=$(dirname "$usbdev")
        vendor=$(cat "$busdir/../idVendor" 2>/dev/null)
        product=$(cat "$busdir/../idProduct" 2>/dev/null)
        [ -z "$vendor" ] || [ -z "$product" ] && continue
        # Skip DualSense (Sony 054c:0ce6 / 054c:0df2) — handled by ds-mouse
        [ "$vendor" = "054c" ] && continue
        QEMU_ARGS="$QEMU_ARGS -device usb-host,vendorid=0x$vendor,productid=0x$product"
    fi
done

# Audio
QEMU_ARGS="$QEMU_ARGS -device intel-hda"
QEMU_ARGS="$QEMU_ARGS -device hda-duplex"

# macOS specifics
QEMU_ARGS="$QEMU_ARGS -rtc base=localtime,driftfix=slew"
QEMU_ARGS="$QEMU_ARGS -global ICH9-LPC.disable_s3=1"
QEMU_ARGS="$QEMU_ARGS -global ICH9-LPC.disable_s4=1"
QEMU_ARGS="$QEMU_ARGS -device isa-applesmc,osk=ourhardworkbythesewordsguardedpleasedontsteal(c)AppleComputerInc"
QEMU_ARGS="$QEMU_ARGS -smbios type=2"

echo "[hackintosh] QEMU ready — launching..."
exec qemu-system-x86_64 $QEMU_ARGS
