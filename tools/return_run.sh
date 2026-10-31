#!/bin/bash
# Like ktty_run.sh but built so that macOS jumps back into the Linux crash kernel on a panic/reboot (RETURN=1) or when the console
# prints $KTTY_RETURN; then waits for the console to answer on SSH again and pulls the macOS log out of RAM into build/logs/.
# Usage: [CPUS=1] [KTTY_RETURN="DSMOS has arrived"] tools/return_run.sh
set -euo pipefail
cd "$(dirname "$0")/.."
source tools/lib.sh
export RETURN=1
tools/ktty_run.sh
echo "waiting for Linux to come back (up to 3 min)..."
for i in $(seq 1 36); do
    sleep 5
    if ssh -o ConnectTimeout=3 $PS5 true 2>/dev/null; then
        scp -q tools/macos_log.py $PS5:/root/
        ssh $PS5 'python3 /root/macos_log.py /root/macos-log.txt'
        mkdir -p build/logs/macos
        scp -q $PS5:/root/macos-log.txt "build/logs/macos/$(date +%Y%m%d-%H%M%S).txt"
        echo "saved in build/logs/macos/"; exit 0
    fi
done
echo "Linux did not come back"; exit 1
