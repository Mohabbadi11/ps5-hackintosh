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
sys.path.insert(0, str(ROOT / "tools"))
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
# AMD CPUs do not report Intel-style topology (CPUID leaf 4, MSR 0x35): cores_per_package falls back to 1, cache_sharing to 1
# while logical_per_package is 16, and initTopoParms()/x86_LLC_info() (inlined in cpu_thread_alloc, xnu cpu_threads.c) end up
# dividing by zero. Replace each quotient by the Zen 2 value (8 cores / 16 threads, 2 CCX of 4 cores sharing an L3):
#   xor edx,edx ; div reg   ->   xor eax,eax ; mov al,N      (context bytes keep every patch on its own site)
TOPO = (("89f031d2f7f3", "2"),               # nLThreadsPerCore helper: thread_count / core_count
        ("89c789c831d2f7f7", "4"),           # nCoresSharingLLC = cache_sharing / (threads per core)
        ("418b879401000031d2f7f1", "2"),     # nLThreadsPerCore = thread_count / core_count
        ("418b87cc00000031d2f7f1", "2"),     # nPThreadsPerCore = logical_per_package / cores_per_package
        ("418b879001000031d2f7f6", "2"),     # nLDiesPerPackage = core_count / nCoresSharingLLC
        ("418bb7c800000031d2f7f1", "4"),     # nPCoresPerDie = maxSharingLLC / nPThreadsPerCore (the one that panicked)
        ("89c789f031d2f7f7", "2"))           # nPDiesPerPackage = cores_per_package / nPCoresPerDie
for find, n in TOPO:
    repl = find[:-8] + "31c0b0" + "%02x" % int(n)
    cfg["Kernel"]["Patch"].insert(0, {
        "Arch": "x86_64", "Base": "_cpu_thread_alloc", "Comment": "ps5 - topology div " + find[:8], "Count": 1,
        "Enabled": True, "Find": bytes.fromhex(find), "Identifier": "kernel", "Limit": 0x400, "Mask": b"",
        "MaxKernel": "21.99.99", "MinKernel": "21.0.0", "Replace": bytes.fromhex(repl), "ReplaceMask": b"", "Skip": 0})
# cpuid_set_cache_info falls back to the Intel CPUID leaf 2 descriptors, which AMD does not provide: cache_linesize stays 0 and
# the kernel panics "no linesize" (cpuid.c:520). Force a 64-byte line (Zen 2):
#   mov r14d,[rbp-72] ; test r14d,r14d ; je panic   ->   mov r14d,64 ; 7 nops
cfg["Kernel"]["Patch"].insert(0, {
    "Arch": "x86_64", "Base": "_cpuid_wa_required", "Comment": "ps5 - cache linesize 64", "Count": 1, "Enabled": True,
    "Find": bytes.fromhex("448b75b84585f60f8405010000"), "Identifier": "kernel", "Limit": 0x1000, "Mask": b"",
    "MaxKernel": "21.99.99", "MinKernel": "21.0.0", "Replace": bytes.fromhex("41be4000000090909090909090"),
    "ReplaceMask": b"", "Skip": 0})
# ACPI for the bare PS5 (see the VM rehearsal notes): our DSDT (PCI0 windows + an RTC node), and Sony's MADT plus a fake I/O APIC
import make_madt
shutil.copy(ROOT / "opencore/ACPI/DSDT-PS5-v2.aml", OUT / "OC/ACPI/DSDT.aml")
(OUT / "OC/ACPI/MADT-PS5.aml").write_bytes(make_madt.build())
cfg["ACPI"]["Add"] = [{"Comment": "PS5 DSDT", "Enabled": True, "Path": "DSDT.aml"},
                      {"Comment": "Sony MADT + fake I/O APIC", "Enabled": True, "Path": "MADT-PS5.aml"}]
cfg["ACPI"]["Delete"] = [{"All": True, "Comment": "Sony MADT (no I/O APIC)", "Enabled": True, "OemTableId": b"",
                          "TableLength": 0, "TableSignature": b"APIC"}]
# the PS5 has no CMOS RTC: AppleRTC reads/writes are replaced by a fixed time (12:00 on 24 Oct 2026) and ignored writes
rtc_read = bytes.fromhex("89f683fe0e730c488d0d080000000fb60431c331c0c3") + bytes.fromhex("0000000012000724102626020080")
for sym, code, name in (("__ZN8AppleRTC7rtcReadEj", rtc_read, "rtcRead"), ("__ZN8AppleRTC8rtcWriteEjh", b"\xc3", "rtcWrite")):
    cfg["Kernel"]["Patch"].insert(0, {
        "Arch": "x86_64", "Base": sym, "Comment": "ps5 - AppleRTC " + name, "Count": 1, "Enabled": True, "Find": b"",
        "Identifier": "com.apple.driver.AppleRTC", "Limit": len(code), "Mask": b"", "MaxKernel": "", "MinKernel": "",
        "Replace": code, "ReplaceMask": b"", "Skip": 0})
