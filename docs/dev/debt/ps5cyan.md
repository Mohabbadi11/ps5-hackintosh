# Technical Debt & Architecture: PS5Cyan Lilu Plugin

## 1. Overview and Purpose
`PS5Cyan` is a Lilu plugin kernel extension engineered specifically for macOS Monterey (XNU 21.6.0) on the PlayStation 5 AMD Oberon APU (Zen 2 + Cyan Skillfish GPU, PCI `1002:13fc`).

Its architectural goal is to adapt Apple's stock `AMDRadeonX6000` driver family for the PS5's customized RDNA 1 silicon without requiring a from-scratch driver implementation.

## 2. Implemented Stages & Architecture

### Stage 1: Device Binding
Apple's stock `AMDRadeonX6000` kexts do not include `0x13fc1002` in their `IOPCIMatch` dictionaries. `PS5Cyan` declares personalities for:
- `com.apple.kext.AMDRadeonX6000HWServices` (`AMDRadeonX6000_AMDRadeonHWServices`)
- `com.apple.kext.AMDRadeonX6000` (`AMDRadeonX6000_AMDNavi10GraphicsAccelerator`)
- `com.apple.kext.AMDRadeonX6000Framebuffer` (`AMDRadeonX6000_AMDFramebuffer`)
with `IOPCIMatch = 0x13fc1002` and `IOProbeScore = 65535` so `IOPCIFamily` matches and attaches the AMD driver stack.

### Stage 2: PowerPlay Isolation and Hang Reset Guard
`PS5Cyan` intercepts the PowerPlay interface constructors:
- `__ZN42AMDRadeonX6000_AMDRadeonHWServicesAbstract24createPowerPlayInterfaceEP18PowerPlayCallbacks`
- `__ZN30AMDRadeonX6000_AMDRadeonHWLibs24createPowerPlayInterfaceEP18PowerPlayCallbacks`
and routes them to `blockPowerPlay()`, which returns `0` (null) immediately. As a result, no PowerPlay object is created, and no SMU mailbox message is ever generated.

In addition, `PS5Cyan` intercepts ASIC hang-recovery routines in `AMDRadeonX6000`:
- `__ZN30AMDRadeonX6000_AMDAccelChannel22resetHardwareAndReplayEv`
- `__ZN26AMDRadeonX6000_AMDHardware13resetHardwareEjPj`
- `__ZN26AMDRadeonX6000_AMDHardware17dumpASICHangStateEb`
routing them to `blockHangReset()` (returns `0`) to prevent Apple's hang recovery from sending SMU reset messages that hang the console.

### Stage 3: Metal Hardware Clocks Injection
Because PowerPlay/SMU queries are blocked, Apple's hardware clock queries return zero. `AMDAccelDevice::getHardwareInfo` (`__ZN29AMDRadeonX6000_AMDAccelDevice15getHardwareInfoEP24_sAMD_GET_HW_INFO_VALUES`) rejects zero clocks with error code `0xE00002BC` (`kIOReturnError`), causing `WindowServer` to crash with `"Failed to create MetalDevice"`.
`PS5Cyan` intercepts `getHardwareInfo` and populates the expected clock offsets:
- `0xC0`: Reference clock = 10,000 (100 MHz in 10 kHz units)
- `0xC8`: System/GFX clock = 200,000 (2000 MHz in 10 kHz units)
- `0xD0`: Memory clock = 175,000 (1750 MHz in 10 kHz units)
- `0xD8`: CG Reference clock = 10,000 (100 MHz in 10 kHz units)
and resets the return value to `0` (`kIOReturnSuccess`), enabling the user-space Metal driver (`AMDRadeonX6000MTLDriver.bundle`) to instantiate the `MTLDevice`.

### Stage 4: VRAM Carve-out & GVM Page Tables Translation
On the PS5, Cyan Skillfish (`1002:13fc`) is an APU that uses unified GDDR6 memory. The loader establishes a physical memory carve-out growing downward from `0x470000000` (`base = 0x470000000 - size`).
Apple's stock `AMDRadeonX6000` driver assumes discrete VRAM starting at physical address 0. As a result, page table entries (PTE/PDE) and HIQ process maps point to unmapped physical memory, triggering immediate hardware faults.

`PS5Cyan` implements the complete GVM physical translation layer:
- `vramPhys(address)`: Converts local VRAM offsets to physical carve-out addresses (`address + gvmFbOffset`).
- `wrapGetPdeValue` (`__ZN26AMDRadeonX6000_AMDGFX10VMM11getPDEValueE15eAMD_VMPT_LEVELy`): Translates PDE page-table blocks to the physical carveout.
- `wrapGetPteValue` (`__ZN26AMDRadeonX6000_AMDGFX10VMM11getPTEValueE15eAMD_VMPT_LEVELyN24AMDRadeonX6000_IAMDHWVMM10VmMapFlagsEj`): Translates VRAM PTEs (when `kPteSystem` bit 1 is clear).
- `wrapDecodePte` (`__ZN26AMDRadeonX6000_AMDGFX10VMM9decodePTEEyPyPb`): Inverse translation for driver internal address queries.
- `wrapUpdatePtesDma` (`__ZN29AMDRadeonX6000_AMDHWVMContext36updateContiguousPTEsWithDMAUsingAddrEyyyyy`): Translates SDMA contiguous PTE update packets.
- `wrapFillMapProcess` (`__ZN35AMDRadeonX6000_AMDGFX10HIQHWChannel20fillMapProcessPacketEP19PM4_MES_MAP_PROCESSyyjjj`): Translates root page table addresses in HIQ `MAP_PROCESS` packets.
- `wrapPrepareVmInvalidate` (`__ZN26AMDRadeonX6000_AMDGFX10VMM26prepareVMInvalidateRequestEP25AMD_VM_INVALIDATE_REQUESTPK22AMD_VM_INVALIDATE_INFOb`): Adjusts page table addresses in invalidate requests.
- **Orphaned Memory Reuse Cache**: In `wrapAccelHwInfo`, bit 28 (`0x10000000`) of `IOGraphicsAccelerator2` config is cleared. This forces freed VRAM to return immediately to the system instead of getting stuck in the orphaned-memory pool, preventing VRAM leaks and out-of-memory green screens.

### Boot Arguments
- `-ps5cyanoff`: Disables the plugin completely.
- `-ps5cyandbg`: Enables verbose SYSLOG kernel messages.
- `-ps5cyanbeta`: Allows loading on kernel versions outside Monterey.
- `-ps5vram=<size_in_mb>`: Sets the VRAM carve-out size in MiB (e.g. `512`, `1024`, `4096`).
- `-ps5vrambase=0x...`: Overrides the physical carve-out base address.
- `-ps5vramsize=0x...`: Overrides the carve-out size in bytes.

## 3. Known Limitations & Technical Debt
- **GC 10.1.3 Identification**: Navi 10 uses GC 10.1.0; Cyan Skillfish reports GC 10.1.3. Once claimed, `HWLibs` version check requires topology remapping.
- **Display Scanout**: DCN 2.0.1 pipe 5 split elimination and HDMI scanout mapping pending (Stage 5).
