#!/usr/bin/env python3
"""Reads the console's /proc/iomem on stdin and prints the physical base of the VRAM carve-out (0x...), e.g.
    ssh root@console cat /proc/iomem | python3 tools/carveout.py
The PS5 Linux loader grows the carve-out downward from the fixed top 0x470000000 (vram.txt: 0x20000000 = 512 MB -> 0x450000000,
0x100000000 = 4 GiB -> 0x370000000); /proc/iomem lists it as a top-level 'Reserved' range ending at 0x46fffffff."""
import re, sys

base = None
for line in sys.stdin:
    m = re.match(r"^\s*([0-9a-fA-F]+)-([0-9a-fA-F]+)\s*:\s*Reserved", line, re.IGNORECASE)
    if m and int(m.group(2), 16) == 0x46FFFFFFF:
        base = int(m.group(1), 16)
if base is None:
    sys.exit("no Reserved range ending at 0x46fffffff in /proc/iomem")
print(hex(base))
