#!/bin/bash
# Fetches the console's own MADT (ACPI table APIC) from the running Linux into opencore/ACPI/sony/APIC.bin, which tools/make_madt.py extends with a fake
# I/O APIC. It is Sony's firmware table, so it is not tracked in the repo: each user dumps their own. Needs Linux up on the console (ssh, see .env).
# This Linux has no /sys/firmware/acpi: the tables are read from physical memory (/dev/mem), starting at the RSDP address that dmesg prints.
set -euo pipefail
cd "$(dirname "$0")/.."
source tools/lib.sh
mkdir -p opencore/ACPI/sony
tmp="$(mktemp)"
ssh "$PS5" python3 - > "$tmp" <<'PY'
import os, re, struct, subprocess, sys
m = re.search(r"ACPI: RSDP 0x([0-9A-Fa-f]+)", subprocess.run(["dmesg"], capture_output=True, text=True).stdout)
if not m:
    sys.exit("no 'ACPI: RSDP' line in dmesg")
fd = os.open("/dev/mem", os.O_RDONLY)
rd = lambda a, n: os.pread(fd, n, a)
rsdp = rd(int(m.group(1), 16), 36)
xsdt = struct.unpack_from("<Q", rsdp, 24)[0]
ln = struct.unpack_from("<I", rd(xsdt, 36), 4)[0]
x = rd(xsdt, ln)
for i in range((ln - 36) // 8):
    p = struct.unpack_from("<Q", x, 36 + 8 * i)[0]
    h = rd(p, 36)
    if h[:4] == b"APIC":
        sys.stdout.buffer.write(rd(p, struct.unpack_from("<I", h, 4)[0]))
        break
else:
    sys.exit("no APIC table in the XSDT")
PY
python3 - "$tmp" <<'PY'
import struct, sys
d = open(sys.argv[1], "rb").read()
if len(d) < 44 or d[:4] != b"APIC" or struct.unpack("<I", d[4:8])[0] != len(d):
    sys.exit(f"that is not a valid MADT ({len(d)} bytes, signature {d[:4]!r})")
print(f"MADT: {len(d)} bytes, OEM {d[10:16].decode('latin1').strip()!r}")
PY
mv "$tmp" opencore/ACPI/sony/APIC.bin
echo "wrote opencore/ACPI/sony/APIC.bin"
