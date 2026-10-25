#!/usr/bin/env python3
"""Assemble the OpenCore EFI folder for the bare-metal PS5 (UEFI payload from uefi/) out of the VM build.

Reads build/opencore/EFI (fetch_opencore.sh) and opencore/config.plist, writes build/baremetal-efi/EFI:
  - OpenCore.efi + BOOTx64.efi, OpenRuntime + OpenHfsPlus drivers (the payload already brings USB keyboard support)
  - only the kexts that make sense without a supported GPU (Lilu, VirtualSMC, SMCProcessor, RestrictEvents)
  - config.plist with the display set to 2560x1440 and file logging enabled (the log lands next to OpenCore.efi, so
    Linux can read it after the next boot)
Copy the result to the USB's FAT "boot" partition (mounted at /boot/efi on the PS5).
"""
import plistlib, shutil, sys
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

shutil.copy(SRC / "BOOT/BOOTx64.efi", OUT / "BOOT/BOOTx64.efi")
shutil.copy(SRC / "OC/OpenCore.efi", OUT / "OC/OpenCore.efi")
drivers = ["OpenRuntime.efi", "OpenHfsPlus.efi"]
for d in drivers:
    shutil.copy(SRC / "OC/Drivers" / d, OUT / "OC/Drivers" / d)

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
cfg["Misc"]["Boot"]["Timeout"] = 0
cfg["Misc"]["Boot"]["ShowPicker"] = True
cfg["Misc"]["Boot"]["HideAuxiliary"] = False
cfg["Misc"]["Security"]["ScanPolicy"] = 0
plistlib.dump(cfg, open(OUT / "OC/config.plist", "wb"))
print("EFI written to", OUT)
for p in sorted(OUT.rglob("*")):
    if p.is_file():
        print(f"  {p.relative_to(OUT)}  {p.stat().st_size}")
