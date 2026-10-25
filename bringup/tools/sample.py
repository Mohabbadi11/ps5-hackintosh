#!/usr/bin/env python3
"""Sample one 4 KiB page every 512 KiB of the VRAM aperture; show whether it is uniform and its first word."""
import mmap, os
fd = os.open("/sys/bus/pci/devices/0000:20:00.0/resource0", os.O_RDONLY)
size = os.fstat(fd).st_size
mm = mmap.mmap(fd, size, mmap.MAP_SHARED, mmap.PROT_READ)
prev = None
for off in range(0, size, 1 << 19):
    pg = mm[off + 0x10000:off + 0x10000 + 4096]
    w = pg[:4]
    uni = pg == w * 1024
    tag = (w.hex(), uni)
    if tag != prev:
        print(f"{off:#010x}: first word {w[::-1].hex()} uniform={uni}")
        prev = tag
