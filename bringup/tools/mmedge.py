#!/usr/bin/env python3
import mmap, os, struct
fd5 = os.open("/sys/bus/pci/devices/0000:20:00.0/resource5", os.O_RDWR | os.O_SYNC)
regs = mmap.mmap(fd5, 0x80000, mmap.MAP_SHARED, mmap.PROT_READ | mmap.PROT_WRITE)
def wr(o, v): regs[o:o+4] = struct.pack("<I", v)
def rd(o): return struct.unpack("<I", regs[o:o+4])[0]
def vram_rd(pos):
    wr(0x0, (pos & 0x7FFFFFFF) | 0x80000000); wr(0x18, pos >> 31); return rd(0x4)
def solid(pos): return vram_rd(pos) == 0xFF11AA33
def edges(lo, hi, step=0x1000):
    out, prev = [], None
    for p in range(lo, hi, step):
        s = solid(p)
        if s != prev:
            out.append((p, s)); prev = s
    return out
for lo, hi in [(447 << 20, 451 << 20), (461 << 20, 465 << 20), (479 << 20, 483 << 20), (493 << 20, 497 << 20)]:
    print(f"[{lo:#x}..{hi:#x}]", [(hex(p), 'solid' if s else 'other') for p, s in edges(lo, hi)])
