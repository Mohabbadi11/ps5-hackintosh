#!/bin/bash
# Usage: tools/tripwire_run.sh <kernel symbol> [colour AARRGGBB]
# Builds the OpenCore EFI with a tripwire on that XNU symbol and deploys + launches it on the console (Linux up, crash kexec
# available). A red square (bottom right, right of the firmware milestones) then proves the kernel executed that function.
set -euo pipefail
cd "$(dirname "$0")/.."
source tools/lib.sh
OC_DEBUG=1 TRIPWIRE="$1=${2:-FFFF0000}" python3 tools/make_baremetal_efi.py | head -1
(cd build/baremetal-efi && tar -cf ../baremetal-efi.tar EFI)
scp -q build/baremetal-efi.tar $PS5:/root/
ssh $PS5 'rm -rf /boot/efi/EFI; tar -C /boot/efi -xf /root/baremetal-efi.tar 2>/dev/null; sync
for p in $(pgrep -x qemu-system-x86); do kill -9 $p; done; systemctl stop hackintosh --no-block; sleep 3
for p in $(pgrep -x stop_qemu.sh); do kill -9 $p; done
nohup bash /root/run_stage.sh /root/chainV5.bzImage /root/ps5-upl.bundle > /root/run_stage.log 2>&1 &'
for i in $(seq 1 20); do sleep 5; ssh -o ConnectTimeout=3 $PS5 true 2>/dev/null || { echo "console is in UEFI now (ssh down after ~$((i*5))s)"; break; }; done
