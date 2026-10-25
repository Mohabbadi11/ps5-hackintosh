#!/usr/bin/env python3
"""Build a bzImage whose 64-bit entry runs the stage-1 stub first, then the real kernel placed 2 MiB later
(the kernel's own alignment, so its self-relocation arithmetic is unchanged)."""
import struct, sys
real, stub, out = sys.argv[1:4]
N = 0x200000
d = bytearray(open(real, 'rb').read())
stubbin = open(stub, 'rb').read()
assert len(stubbin) < N
sects = d[0x1f1]
setup_len = (sects + 1) * 512
setup, pm = bytes(d[:setup_len]), bytes(d[setup_len:])
setup = bytearray(setup)
g = lambda o, f: struct.unpack_from(f, setup, o)[0]
def p(o, f, v): struct.pack_into(f, setup, o, v)
p(0x1f4, '<I', g(0x1f4, '<I') + N // 16)             # syssize
p(0x248, '<I', g(0x248, '<I') + N)                   # payload_offset
p(0x260, '<I', g(0x260, '<I') + N)                   # init_size
p(0x264, '<I', g(0x264, '<I') + N)                   # handover_offset
body = stubbin + b'\0' * (N - len(stubbin)) + pm
open(out, 'wb').write(bytes(setup) + body)
print(f"{out}: {len(setup) + len(body)} bytes, init_size={g(0x260,'<I'):#x}")
