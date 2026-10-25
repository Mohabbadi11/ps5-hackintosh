#!/usr/bin/env python3
import mmap, os, struct
fd5 = os.open("/sys/bus/pci/devices/0000:20:00.0/resource5", os.O_RDWR | os.O_SYNC)
regs = mmap.mmap(fd5, 0x80000, mmap.MAP_SHARED, mmap.PROT_READ | mmap.PROT_WRITE)
def vr(pos):
    regs[0:4] = struct.pack("<I", (pos & 0x7FFFFFFF) | 0x80000000); regs[0x18:0x1c] = struct.pack("<I", pos >> 31)
    return struct.unpack("<I", regs[4:8])[0]
hits = []
for pos in range(0, 512 << 20, 0x1000):
    if vr(pos) == 0xDEADBE00 and vr(pos + 4) == 0xDEADBE01 and vr(pos + 28) == 0xDEADBE07:
        hits.append(pos)
print("signature hits:", [hex(h) for h in hits])
for h in hits:
    base = h
    print("first pixel after signature (x=8,y=0):", hex(vr(base + 32)))
    print("row 1 first pixel:", hex(vr(base + 10240)), " (expect bar0 0xffffffff)")
    print("mid ramp row 480 x=0:", hex(vr(base + 10240 * 480)), "x=1279:", hex(vr(base + 10240 * 480 + 1279 * 4)))
    print("row 960 x=5,y=960 code:", hex(vr(base + 10240 * 960 + 5 * 4)), "expect", hex(0xFF000000 | (5 << 8) | (960 & 0xFF)))
