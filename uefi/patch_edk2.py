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
           "        Status          = EFI_SUCCESS;  // the BAR loop left the error of its last GetBarAttributes() call here\n"
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


# ---- CpuExceptionHandlerLib: acknowledge external interrupts nobody registered a handler for --------------------------
# The previous OS (Linux, killed by the crash kexec) leaves vectors such as 0xEC/0xFD pending in the local APIC and its
# devices may still raise MSIs. The stock handler returns from an unhandled external interrupt without an EOI, so the
# in-service bit stays set and blocks every lower-priority vector, including UEFI's own timer tick (BdsWait then waits
# forever). Send the EOI, except for the spurious vector 0xFF which has no in-service bit.
path = "UefiCpuPkg/Library/CpuExceptionHandlerLib/PeiDxeSmmCpuException.c"
text = open(path).read()
if "PS5 PATCH" not in text:
    old = ("    if (ReservedVectors[ExceptionType].Attribute != EFI_VECTOR_HANDOFF_HOOK_BEFORE) {\n"
           "      CpuDeadLoop ();\n"
           "    }\n"
           "  }\n"
           "}\n")
    assert old in text, "unexpected PeiDxeSmmCpuException.c contents"
    new = old[:-len("  }\n}\n")] + (
           "  } else if (ExceptionType != 0xFF) {\n"
           "    // PS5 PATCH: unhandled external interrupt, send the local APIC EOI\n"
           "    *(volatile UINT32 *)(UINTN)0xFEE000B0 = 0;\n"
           "  }\n"
           "}\n")
    open(path, "w").write(text.replace(old, new))
    print("patched", path)

# ---- GraphicsOutputDxe: do not let PCI attribute handling veto the GOP, and say what happens ---------------------------
# OpenCore reported "Missing compatible GOP": the driver kept being started for every PCI controller (mDriverStarted
# never became TRUE), so one of the late steps of Start() fails for the GPU. The previous OS already enabled the GPU
# (I/O, memory, bus master), so a failure of PciIo->Attributes() is ignored, and every later step logs its status.
path = "UefiPayloadPkg/GraphicsOutputDxe/GraphicsOutput.c"
text = open(path).read()
if "PS5 PATCH PCI" not in text:
    old1 = "  if (EFI_ERROR (Status)) {\n    goto FreeMemory;\n  }\n"
    new1 = ("  DEBUG ((DEBUG_INFO, \"[%a]: PciIo attributes: %r (ignored)\\n\", gEfiCallerBaseName, Status));\n"
            "  Status = EFI_SUCCESS;  // PS5 PATCH PCI\n"
            "  if (FALSE) {\n    goto FreeMemory;  // keeps the label used\n  }\n")
    old2 = "  if (RETURN_ERROR (ReturnStatus)) {\n    Status = EFI_OUT_OF_RESOURCES;"
    new2 = ("  DEBUG ((DEBUG_INFO, \"[%a]: FrameBufferBltConfigure: %r\\n\", gEfiCallerBaseName, ReturnStatus));\n" + old2)
    old3 = ("  if (!EFI_ERROR (Status)) {\n    Status = gBS->OpenProtocol (\n                    Controller,\n"
            "                    &gEfiPciIoProtocolGuid,\n                    (VOID **)&Private->PciIo,")
    new3 = ("  DEBUG ((DEBUG_INFO, \"[%a]: GOP install: %r\\n\", gEfiCallerBaseName, Status));\n" + old3)
    old4 = "    if (!EFI_ERROR (Status)) {\n      mDriverStarted = TRUE;"
    new4 = ("    DEBUG ((DEBUG_INFO, \"[%a]: open as child: %r\\n\", gEfiCallerBaseName, Status));\n" + old4)
    for o in (old1, old2, old3, old4):
        assert text.count(o) == 1, o
    text = text.replace(old1, new1).replace(old2, new2).replace(old3, new3).replace(old4, new4)
    open(path, "w").write(text)
    print("patched PCI/debug", path)

# ---- GraphicsOutputDxe: drop the per-controller 'GraphicsDeviceInfo HOB' banner ------------------------------------------
# It is printed for every PCI controller on every connect pass and floods the framebuffer log ring, hiding the lines that
# matter (the GOP installation statuses).
import re
path = "UefiPayloadPkg/GraphicsOutputDxe/GraphicsOutput.c"
text = open(path).read()
if "PS5 PATCH QUIET" not in text:
    pattern = re.compile(r'    DEBUG \(\(\n      DEBUG_INFO,\n      "\[%a\]: GraphicsDeviceInfo HOB:\\n".*?\n      \)\);\n', re.S)
    assert len(pattern.findall(text)) == 1, "GraphicsDeviceInfo banner not found once"
    text = pattern.sub("    // PS5 PATCH QUIET: banner removed\n", text)
    open(path, "w").write(text)
    print("patched QUIET", path)

