#!/bin/bash
#
# Run on the PS5 (as root, main kernel with crashkernel=400M): put the linear test framebuffer on screen, load a stage-1
# chain image as the crash kernel (optionally with a bundle as its initrd) and crash into it.
#
# Usage: run_stage.sh /root/chainV5.bzImage [/root/ps5-upl.bundle]
set -euo pipefail
IMG="${1:?chain bzImage}"
BUNDLE="${2:-}"

systemctl stop hackintosh 2>/dev/null || true
pkill -u ps5 sway || true
sleep 2
nohup python3 /root/kms_linear.py >/root/kms.log 2>&1 &
# wait for the picture to be on screen (a few seconds with the prepared welcome screen), not a fixed time
for i in $(seq 1 400); do grep -q "SETCRTC done" /root/kms.log 2>/dev/null && break; sleep 0.5; done
sleep 1
tail -1 /root/kms.log
# a tripwire kernel patch in the OpenCore config needs this boot's framebuffer offset
[ -f /root/patch_tripwire.py ] && python3 /root/patch_tripwire.py /boot/efi/EFI/OC/config.plist || true

python3 - "$IMG" "$BUNDLE" <<'PY'
import ctypes, os, sys
libc = ctypes.CDLL(None, use_errno=True)
kfd = os.open(sys.argv[1], os.O_RDONLY)
cmd = b"root=/dev/sda1 rw rootwait console=tty0 mitigations=off idle=halt nr_cpus=1 module_blacklist=amdgpu systemd.mask=hackintosh.service systemd.unit=multi-user.target\0"
if sys.argv[2]:
    ifd, flags = os.open(sys.argv[2], os.O_RDONLY), 2          # KEXEC_FILE_ON_CRASH
else:
    ifd, flags = -1, 6                                          # ON_CRASH | NO_INITRAMFS
r = libc.syscall(320, kfd, ifd, len(cmd), cmd, flags)
print("kexec_file_load:", r, os.strerror(ctypes.get_errno()), "crash_loaded:", open("/sys/kernel/kexec_crash_loaded").read().strip())
PY
sync
echo 1 > /proc/sys/kernel/sysrq
# the CPU that takes the crash becomes the one running UEFI and macOS: it has to be the boot processor (CPU 0), because XNU
# panics with "Unexpected local APIC state" in lapic_init() on any other core (IA32_APIC_BASE.BSP clear)
# Sony's GbE (104d:9104) keeps its DMA rings armed through a crash and the IOMMU is switched off afterwards: its ring addresses would
# become physical addresses inside macOS' memory. Linux's mts driver stops both DMA engines on "ip link set down" (this ends the ssh session).
nohup taskset -c 0 sh -c 'sleep 1; for n in /sys/class/net/*; do [ "$(cat $n/device/vendor 2>/dev/null)" = 0x104d ] && ip link set "${n##*/}" down; done; echo c > /proc/sysrq-trigger' >/dev/null 2>&1 &
echo "crashing into the stage in 1 s"
