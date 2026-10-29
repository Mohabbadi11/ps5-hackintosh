#!/usr/bin/env python3
"""Sony's MADT (opencore/ACPI/sony/APIC.bin, dumped from physical memory 0x7fd8b000) plus one I/O APIC entry pointing at the fake
register page the UEFI bundle loads (uefi/mkbundle.py IOAPIC_PAGE). Usage: make_madt.py out.aml"""
import struct, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
IOAPIC_PAGE = 0x7fd70000

def build():
    t = bytearray((ROOT / "opencore/ACPI/sony/APIC.bin").read_bytes())
    t += struct.pack("<BBBBII", 1, 12, 0, 0, IOAPIC_PAGE, 0)       # type 1: I/O APIC id 0, address, GSI base 0
    struct.pack_into("<I", t, 4, len(t))
    t[9] = 0
    t[9] = (-sum(t)) & 0xFF
    assert sum(t) & 0xFF == 0
    return bytes(t)

if __name__ == "__main__":
    Path(sys.argv[1]).write_bytes(build())
    print("MADT with I/O APIC:", len(build()), "bytes")
