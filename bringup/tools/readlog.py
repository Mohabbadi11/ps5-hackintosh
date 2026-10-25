#!/usr/bin/env python3
import mmap, os, struct
fd = os.open("/dev/mem", os.O_RDONLY)
mm = mmap.mmap(fd, 0x10000, mmap.MAP_SHARED, mmap.PROT_READ, offset=0x300000000)
tag, cnt = struct.unpack("<QQ", mm[:16])
vals = struct.unpack(f"<{cnt}Q", mm[:cnt * 8])
print("tag", tag.to_bytes(8, "little"), "count", cnt, "sig", hex(vals[16]), hex(vals[17]), "logn", vals[18])
n = vals[18]
print(bytes(mm[0x1000:0x1000 + n]).decode("latin-1"))
