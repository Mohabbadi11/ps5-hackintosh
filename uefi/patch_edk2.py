#!/usr/bin/env python3
"""Patches applied to the EDK2 workspace copy before building the PS5 payload (idempotent).

PciCf8Lib: PCI configuration through ports 0xCF8/0xCFC cannot reach registers >= 0x100. PciBusDxe walks extended
capabilities and the stock library ASSERTs on such addresses. Here those accesses are redirected to a device that does
not exist (bus 0xFF, device 0x1F, function 7), so reads return all ones ("no extended capabilities") and writes vanish.
"""
import sys

path = "MdePkg/Library/BasePciCf8Lib/PciCf8Lib.c"
text = open(path).read()
if "PS5 PATCH" in text:
    sys.exit(0)

assert_old = "#define ASSERT_INVALID_PCI_ADDRESS(A, M) \\\n  ASSERT (((A) & (~0xffff0ff | (M))) == 0)"
cf8_old = "#define PCI_TO_CF8_ADDRESS(A) \\\n  ((UINT32) ((((A) >> 4) & 0x00ffff00) | ((A) & 0xfc) | 0x80000000))"
assert assert_old in text and cf8_old in text, "unexpected PciCf8Lib.c contents"

text = text.replace(assert_old, "#define ASSERT_INVALID_PCI_ADDRESS(A, M)  ((void)0)   // PS5 PATCH")
text = text.replace(
    cf8_old,
    "#define PCI_TO_CF8_ADDRESS(A) \\\n"
    "  ((UINT32) (((A) & 0xf00) ? 0x80ffff00 : ((((A) >> 4) & 0x00ffff00) | ((A) & 0xfc) | 0x80000000)))",
)
open(path, "w").write(text)
print("patched", path)
