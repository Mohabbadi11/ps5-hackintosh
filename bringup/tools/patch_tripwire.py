#!/usr/bin/env python3
"""Run on the console after kms_linear.py: find where the linear test framebuffer sits in the VRAM carve-out (signature
0xDEADBE00.. at pixel (0,0)) and write that VRAM offset into the tripwire kernel patch of an OpenCore config.plist
(the immediate of the first instruction, see bringup/tripwire/tripwire.S). Usage: patch_tripwire.py config.plist"""
import os, plistlib, re, struct, sys

def carve_from_iomem():
    """(base, size) of the VRAM carve-out: the loader grows it downward from the fixed top 0x470000000 (vram.txt), and /proc/iomem
    lists it as a top-level 'Reserved' range ending at 0x46fffffff. 512 MB at 0x450000000 if that is not found."""
    try:
        for line in open("/proc/iomem"):
            m = re.match(r"^([0-9a-f]+)-([0-9a-f]+) : Reserved", line)
            if m and int(m.group(2), 16) == 0x46FFFFFFF:
                base = int(m.group(1), 16)
                return base, 0x470000000 - base
    except OSError:
        pass
    return 0x450000000, 0x20000000

CARVEOUT, SIZE = carve_from_iomem()
fd = os.open("/dev/mem", os.O_RDONLY)
pos = None
for off in range(0, SIZE, 0x1000):
    b = os.pread(fd, 32, CARVEOUT + off)
    if len(b) == 32 and struct.unpack("<8I", b) == tuple(0xDEADBE00 + i for i in range(8)):
        pos = off
        break
if pos is None:
    sys.exit("signature not found: is kms_linear.py running?")
path = sys.argv[1]
cfg = plistlib.load(open(path, "rb"))
n = 0
PLACEHOLDER = bytes.fromhex("0df0adde")            # 0xDEADF00D, the ktty console's VRAM offset
for p in cfg["Kernel"]["Patch"]:
    if p["Comment"].startswith("tripwire"):
        r = bytearray(p["Replace"])
        assert r[0] == 0xFA and r[1] == 0xBE, "unexpected tripwire code"
        r[2:6] = struct.pack("<I", pos)
        p["Replace"] = bytes(r)
        n += 1
    elif p["Comment"].startswith(("ktty", "ps5 - return")) and PLACEHOLDER in p["Replace"]:
        p["Replace"] = p["Replace"].replace(PLACEHOLDER, struct.pack("<I", pos))
        n += 1
plistlib.dump(cfg, open(path, "wb"))
print(f"framebuffer at VRAM+{pos:#x} (phys {CARVEOUT + pos:#x}); patched {n} tripwire(s) in {path}")
