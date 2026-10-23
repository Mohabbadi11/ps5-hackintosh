#!/bin/sh
#
# PS5 Hackintosh — QEMU/KVM macOS boot
#
# Se ejecuta como PID 1 después de switch_root (modo rootfs)
# o invocado desde init (modo embebido).
#
# Modo rootfs: busca automáticamente la partición USB con macos/
# Modo embebido: recibe rutas como argumentos

export PATH=/bin:/sbin:/usr/bin:/usr/sbin

# ── Montar filesystems si somos PID 1 ────────────────
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

# ── Cargar módulos ────────────────────────────────────
echo "[hackintosh] Cargando módulos KVM/VFIO..."
for mod in kvm kvm_amd vfio vfio_pci vfio_iommu_type1 loop; do
    modprobe -q $mod 2>/dev/null
done

# ── Configurar hugepages ──────────────────────────────
echo "[hackintosh] Configurando hugepages..."
echo 4096 > /proc/sys/vm/nr_hugepages 2>/dev/null

# ── Buscar partición USB con macos/ ───────────────────
MACOS_IMG="${1:-}"
OVMF_CODE="${2:-}"
OVMF_VARS="${3:-}"
OC_IMG="${4:-}"
USB_MNT="/mnt/macos"

if [ -z "$MACOS_IMG" ]; then
    echo "[hackintosh] Buscando USB con datos de macOS..."

    for dev in /dev/sd[a-z]1 /dev/sd[a-z]3 /dev/sd[a-z]2 /dev/sd[a-z]; do
        [ -b "$dev" ] || continue
        for fs in vfat exfat ext4; do
            if mount -t $fs "$dev" "$USB_MNT" 2>/dev/null; then
                if [ -d "$USB_MNT/macos" ]; then
                    echo "[hackintosh] USB encontrado: $dev ($fs)"
                    break 2
                fi
                umount "$USB_MNT" 2>/dev/null
            fi
        done
    done

    if [ ! -d "$USB_MNT/macos" ]; then
        echo "[hackintosh] ERROR: No se encontró USB con directorio macos/"
        echo ""
        echo "  El USB necesita un directorio macos/ con:"
        echo "    - macOS.img     (disco virtual macOS)"
        echo "    - OVMF_CODE.fd  (firmware UEFI)"
        echo "    - OpenCore.img  (disco EFI de OpenCore)"
        echo ""
        [ $$ -eq 1 ] && exec /bin/sh
        exit 1
    fi

    MACOS_IMG="$USB_MNT/macos/macOS.img"
    OC_IMG="$USB_MNT/macos/OpenCore.img"

    # OVMF: buscar en USB, luego en sistema Alpine
    if [ -f "$USB_MNT/macos/OVMF_CODE.fd" ]; then
        OVMF_CODE="$USB_MNT/macos/OVMF_CODE.fd"
    elif [ -f /usr/share/OVMF/OVMF_CODE.fd ]; then
        OVMF_CODE="/usr/share/OVMF/OVMF_CODE.fd"
        echo "[hackintosh] Usando OVMF del sistema"
    fi

    # OVMF_VARS: copia mutable (QEMU escribe en él)
    OVMF_VARS="/tmp/OVMF_VARS.fd"
    if [ -f "$USB_MNT/macos/OVMF_VARS.fd" ]; then
        cp "$USB_MNT/macos/OVMF_VARS.fd" "$OVMF_VARS"
    elif [ -f /usr/share/OVMF/OVMF_VARS.fd ]; then
        cp /usr/share/OVMF/OVMF_VARS.fd "$OVMF_VARS"
    fi
fi

# ── Verificar archivos necesarios ─────────────────────
echo "[hackintosh] Verificando archivos..."
MISSING=""
[ ! -f "$MACOS_IMG" ]  && MISSING="$MISSING macOS.img"
[ ! -f "$OVMF_CODE" ]  && MISSING="$MISSING OVMF_CODE.fd"

if [ -n "$MISSING" ]; then
    echo "[hackintosh] ERROR: Archivos faltantes:$MISSING"
    [ $$ -eq 1 ] && exec /bin/sh
    exit 1
fi

echo "[hackintosh] macOS.img: $(du -h "$MACOS_IMG" 2>/dev/null | cut -f1)"
echo "[hackintosh] OVMF: $OVMF_CODE"
[ -f "$OC_IMG" ] && echo "[hackintosh] OpenCore: $OC_IMG"

# Crear copia de OVMF_VARS si no se hizo antes (modo embebido)
if [ ! -f "$OVMF_VARS" ] && [ -f "$OVMF_CODE" ]; then
    cp "$OVMF_CODE" "$OVMF_VARS" 2>/dev/null
fi

# ── CPU topology ──────────────────────────────────────
# PS5: 8 cores / 16 threads — dar a macOS 6 cores / 12 threads
CPUS=12
CORES=6
THREADS=2
SOCKETS=1
MEM="12G"

# ── GPU passthrough ───────────────────────────────────
GPU_PCI=""
GPU_AUDIO_PCI=""

echo "[hackintosh] Configurando GPU passthrough..."

