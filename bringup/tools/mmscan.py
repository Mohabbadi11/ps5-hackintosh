#!/usr/bin/env python3
"""Read VRAM beyond the 256 MiB BAR through the GPU's MM_INDEX/MM_DATA window (BAR5)."""
import mmap, os, struct, sys
fd5 = os.open("/sys/bus/pci/devices/0000:20:00.0/resource5", os.O_RDWR | os.O_SYNC)
regs = mmap.mmap(fd5, 0x80000, mmap.MAP_SHARED, mmap.PROT_READ | mmap.PROT_WRITE)
fd0 = os.open("/sys/bus/pci/devices/0000:20:00.0/resource0", os.O_RDONLY)
bar0 = mmap.mmap(fd0, 0x10000000, mmap.MAP_SHARED, mmap.PROT_READ)
def wr(o, v): regs[o:o+4] = struct.pack("<I", v)
def rd(o): return struct.unpack("<I", regs[o:o+4])[0]
def vram_rd(pos):
    wr(0x0, (pos & 0x7FFFFFFF) | 0x80000000)
    wr(0x18, pos >> 31)
    return rd(0x4)
# sanity: compare the indirect path with the aperture
ok = all(vram_rd(o) == struct.unpack("<I", bar0[o:o+4])[0] for o in (0x4280000, 0xb000000, 0x1000, 0x2000000))
print("indirect == aperture:", ok)
want = {int(a, 16) for a in sys.argv[1:]} if len(sys.argv) > 1 else {0xFF11AA33, 0x0011AA33}
prev = None
for mb in range(0, 512):
    pos = mb << 20
    v = [vram_rd(pos + k) for k in (0x40000, 0x80000, 0xC0000)]
    tag = (v[0] in want and v[1] in want and v[2] in want)
    if tag != prev:
        print(f"VRAM+{pos:#011x} ({mb} MiB): {'solid colour' if tag else 'other'}  words={[hex(x) for x in v]}")
        prev = tag
