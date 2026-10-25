#!/usr/bin/env python3
"""Find runs of pages in the VRAM aperture (BAR0) that are filled with one XR24 colour: usage scanvram.py RRGGBB"""
import mmap, os, sys, time
rgb = sys.argv[1]
r, g, b = int(rgb[0:2], 16), int(rgb[2:4], 16), int(rgb[4:6], 16)
pat = bytes([b, g, r, 0xFF])
page = pat * 1024
fd = os.open("/sys/bus/pci/devices/0000:20:00.0/resource0", os.O_RDONLY)
size = os.fstat(fd).st_size
mm = mmap.mmap(fd, size, mmap.MAP_SHARED, mmap.PROT_READ)
t0 = time.time()
runs, start, n = [], None, 0
CH = 1 << 20
for off in range(0, size, CH):
    chunk = mm[off:off + CH]
    for p in range(0, CH, 4096):
        hit = chunk[p:p + 4096] == page
        a = off + p
        if hit and start is None:
            start = a
        elif not hit and start is not None:
            runs.append((start, a)); start = None
if start is not None:
    runs.append((start, size))
print(f"scanned {size >> 20} MiB in {time.time() - t0:.1f}s; runs >= 64 KiB:")
for s, e in runs:
    if e - s >= 65536:
        print(f"  VRAM+{s:#010x} .. {e:#010x}  ({(e - s) / 1048576:.2f} MiB)  phys {0xD0000000 + s:#x}")
