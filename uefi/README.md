# PS5 UEFI layer

Goal: give OpenCore (and macOS) a UEFI environment on the bare PS5, entered from the stage-1 stub that
`ps5-linux-loader` -> Linux crash-kexec hands control to (see `bringup/`).

```
ps5-linux-loader -> Linux (brings the display up) -> sysrq-c crash kexec -> stage 1 (bringup/stub.c)
                 -> EDK2 UefiPayloadPkg (this directory) -> OpenCore -> macOS
```

## Build

```bash
docker build -t ps5-edk2 uefi            # once: Ubuntu + clang/lld/nasm/iasl
git clone --depth 1 --branch edk2-stable202505 --recurse-submodules --shallow-submodules https://github.com/tianocore/edk2.git build/edk2
uefi/build_upl.sh -b RELEASE -l 1744830464   # -l is the load address in DECIMAL (0x68000000)
```

Output: `build/edk2/Build/UefiPayloadPkgX64/UniversalPayload.elf` (PIE ELF, entry `_ModuleEntryPoint(HobList)` with the UEFI
(MS x64) calling convention, `.upld.uefi_fv` = DXE FV ~2 MiB, `.upld.bds_fv`).

## What stage 1 has to provide (HOB list)

PHIT, resource descriptors (RAM, MMIO, reserved), CPU HOB, `gUniversalPayloadExtraDataGuid` (FV bases), ACPI RSDP
(`gUniversalPayloadAcpiTableGuid`, Sony's RSDP at 0x7fd8e014), graphics info (2560x1440 XR24, base 0x46a000000,
pitch 10240), PCI root bridge info.

## Platform facts (verified on the console)

* Framebuffer = VRAM carve-out in system RAM: VRAM offset N is physical 0x450000000 + N. A linear scanout buffer sits at
  0x46a000000 after `bringup/kms_linear.py` ran; the CPU writes it directly (UC mapping).
* PCI config via ports 0xCF8/0xCFC; buses 00, 20 (GPU, AMD USB), 40 (Sony Salina + M.2 NVMe 2646:5017 at 40:02.5).
* e820/ACPI layout: see memory notes. ACPI reclaim 0x7fd6f000-0x7fd8efff, NVS 0x7fd67000-0x7fd6efff.
* Timer: TSC at 1596.3 MHz, LAPIC at 0xfee00000; no PIT/HPET/RTC/IOAPIC visible.