# XNU's built-in Intel power management (XCPM) switches on for CPU model 0x47 (family 17h model 0x47 is a supported case in
# xcpm_bootstrap) whatever the vendor: machine_idle then uses XCPM's MWAIT idle and timer deadlines instead of sti;hlt, which is a
# prime suspect for the console never receiving a LAPIC interrupt. DummyPowerManagement does not stop it. Make it a no-op (ret):
cfg["Kernel"]["Patch"].insert(0, {
    "Arch": "x86_64", "Base": "_xcpm_bootstrap", "Comment": "ps5 - no XCPM", "Count": 1, "Enabled": True, "Find": b"",
    "Identifier": "kernel", "Limit": 0, "Mask": b"", "MaxKernel": "", "MinKernel": "",
    "Replace": bytes.fromhex("c3"), "ReplaceMask": b"", "Skip": 0})
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
# RETURN=1: a panic/reboot (kernel halt_all_cpus) jumps back into the Linux crash kernel instead of resetting the console: Linux
# comes back with all of macOS' RAM readable (tools/macos_log.py). KTTY_RETURN="text" does the same when the console prints it.
if os.environ.get("RETURN") == "1":
    import subprocess, tempfile
    llvm = os.environ.get("LLVM_BIN", "/opt/homebrew/opt/llvm@18/bin")
    with tempfile.TemporaryDirectory() as td:
        subprocess.check_call([f"{llvm}/clang", "-target", "x86_64-unknown-none-elf", "-I", str(ROOT / "bringup/retlinux"), "-c",
                               str(ROOT / "bringup/retlinux/retkern.S"), "-o", f"{td}/rk.o"])
        subprocess.check_call([f"{llvm}/llvm-objcopy", "-O", "binary", "--only-section=.text", f"{td}/rk.o", f"{td}/rk.bin"])
        retkern = open(f"{td}/rk.bin", "rb").read()
    cfg["Kernel"]["Patch"].insert(0, {
        "Arch": "x86_64", "Base": "_halt_all_cpus", "Comment": "ps5 - return to Linux", "Count": 1, "Enabled": True, "Find": b"",
        "Identifier": "kernel", "Limit": 0, "Mask": b"", "MaxKernel": "", "MinKernel": "",
        "Replace": retkern, "ReplaceMask": b"", "Skip": 0})
# XNU's clocks: OpenCore tells it a 1 GHz TSC / 100 MHz bus, the hardware is 1596.3 MHz / ~25 MHz (tools/make_tscfix.py). TSCFIX=0 leaves them.
if os.environ.get("TSCFIX", "1") != "0":
    sys.path.insert(0, str(ROOT / "tools"))
    import make_tscfix
    cfg["Kernel"]["Patch"] = make_tscfix.patches() + cfg["Kernel"]["Patch"]
# Safety: the internal Sony SSD controller (PCI 40:00.0, 104d:90eb) is class 0180 and AppleNVMe attaches to it. It fails at start today (CAP reads
# all ones), but the boot disk is USB and the internal SSD must never be touched: make the kext fail to start (Disable, not Exclude: other kexts may link
# against it). NVMEBLOCK=0 allows it.
if os.environ.get("NVMEBLOCK", "1") != "0":
    cfg["Kernel"]["Block"].append({"Arch": "Any", "Comment": "Never let AppleNVMe near the internal Sony SSD", "Enabled": True,
                                    "Identifier": "com.apple.iokit.IONVMeFamily", "MaxKernel": "", "MinKernel": "", "Strategy": "Disable"})
# Cache sharing/cores per package for XNU (tools/make_cachefix.py): without it every logical CPU gets its own processor set and cpus>1 deadlocks.
# CACHEFIX=0 leaves the legacy AMD fallback.
if os.environ.get("CACHEFIX", "1") != "0":
    sys.path.insert(0, str(ROOT / "tools"))
    import make_cachefix
    cfg["Kernel"]["Patch"] = make_cachefix.patches() + cfg["Kernel"]["Patch"]
# AMD's APIC interrupt-enable registers (tools/make_ierfix.py): without this no interrupt reaches the core. IERFIX=0 leaves them.
if os.environ.get("IERFIX", "1") != "0":
    sys.path.insert(0, str(ROOT / "tools"))
    import make_ierfix
    cfg["Kernel"]["Patch"] = make_ierfix.patches() + cfg["Kernel"]["Patch"]
# QUIET=1 (no KTTY): the normal boot. -v stays (XNU's own console shows the boot text until WindowServer takes the screen), the serial probe goes.
if os.environ.get("QUIET") == "1":
    k = "7C436110-AB2A-4BBB-A880-FE41995C9F82"
    args = [a for a in cfg["NVRAM"]["Add"][k]["boot-args"].split() if a != "serial=3"]
    if os.environ.get("CPUS"): args.append("cpus=" + os.environ["CPUS"])
    if os.environ.get("CPUS", "1") != "1": args.append("-topo")      # XNU prints the topology it builds (one line per cache/pset)
    cfg["NVRAM"]["Add"][k]["boot-args"] = " ".join(args)
# KTTY=1: show the whole kernel console (printf/kprintf) on the screen, see bringup/ktty and tools/make_ktty.py
if os.environ.get("KTTY") == "1":
    sys.path.insert(0, str(ROOT / "tools"))
    import make_ktty
    cfg["Kernel"]["Patch"] = make_ktty.patches() + cfg["Kernel"]["Patch"]
    args = cfg["NVRAM"]["Add"]["7C436110-AB2A-4BBB-A880-FE41995C9F82"]["boot-args"]
    # slto_us: the console paints each character through I/O ports (slow) with kernel locks held; the default 0.1 s ticket-lock
    # watchdog would panic ("Ticket spinlock ... timeout")
    cfg["NVRAM"]["Add"]["7C436110-AB2A-4BBB-A880-FE41995C9F82"]["boot-args"] = (
        args if "serial=" in args else args + " serial=3") + " slto_us=10000000 msgbuf=2097152" + (" cpus=" + os.environ["CPUS"] if os.environ.get("CPUS") else "") + (" io=" + os.environ["IOLOG"] if os.environ.get("IOLOG") else "")
plistlib.dump(cfg, open(OUT / "OC/config.plist", "wb"))
print("EFI written to", OUT)
for p in sorted(OUT.rglob("*")):
    if p.is_file():
        print(f"  {p.relative_to(OUT)}  {p.stat().st_size}")
