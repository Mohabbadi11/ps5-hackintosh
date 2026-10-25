#!/usr/bin/env python3
"""Patches applied to the EDK2 workspace copy before building the PS5 payload (idempotent).

PciCf8Lib: PCI configuration through ports 0xCF8/0xCFC cannot reach registers >= 0x100. PciBusDxe walks extended
capabilities and the stock library ASSERTs on such addresses. Here those accesses are redirected to a device that does
not exist (bus 0xFF, device 0x1F, function 7), so reads return all ones ("no extended capabilities") and writes vanish.
"""
import sys

path = "MdePkg/Library/BasePciCf8Lib/PciCf8Lib.c"
text = open(path).read()
assert_old = "#define ASSERT_INVALID_PCI_ADDRESS(A, M) \\\n  ASSERT (((A) & (~0xffff0ff | (M))) == 0)"
cf8_old = "#define PCI_TO_CF8_ADDRESS(A) \\\n  ((UINT32) ((((A) >> 4) & 0x00ffff00) | ((A) & 0xfc) | 0x80000000))"
if "PS5 PATCH" not in text:
    assert assert_old in text and cf8_old in text, "unexpected PciCf8Lib.c contents"
    text = text.replace(assert_old, "#define ASSERT_INVALID_PCI_ADDRESS(A, M)  ((void)0)   // PS5 PATCH")
    text = text.replace(
        cf8_old,
        "#define PCI_TO_CF8_ADDRESS(A) \\\n"
        "  ((UINT32) (((A) & 0xf00) ? 0x80ffff00 : ((((A) >> 4) & 0x00ffff00) | ((A) & 0xfc) | 0x80000000)))",
    )
    open(path, "w").write(text)
    print("patched", path)


# ---- GraphicsOutputDxe: the PS5 framebuffer is in system RAM (the VRAM carve-out), not in a BAR of the GPU ---------------
# The stock driver only attaches when a BAR of the display device contains the framebuffer address from the graphics
# HOB. Here the device (1002:13fc) is matched by vendor/device id and the HOB address is used as is.
path = "UefiPayloadPkg/GraphicsOutputDxe/GraphicsOutput.c"
text = open(path).read()
if "PS5 PATCH" not in text:
    old = "      if (Index == MAX_PCI_BAR) {\n        Status = EFI_UNSUPPORTED;\n      } else {"
    new = ("      if (Index == MAX_PCI_BAR) {\n"
           "        // PS5 PATCH: framebuffer is not inside a BAR, trust the HOB\n"
           "        FrameBufferBase = GraphicsInfo->FrameBufferBase;\n"
           "        DEBUG ((DEBUG_INFO, \"[%a]: framebuffer outside the BARs, using HOB base %lx\\n\", gEfiCallerBaseName, FrameBufferBase));\n"
           "      } else {")
    assert old in text, "unexpected GraphicsOutput.c contents"
    open(path, "w").write(text.replace(old, new))
    print("patched", path)

# ---- GraphicsOutputDxe: the framebuffer must not be cached ---------------------------------------------------------------
# The scanout engine reads DRAM. The carve-out descriptor only declares UC/WC as capabilities, so the CPU would map it
# write-back and the Blt output would sit in the caches. Ask the GCD for write-combining on the framebuffer range.
text = open(path).read()
if "PS5 PATCH WC" not in text:
    inc_old = '#include "GraphicsOutput.h"\n'
    wc_old = "        FrameBufferBase = GraphicsInfo->FrameBufferBase;\n"
    assert inc_old in text and wc_old in text
    text = text.replace(inc_old, inc_old + "#include <Library/DxeServicesTableLib.h>\n", 1)
    wc_new = (wc_old +
              "        // PS5 PATCH WC\n"
              "        gDS->SetMemorySpaceAttributes (\n"
              "               FrameBufferBase,\n"
              "               (GraphicsInfo->FrameBufferSize + 0xFFF) & ~0xFFFULL,\n"
              "               EFI_MEMORY_WC\n"
              "               );\n")
    text = text.replace(wc_old, wc_new, 1)
    open(path, "w").write(text)
    print("patched WC", path)
