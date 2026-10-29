#!/usr/bin/env python3
"""Run on the console, in the Linux that comes back after macOS jumped into the crash kernel (RETURN=1 / KTTY_RETURN): finds the
kernel's message buffer (struct msgbuf, magic 0x063061) and any panic text in the physical RAM macOS used and prints/saves them.
Usage: macos_log.py [outfile]   (default /root/macos-log.txt)"""
import os, re, struct, sys

RANGES = [(0x100000, 0x40000000), (0x40000000, 0x60000000), (0x60c00000, 0x62800000), (0x64829000, 0x66000000),
          (0x7f000000, 0x7f9d0000), (0x100000000, 0x300000000), (0x300100000, 0x450000000), (0x470000000, 0x47f300000)]
CHUNK = 8 << 20
fd = os.open("/dev/mem", os.O_RDONLY)
MAGIC = struct.pack("<I", 0x063061)
found, panics = [], []
for lo, hi in RANGES:
    a = lo
    while a < hi:
        n = min(CHUNK, hi - a)
        try:
            d = os.pread(fd, n, a)
        except OSError:
            a += n
            continue
        for m in re.finditer(re.escape(MAGIC), d):
            o = m.start()
            if o + 16 > len(d): continue
            size, bufx, bufr = struct.unpack_from("<III", d, o + 4)
            if 0x1000 <= size <= 0x4000000 and bufx < size and o + 16 + size <= len(d):
                found.append((a + o, size, bufx, bytes(d[o + 16:o + 16 + size])))
        for m in re.finditer(rb"panic\(cpu \d+ caller", d):
            panics.append((a + m.start(), bytes(d[m.start():m.start() + 24000])))
        a += n
out = []
for addr, size, bufx, buf in found:
    text = buf[bufx:] + buf[:bufx]
    text = text.replace(b"\0", b"")
    out.append(f"===== msgbuf at phys {addr:#x}, {size} bytes, write index {bufx} =====\n" + text.decode("latin-1"))
seen = set()
for addr, t in panics:
    t = t.split(b"\0")[0]
    if t[:80] in seen: continue
    seen.add(t[:80])
    out.append(f"===== panic text at phys {addr:#x} =====\n" + t.decode("latin-1"))
path = sys.argv[1] if len(sys.argv) > 1 else "/root/macos-log.txt"
open(path, "w").write("\n\n".join(out))
print(f"{len(found)} msgbuf(s), {len(seen)} panic text(s) -> {path}")
