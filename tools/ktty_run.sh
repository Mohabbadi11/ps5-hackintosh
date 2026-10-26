#!/bin/bash
# Deploys the EFI built with the in-kernel text console (KTTY=1) and launches UEFI. Pick Macintosh HD in the picker: the whole
# kernel log (printf/kprintf) is drawn on the screen.
set -euo pipefail
cd "$(dirname "$0")/.."
OC_DEBUG=1 KTTY=1 python3 tools/make_baremetal_efi.py | head -1
(cd build/baremetal-efi && tar -cf ../baremetal-efi.tar EFI)
scp -q build/baremetal-efi.tar bringup/tools/patch_tripwire.py bringup/tools/run_stage.sh root@192.168.1.200:/root/
ssh root@192.168.1.200 'rm -rf /boot/efi/EFI; tar -C /boot/efi -xf /root/baremetal-efi.tar 2>/dev/null; sync
for p in $(pgrep -x qemu-system-x86); do kill -9 $p; done; systemctl stop hackintosh --no-block; sleep 3
for p in $(pgrep -x stop_qemu.sh); do kill -9 $p; done
nohup bash /root/run_stage.sh /root/chainV5.bzImage /root/ps5-upl.bundle > /root/run_stage.log 2>&1 &'
for i in $(seq 1 30); do sleep 5; ssh -o ConnectTimeout=3 root@192.168.1.200 true 2>/dev/null || { echo "console is in UEFI now"; break; }; done
