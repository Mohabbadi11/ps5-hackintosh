#!/usr/bin/env python3
"""Sony's MADT (opencore/ACPI/sony/APIC.bin, dumped from physical memory 0x7fd8b000) plus one I/O APIC entry pointing at the fake
register page the UEFI bundle loads (uefi/mkbundle.py IOAPIC_PAGE). Usage: make_madt.py out.aml"""
import os, struct, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
IOAPIC_PAGE = 0x7fd70000

def build():
    apic = ROOT / "opencore/ACPI/sony/APIC.bin"
    if not apic.exists():
        sys.exit("missing opencore/ACPI/sony/APIC.bin, the console's own MADT (not tracked): with Linux up on the console run tools/dump_sony_acpi.sh")
    t = bytearray(apic.read_bytes())
    # DISABLE_LAPIC=8,9: mark those local APIC ids as not enabled (processor local APIC entries: type 0, flags dword at +4; bit 0 = enabled)
    off = 44
    off_ids = {int(x) for x in os.environ.get("DISABLE_LAPIC", "").split(",") if x}
    while off < len(t):
        etype, elen = t[off], t[off + 1]
        if elen == 0:
            break
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
    Path(sys.argv[1]).write_bytes(build())
    print("MADT with I/O APIC:", len(build()), "bytes")
