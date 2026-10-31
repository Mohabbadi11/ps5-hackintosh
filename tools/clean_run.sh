#!/bin/bash
# Deploys the normal (quiet) EFI: no kernel console blob, no verbose text over the picture. The kernel patches (TSC, APIC IER) and the
# framebuffer-in-BAR0 stage are the same as in ktty_run.sh. Pick Macintosh HD in the picker; the desktop appears on the screen.
#
# Default = the NEW version: cpus=2 and AppleNVMe disabled (never touch the internal SSD). The known-good build of 2026-10-30 (stable desktop,
# one CPU, no NVMe block) is:   NVMEBLOCK=0 CPUS=1 tools/clean_run.sh
# Try more cores step by step: CPUS=2, then 4, 8, 16. Needs Linux up (jailbreak first); then pick "2. Macintosh HD" in the picker.
set -euo pipefail
cd "$(dirname "$0")/.."
export CPUS="${CPUS:-2}"
QUIET=1 OC_DEBUG=1 python3 tools/make_baremetal_efi.py | head -1
python3 tools/make_welcome.py build/welcome.raw >/dev/null
(cd build/baremetal-efi && tar -cf ../baremetal-efi.tar EFI)
scp -q build/baremetal-efi.tar build/ps5-upl.bundle build/bringup/chainV5.bzImage bringup/tools/patch_tripwire.py bringup/tools/run_stage.sh bringup/tools/kms_linear.py build/welcome.raw root@192.168.1.200:/root/
ssh root@192.168.1.200 'rm -rf /boot/efi/EFI; tar -C /boot/efi -xf /root/baremetal-efi.tar 2>/dev/null; sync
for p in $(pgrep -x qemu-system-x86); do kill -9 $p; done; systemctl stop hackintosh --no-block; sleep 3
for p in $(pgrep -x stop_qemu.sh); do kill -9 $p; done
nohup bash /root/run_stage.sh /root/chainV5.bzImage /root/ps5-upl.bundle > /root/run_stage.log 2>&1 &'
for i in $(seq 1 30); do sleep 5; ssh -o ConnectTimeout=3 root@192.168.1.200 true 2>/dev/null || { echo "console is in UEFI now"; break; }; done