for dev in /sys/bus/pci/devices/*/; do
    vendor=$(cat "$dev/vendor" 2>/dev/null)
    class=$(cat "$dev/class" 2>/dev/null)
    if [ "$vendor" = "0x1002" ] && [ "${class%??}" = "0x0300" ]; then
        GPU_PCI=$(basename "$dev")
        echo "[hackintosh] GPU encontrada: $GPU_PCI"
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

    echo "[hackintosh] Enlazando GPU a vfio-pci..."
    echo "$GPU_PCI" > /sys/bus/pci/devices/$GPU_PCI/driver/unbind 2>/dev/null || true
    echo "vfio-pci" > /sys/bus/pci/devices/$GPU_PCI/driver_override
    echo "$GPU_PCI" > /sys/bus/pci/drivers/vfio-pci/bind 2>/dev/null || true

    if [ -n "$GPU_AUDIO_PCI" ]; then
        echo "$GPU_AUDIO_PCI" > /sys/bus/pci/devices/$GPU_AUDIO_PCI/driver/unbind 2>/dev/null || true
        echo "vfio-pci" > /sys/bus/pci/devices/$GPU_AUDIO_PCI/driver_override
        echo "$GPU_AUDIO_PCI" > /sys/bus/pci/drivers/vfio-pci/bind 2>/dev/null || true
    fi
fi

# ── DualSense → ratón/teclado ────────────────────────
DS_MOUSE_EVDEV=""
DS_KBD_EVDEV=""

if [ -x /hackintosh/ds-mouse ]; then
    modprobe -q uinput 2>/dev/null
    echo "[hackintosh] Iniciando mapper DualSense..."
    /hackintosh/ds-mouse &
    DS_PID=$!
    sleep 1

    if [ -f /tmp/ds-mouse.env ]; then
        . /tmp/ds-mouse.env
        echo "[hackintosh] DualSense mapeado como ratón + teclado"
    else
        echo "[hackintosh] AVISO: ds-mouse no creó dispositivos"
    fi
else
    echo "[hackintosh] ds-mouse no encontrado — DualSense pasará como gamepad"
fi

# ── Lanzar QEMU ──────────────────────────────────────
echo ""
echo "[hackintosh] Lanzando macOS con QEMU/KVM..."
echo ""

QEMU_ARGS=""
QEMU_ARGS="$QEMU_ARGS -enable-kvm"
QEMU_ARGS="$QEMU_ARGS -machine q35,accel=kvm,kernel_irqchip=on"
QEMU_ARGS="$QEMU_ARGS -cpu host,vendor=AuthenticAMD,+ssse3,+sse4.2,+popcnt,+avx,+aes,+xsave,+xsaveopt,topoext=on,kvm=off"
QEMU_ARGS="$QEMU_ARGS -smp cpus=$CPUS,cores=$CORES,threads=$THREADS,sockets=$SOCKETS"
QEMU_ARGS="$QEMU_ARGS -m $MEM"
QEMU_ARGS="$QEMU_ARGS -mem-prealloc"
QEMU_ARGS="$QEMU_ARGS -mem-path /dev/hugepages"

# UEFI firmware
QEMU_ARGS="$QEMU_ARGS -drive if=pflash,format=raw,readonly=on,file=$OVMF_CODE"
[ -f "$OVMF_VARS" ] && QEMU_ARGS="$QEMU_ARGS -drive if=pflash,format=raw,file=$OVMF_VARS"

# OpenCore (disco de arranque)
if [ -f "$OC_IMG" ]; then
    QEMU_ARGS="$QEMU_ARGS -drive id=OpenCore,if=none,format=qcow2,file=$OC_IMG"
    QEMU_ARGS="$QEMU_ARGS -device virtio-blk-pci,drive=OpenCore,bootindex=1"
fi

# macOS disk — detectar formato (qcow2 o raw)
MACOS_FMT="raw"
if command -v qemu-img >/dev/null 2>&1; then
    detected=$(qemu-img info --output=json "$MACOS_IMG" 2>/dev/null | grep -o '"format": *"[^"]*"' | head -1 | sed 's/.*"format": *"//;s/"//')
    [ -n "$detected" ] && MACOS_FMT="$detected"
elif head -c 4 "$MACOS_IMG" 2>/dev/null | grep -q "QFI"; then
    MACOS_FMT="qcow2"
fi
echo "[hackintosh] macOS.img formato: $MACOS_FMT"
QEMU_ARGS="$QEMU_ARGS -drive id=MacOS,if=none,format=$MACOS_FMT,file=$MACOS_IMG,cache=writeback,aio=threads"
QEMU_ARGS="$QEMU_ARGS -device virtio-blk-pci,drive=MacOS"

# GPU
if [ -n "$GPU_PCI" ]; then
    QEMU_ARGS="$QEMU_ARGS -device vfio-pci,host=$GPU_PCI,multifunction=on,x-vga=on,rombar=0"
    [ -n "$GPU_AUDIO_PCI" ] && QEMU_ARGS="$QEMU_ARGS -device vfio-pci,host=$GPU_AUDIO_PCI"
    QEMU_ARGS="$QEMU_ARGS -nographic -vga none"
else
    echo "[hackintosh] AVISO: Sin GPU passthrough — usando virtio-vga"
    QEMU_ARGS="$QEMU_ARGS -device virtio-vga"
fi

# Red
QEMU_ARGS="$QEMU_ARGS -netdev user,id=net0,hostfwd=tcp::2222-:22"
QEMU_ARGS="$QEMU_ARGS -device virtio-net-pci,netdev=net0"

# USB
QEMU_ARGS="$QEMU_ARGS -usb"
QEMU_ARGS="$QEMU_ARGS -device qemu-xhci,id=xhci"

# Virtual input devices (QEMU's own USB tablet/kbd, fed by input-linux)
QEMU_ARGS="$QEMU_ARGS -device usb-kbd"
QEMU_ARGS="$QEMU_ARGS -device usb-tablet"

# DualSense mapped input → QEMU via input-linux
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

echo "[hackintosh] QEMU listo — ejecutando..."
exec qemu-system-x86_64 $QEMU_ARGS
