#!/bin/bash
# Waits for the console to listen for payloads (jailbreak done, port 9021 open) and sends the Linux loader, then waits for Linux to answer on ssh.
# Leave it running in a terminal while you power-cycle and jailbreak: it retries until Linux is up, and does nothing while Linux is already up.
#   needs PS5_HOST (the console while it listens for payloads) and PS5_LINUX_HOST in .env; the ELF is build/bin/ps5-linux-loader.elf (or $1).
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
[ -f "$ROOT/.env" ] && { set -a; . "$ROOT/.env"; set +a; }
: "${PS5_HOST:?set PS5_HOST in .env}" "${PS5_LINUX_HOST:?set PS5_LINUX_HOST in .env}"
ELF="${1:-$ROOT/build/bin/ps5-linux-loader.elf}"
[ -f "$ELF" ] || { echo "no loader ELF at $ELF (make loader)"; exit 1; }
linux_up() { nc -z -w 3 "$PS5_LINUX_HOST" 22 2>/dev/null; }
while true; do
    if linux_up; then echo "$(date +%T) Linux is up on $PS5_LINUX_HOST"; exit 0; fi
    if nc -z -w 3 "$PS5_HOST" 9021 2>/dev/null; then
        echo "$(date +%T) port 9021 is open on $PS5_HOST: sending $(basename "$ELF")"
        nc -w 20 "$PS5_HOST" 9021 < "$ELF"
        echo "$(date +%T) sent; the console goes to rest mode, wake it up (power button) when its light stops blinking"
        for i in $(seq 1 36); do linux_up && break; sleep 5; done        # up to 3 minutes before trying again
    else
        echo "$(date +%T) waiting for the jailbreak (9021 closed)..."
        sleep 5
    fi
done
