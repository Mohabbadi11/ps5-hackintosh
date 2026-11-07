#!/usr/bin/env python3
"""Sony's MADT (opencore/ACPI/sony/APIC.bin, dumped from physical memory 0x7fd8b000) plus one I/O APIC entry pointing at the fake
register page the UEFI bundle loads (uefi/mkbundle.py IOAPIC_PAGE). Usage: make_madt.py out.aml"""
import os, struct, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
IOAPIC_PAGE = 0x7fd70000
# ACPI 6.x MADT entry sizes (type: bytes); 0 = processor local APIC, whose APIC id (+3) and flags (+4..+7) are read and written below
MIN_LEN = {0: 8, 1: 12, 2: 10, 3: 8, 4: 6, 5: 12, 9: 16, 10: 12}

def build():
    apic = ROOT / "opencore/ACPI/sony/APIC.bin"
    if not apic.exists():
        sys.exit("missing opencore/ACPI/sony/APIC.bin, the console's own MADT (not tracked): with Linux up on the console run tools/dump_sony_acpi.sh")
    t = bytearray(apic.read_bytes())
    if len(t) < 44 or t[:4] != b"APIC" or struct.unpack_from("<I", t, 4)[0] != len(t):
        sys.exit(f"APIC.bin is not a whole MADT ({len(t)} bytes, signature {bytes(t[:4])!r}); dump it again (tools/dump_sony_acpi.sh)")
    # DISABLE_LAPIC=8,9: mark those local APIC ids as not enabled (processor local APIC entries: type 0, flags dword at +4; bit 0 = enabled)
    off = 44
    off_ids = {int(x) for x in os.environ.get("DISABLE_LAPIC", "").split(",") if x}
    while off < len(t):
        if off + 2 > len(t):
            sys.exit(f"APIC.bin is cut short: an entry header at {off} runs past the end ({len(t)} bytes); dump it again (tools/dump_sony_acpi.sh)")
        etype, elen = t[off], t[off + 1]
        if elen < MIN_LEN.get(etype, 2) or off + elen > len(t):
            sys.exit(f"APIC.bin has a bad entry at {off} (type {etype}, length {elen}, needs at least {MIN_LEN.get(etype, 2)}, "
                     f"table end {len(t)}); dump it again (tools/dump_sony_acpi.sh)")
        if etype == 0 and t[off + 3] in off_ids:
            struct.pack_into("<I", t, off + 4, 0)
        off += elen
    t += struct.pack("<BBBBII", 1, 12, 0, 0, IOAPIC_PAGE, 0)       # type 1: I/O APIC id 0, address, GSI base 0
    struct.pack_into("<I", t, 4, len(t))
    t[9] = 0
    t[9] = (-sum(t)) & 0xFF
    assert sum(t) & 0xFF == 0
    return bytes(t)

if __name__ == "__main__":
    madt = build()
    Path(sys.argv[1]).write_bytes(madt)
    print("MADT with I/O APIC:", len(madt), "bytes")
