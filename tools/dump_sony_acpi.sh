#!/bin/bash
# Fetches the console's own MADT (ACPI table APIC) from the running Linux into opencore/ACPI/sony/APIC.bin, which tools/make_madt.py extends with a fake
# I/O APIC. It is Sony's firmware table, so it is not tracked in the repo: each user dumps their own. Needs Linux up on the console (ssh, see .env).
set -euo pipefail
cd "$(dirname "$0")/.."
source tools/lib.sh
mkdir -p opencore/ACPI/sony
tmp="$(mktemp)"
ssh "$PS5" 'cat /sys/firmware/acpi/tables/APIC' > "$tmp"
python3 - "$tmp" <<'PY'
import struct, sys
d = open(sys.argv[1], "rb").read()
if len(d) < 44 or d[:4] != b"APIC" or struct.unpack("<I", d[4:8])[0] != len(d):
    sys.exit(f"that is not a valid MADT ({len(d)} bytes, signature {d[:4]!r})")
print(f"MADT: {len(d)} bytes, OEM {d[10:16].decode('latin1').strip()!r}")
PY
mv "$tmp" opencore/ACPI/sony/APIC.bin
echo "wrote opencore/ACPI/sony/APIC.bin"