# ---- PlatformBootManagerLib: dump the framebuffer console log to \ps5-uefi.log on the boot USB -----------------------------
# The console log lives in RAM (0x300002000, length at 0x300001f0c) which does not survive the jailbreak cycle. BDS calls the
# platform hooks at TPL_APPLICATION, where FAT writes are safe: write the log after the console is up and on every
# BdsWait tick, into the ESP that contains EFI\OC\OpenCore.efi, so Linux can read it afterwards.
path = "UefiPayloadPkg/Library/PlatformBootManagerLib/PlatformBootManager.c"
text = open(path).read()
if "PS5 PATCH LOG" not in text:
    helper = r'''
#include <Protocol/SimpleFileSystem.h>
#include <Guid/FileInfo.h>

// PS5 PATCH LOG
STATIC
VOID
Ps5DumpLog (
  VOID
  )
{
  UINT32                           Len;
  EFI_HANDLE                       *Handles;
  UINTN                            Count;
  UINTN                            I;
  EFI_STATUS                       Status;
  EFI_SIMPLE_FILE_SYSTEM_PROTOCOL  *Fs;
  EFI_FILE_PROTOCOL                *Root;
  EFI_FILE_PROTOCOL                *File;
  UINTN                            Size;

  Len = *(volatile UINT32 *)(UINTN)0x300001f0cULL;
  if ((Len == 0) || (Len > 0x40000)) {
    return;
  }

  Status = gBS->LocateHandleBuffer (ByProtocol, &gEfiSimpleFileSystemProtocolGuid, NULL, &Count, &Handles);
  if (EFI_ERROR (Status)) {
    return;
  }

  for (I = 0; I < Count; I++) {
    if (EFI_ERROR (gBS->HandleProtocol (Handles[I], &gEfiSimpleFileSystemProtocolGuid, (VOID **)&Fs))) {
      continue;
    }

    if (EFI_ERROR (Fs->OpenVolume (Fs, &Root))) {
      continue;
    }

    if (!EFI_ERROR (Root->Open (Root, &File, L"\\EFI\\OC\\OpenCore.efi", EFI_FILE_MODE_READ, 0))) {
      File->Close (File);
      if (!EFI_ERROR (Root->Open (Root, &File, L"\\ps5-uefi.log", EFI_FILE_MODE_READ | EFI_FILE_MODE_WRITE, 0))) {
        File->Delete (File);
      }

      if (!EFI_ERROR (Root->Open (Root, &File, L"\\ps5-uefi.log", EFI_FILE_MODE_READ | EFI_FILE_MODE_WRITE | EFI_FILE_MODE_CREATE, 0))) {
        Size = Len;
        File->Write (File, &Size, (VOID *)(UINTN)0x300002000ULL);
        File->Flush (File);
        File->Close (File);
      }

      Root->Close (Root);
      break;
    }

    Root->Close (Root);
  }

  gBS->FreePool (Handles);
}

'''
    anchor = "VOID\nEFIAPI\nPlatformBootManagerAfterConsole ("
    assert text.count(anchor) == 1
    # keep the doc comment above AfterConsole attached to it: insert the helper before that comment block
    idx = text.rindex("/**", 0, text.index(anchor))
    text = text[:idx] + helper.lstrip("\n") + "\n" + text[idx:]
    old_wait = "PlatformBootManagerWaitCallback (\n  UINT16  TimeoutRemain\n  )\n{\n  return;\n}"
    assert old_wait in text
    text = text.replace(old_wait, "PlatformBootManagerWaitCallback (\n  UINT16  TimeoutRemain\n  )\n{\n  Ps5DumpLog ();\n  return;\n}")
    old_tail = '      L"    ENTER           to boot directly.\\n"\n      L"\\n"\n      );\n  }\n}\n'
    assert old_tail in text, "AfterConsole tail"
    text = text.replace(old_tail, old_tail[:-2] + "\n  Ps5DumpLog ();\n}\n")
    open(path, "w").write(text)
    inf = "UefiPayloadPkg/Library/PlatformBootManagerLib/PlatformBootManagerLib.inf"
    t = open(inf).read()
    t = t.replace("  gEfiPciRootBridgeIoProtocolGuid\n", "  gEfiPciRootBridgeIoProtocolGuid\n  gEfiSimpleFileSystemProtocolGuid\n", 1)
    t = t.replace("[Guids]\n  gEfiEndOfDxeEventGroupGuid", "[Guids]\n  gEfiFileInfoGuid\n  gEfiEndOfDxeEventGroupGuid", 1)
    open(inf, "w").write(t)
    print("patched LOG", path)
