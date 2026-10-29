#!/usr/bin/env python3
"""Assemble the OpenCore EFI folder for the bare-metal PS5 (UEFI payload from uefi/) out of the VM build.

Reads build/opencore/EFI (fetch_opencore.sh) and opencore/config.plist, writes build/baremetal-efi/EFI:
  - OpenCore.efi + BOOTx64.efi, OpenRuntime + OpenHfsPlus drivers (the payload already brings USB keyboard support)
  - only the kexts that make sense without a supported GPU (Lilu, VirtualSMC, SMCProcessor, RestrictEvents)
  - config.plist with the display set to 2560x1440 and file logging enabled (the log lands next to OpenCore.efi, so
    Linux can read it after the next boot)
Copy the result to the USB's FAT "boot" partition (mounted at /boot/efi on the PS5).
"""
import os, plistlib, shutil, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "build/opencore/EFI"
OUT = ROOT / "build/baremetal-efi/EFI"

if not SRC.exists():
    sys.exit(f"missing {SRC}: run tools/fetch_opencore.sh first")
shutil.rmtree(ROOT / "build/baremetal-efi", ignore_errors=True)
(OUT / "BOOT").mkdir(parents=True)
(OUT / "OC/Drivers").mkdir(parents=True)
(OUT / "OC/Kexts").mkdir()
(OUT / "OC/ACPI").mkdir()
(OUT / "OC/Resources").mkdir()
(OUT / "OC/Tools").mkdir()

# OC_DEBUG=1 swaps in the DEBUG build of OpenCore (build/opencore-debug, from OpenCore-<ver>-DEBUG.zip): it logs the
# memory map, slide and ExitBootServices steps, which the release build leaves out
BIN = ROOT / "build/opencore-debug/X64/EFI" if os.environ.get("OC_DEBUG") == "1" else SRC
shutil.copy(BIN / "BOOT/BOOTx64.efi", OUT / "BOOT/BOOTx64.efi")
shutil.copy(BIN / "OC/OpenCore.efi", OUT / "OC/OpenCore.efi")
drivers = ["OpenRuntime.efi", "OpenHfsPlus.efi"]
for d in drivers:
    shutil.copy(BIN / "OC/Drivers" / d, OUT / "OC/Drivers" / d)

# bringup/ebstest: tells where ExitBootServices/SetVirtualAddressMap die (shows up in the picker as "EbsTest")
ebs = ROOT / "bringup/ebstest/EbsTest.efi"
if ebs.exists():
    shutil.copy(ebs, OUT / "OC/Tools/EbsTest.efi")

kexts = ["Lilu.kext", "VirtualSMC.kext", "SMCProcessor.kext", "RestrictEvents.kext"]
for k in kexts:
    shutil.copytree(SRC / "OC/Kexts" / k, OUT / "OC/Kexts" / k)


def kext_entry(name):
    stem = name[:-5]
    return {
        "Arch": "x86_64", "BundlePath": name, "Comment": stem, "Enabled": True,
        "ExecutablePath": f"Contents/MacOS/{stem}", "MaxKernel": "", "MinKernel": "",
        "PlistPath": "Contents/Info.plist",
    }


cfg = plistlib.load(open(ROOT / "opencore/config.plist", "rb"))
cfg["Kernel"]["Add"] = [kext_entry("Lilu.kext"), kext_entry("VirtualSMC.kext"), kext_entry("SMCProcessor.kext"),
                        kext_entry("RestrictEvents.kext")]
# SMCProcessor lives inside the VirtualSMC release but is a separate bundle; fix its executable path when needed
for e in cfg["Kernel"]["Add"]:
    stem = e["BundlePath"][:-5]
    if not (OUT / "OC/Kexts" / e["BundlePath"] / "Contents/MacOS" / stem).exists():
        e["ExecutablePath"] = ""
cfg["UEFI"]["Drivers"] = [{"Arguments": "", "Comment": d, "Enabled": True, "LoadEarly": False, "Path": d} for d in drivers]
cfg["UEFI"]["Output"]["Resolution"] = "2560x1440"
cfg["UEFI"]["Output"]["ProvideConsoleGop"] = True
cfg["Misc"]["Debug"]["Target"] = 67              # enable | console | file
if os.environ.get("OC_DEBUG") == "1":
    cfg["Misc"]["Debug"]["DisplayLevel"] = 0x80400042   # error | warn | info | verbose
# The console has no SMBIOS memory tables, so boot.efi reports PhysicalMemorySize = 0 and XNU sizes its physical-memory window
# (physmap) at PhysicalMemorySize + 4 GiB = 4 GiB: touching RAM above that panics with "PHYSMAP_PTOV bounds exceeded".
# Describe the PS5's 16 GB (2 x 8 GB) so the window covers all of it.
cfg["PlatformInfo"]["CustomMemory"] = True
cfg["PlatformInfo"]["Memory"] = {
    "DataWidth": 64, "ErrorCorrection": 3, "FormFactor": 13, "MaxCapacity": 16 * 1024 ** 3, "TotalWidth": 64, "Type": 26,
    "TypeDetail": 128,
    "Devices": [{"AssetTag": "Unknown", "BankLocator": f"BANK {i}", "DeviceLocator": f"DIMM{i}", "Manufacturer": "Unknown",
                 "PartNumber": "Unknown", "SerialNumber": "Unknown", "Size": 8192, "Speed": 3200} for i in range(2)]}
