#!/bin/bash
#
# PS5 Hackintosh — Gracefully stop the macOS VM
#
# 1. Asks macOS to shut down over SSH (QEMU forwards host :2222 -> guest :22).
#    Needs /mnt/macos/guest.conf with GUEST_USER=<macOS user>, the key
#    /root/.ssh/hackintosh_guest authorized in that account, and passwordless
#    sudo for /sbin/shutdown (see tools/setup_guest_shutdown.md).
# 2. Falls back to the ACPI power button (macOS usually ignores it).
# 3. Waits for the guest to halt, then quits QEMU. QEMU does not exit on its
#    own when macOS halts, so the vCPUs would otherwise spin forever.

SOCK="/tmp/qemu-monitor.sock"
SERIAL="/mnt/macos/serial.log"
GUEST_CONF="/mnt/macos/guest.conf"
GUEST_KEY="/root/.ssh/hackintosh_guest"
TIMEOUT="${1:-90}"

[ -S "$SOCK" ] || { echo "[hackintosh] VM is not running"; exit 0; }

mon() {
    python3 - "$1" <<'EOF'
import socket, sys, time
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.settimeout(2)
s.connect("/tmp/qemu-monitor.sock")
time.sleep(0.3)
try: s.recv(65536)
except Exception: pass
s.sendall((sys.argv[1] + "\n").encode())
time.sleep(0.5)
s.close()
EOF
}

START=$(wc -c < "$SERIAL" 2>/dev/null || echo 0)
REQUESTED=false

if [ -r "$GUEST_CONF" ] && [ -f "$GUEST_KEY" ]; then
    # shellcheck disable=SC1090
    . "$GUEST_CONF"
    echo "[hackintosh] Asking macOS to shut down over SSH..."
    # ssh exits non-zero when the guest drops the connection while shutting
    # down, so judge success by shutdown's own "Shutdown NOW!" banner.
    OUT=$(ssh -i "$GUEST_KEY" -p 2222 -o BatchMode=yes -o ConnectTimeout=5 \
              -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
              "$GUEST_USER@127.0.0.1" "sudo -n /sbin/shutdown -h now" 2>&1)
    if [ $? -eq 0 ] || echo "$OUT" | grep -q "Shutdown NOW"; then
        REQUESTED=true
    else
        echo "[hackintosh] SSH shutdown failed: $OUT"
    fi
fi

if [ "$REQUESTED" = false ]; then
    echo "[hackintosh] Falling back to the ACPI power button..."
    mon system_powerdown
fi

HALTED=false
for _ in $(seq 1 "$TIMEOUT"); do
    if tail -c +"$((START + 1))" "$SERIAL" 2>/dev/null | grep -a -q "CPU halted"; then
        HALTED=true
        echo "[hackintosh] macOS halted cleanly"
        break
    fi
    [ -S "$SOCK" ] || break   # QEMU already exited on its own
    sleep 1
done

# QEMU usually exits by itself after a guest-initiated shutdown
sleep 3
if [ -S "$SOCK" ]; then
    [ "$HALTED" = true ] || echo "[hackintosh] WARNING: macOS did not halt; forcing QEMU to quit"
    mon quit
fi
exit 0
