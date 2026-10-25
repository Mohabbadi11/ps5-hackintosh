#!/usr/bin/env python3
import mmap, os, struct, sys
ADDR = 0x300000000
fd = os.open("/dev/mem", os.O_RDONLY)
mm = mmap.mmap(fd, 4096, mmap.MAP_SHARED, mmap.PROT_READ, offset=ADDR)
v = struct.unpack("<64Q", mm[:512])
tag = struct.pack("<Q", v[0])
print("tag:", tag, "count:", v[1])
names = ["boot_params","cr0","cr3(entry)","cr4","EFER","APIC_BASE","TSC","cpuid0.eax","vendor_b_d","vendor_c","cpuid1.eax","cpuid1.ebx","cpuid1.edx:ecx","stub_pml4"]
for i, n in enumerate(names):
    print(f"  {n:16s} {v[2+i]:#018x}")