# XNU 21.6 derives core_count/thread_count from MSR 0x35, which the AMD CPU does not have; after OpenCore's own CPU-info patches
# the counters end up as core_count 16 / thread_count 0 and initTopoParms() (inlined in cpu_thread_alloc) divides by zero (#DE).
# OpenCore rewrites the MSR code before the user patches run, so fix the readers instead: cpu_thread_alloc sees 8 cores, 16 threads.
for find, repl, count in (("8b9890010000", "bb0800000090", 1),            # mov ebx,[rax+400]  -> mov ebx,8
                          ("8bb094010000", "be1000000090", 1),            # mov esi,[rax+404]  -> mov esi,16
                          ("418b8f90010000", "b9080000009090", 2),        # mov ecx,[r15+400]  -> mov ecx,8
                          ("418b8794010000", "b8100000009090", 1),        # mov eax,[r15+404]  -> mov eax,16
                          # belt and braces: xor edx,edx / div reg  ->  xor eax,eax / mov al,N, so no division can fault
                          ("31d2f7f3", "31c0b002", 1),                    # div ebx (threads per core) -> 2
                          ("31d2f7f7", "31c0b008", 1),                    # div edi (cores sharing the LLC) -> 8
                          ("31d2f7f1", "31c0b002", 1)):                   # div ecx (threads per core) -> 2
    cfg["Kernel"]["Patch"].insert(0, {
        "Arch": "x86_64", "Base": "_cpu_thread_alloc", "Comment": "ps5 - topology counts " + find[:8], "Count": count,
        "Enabled": True, "Find": bytes.fromhex(find), "Identifier": "kernel", "Limit": 0x400, "Mask": b"",
        "MaxKernel": "21.99.99", "MinKernel": "21.0.0", "Replace": bytes.fromhex(repl), "ReplaceMask": b"", "Skip": 0})
cfg["Misc"]["Boot"]["Timeout"] = 0
cfg["Misc"]["Boot"]["ShowPicker"] = True
cfg["Misc"]["Boot"]["HideAuxiliary"] = False
cfg["Misc"]["Security"]["ScanPolicy"] = 0
if ebs.exists():
    cfg["Misc"]["Tools"] = [t for t in cfg["Misc"]["Tools"] if t["Path"] != "EbsTest.efi"] + [
        {"Arguments": "", "Auxiliary": False, "Comment": "ExitBootServices probe", "Enabled": True, "Flavour": "Auto",
         "FullNvramAccess": False, "Name": "EbsTest", "Path": "EbsTest.efi", "RealPath": False, "TextMode": False}]
# TRIPWIRE=<kernel symbol>=<AARRGGBB>: overwrite the start of that kernel function with bringup/tripwire, which paints a
# square of that colour on the screen through the GPU's I/O ports and spins (bringup/tools/patch_tripwire.py then fixes the
# VRAM offset on the console). Reaching it proves the kernel got that far.
# (A deliberate triple fault is no use: on this console it freezes the picture instead of resetting.)
if os.environ.get("TRIPWIRE"):
    import subprocess, tempfile
    sym, colour = os.environ["TRIPWIRE"].split("=")
    llvm = os.environ.get("LLVM_BIN", "/opt/homebrew/opt/llvm@18/bin")
    with tempfile.TemporaryDirectory() as td:
        subprocess.check_call([f"{llvm}/clang", "-target", "i386-unknown-none-elf", "-c", f"-DCOLOUR=0x{colour}",
                               "-DVRAM_OFFSET=0x1a000000",
                               str(ROOT / "bringup/tripwire/tripwire.S"), "-o", f"{td}/tw.o"])
        subprocess.check_call([f"{llvm}/llvm-objcopy", "-O", "binary", "--only-section=.text", f"{td}/tw.o", f"{td}/tw.bin"])
        code = open(f"{td}/tw.bin", "rb").read()
    cfg["Kernel"]["Patch"].insert(0, {
        "Arch": "x86_64", "Base": sym, "Comment": f"tripwire {sym}", "Count": 1, "Enabled": True, "Find": b"",
        "Identifier": "kernel", "Limit": 0, "Mask": b"", "MaxKernel": "", "MinKernel": "",
        "Replace": code, "ReplaceMask": b"", "Skip": 0})
# KTTY=1: show the whole kernel console (printf/kprintf) on the screen, see bringup/ktty and tools/make_ktty.py
if os.environ.get("KTTY") == "1":
    sys.path.insert(0, str(ROOT / "tools"))
    import make_ktty
    cfg["Kernel"]["Patch"] = make_ktty.patches() + cfg["Kernel"]["Patch"]
    args = cfg["NVRAM"]["Add"]["7C436110-AB2A-4BBB-A880-FE41995C9F82"]["boot-args"]
    if "serial=" not in args:
        cfg["NVRAM"]["Add"]["7C436110-AB2A-4BBB-A880-FE41995C9F82"]["boot-args"] = args + " serial=3"
plistlib.dump(cfg, open(OUT / "OC/config.plist", "wb"))
print("EFI written to", OUT)
for p in sorted(OUT.rglob("*")):
    if p.is_file():
        print(f"  {p.relative_to(OUT)}  {p.stat().st_size}")
