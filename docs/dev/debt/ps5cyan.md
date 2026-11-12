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
- **Orphaned Memory Reuse Cache**: To protect against differing kernel structure layouts across macOS versions (Monterey vs Tahoe), clearing bit 28 (`0x10000000`) of `IOGraphicsAccelerator2` config at `device + 0xC90` is guarded behind the explicit boot argument `-ps5cyanreuseoff`. When enabled, it forces freed VRAM to return immediately to the system instead of lingering in the orphaned-memory pool.

### Stage 5: DCN 2.0.1 HDMI Framebuffer Scanout and Pipe Split Suppression
On the PS5 AMD Oberon APU, display scanout is handled by DCN 2.0.1 silicon, which presents two fundamental architectural divergence points from discrete Navi 10 (DCN 2.0):

1. **Physical Pipe Topology & Split Suppression**:
   - Discrete Navi 10 provides 6 hardware display pipes, whereas DCN 2.0.1 silicon provides only 4 display pipes (pipes 0–3).
   - Stock Apple DAL display logic attempts MPC (Multi-Pipe Combiner) pipe splitting to distribute high-pixel-rate surfaces across two pipes, directing secondary pipe requests onto pipe 4 or pipe 5. Because pipe 5 does not exist on DCN 2.0.1, the secondary stream is lost, resulting in half-screen blanking or display corruption.
   - `PS5Cyan` locates the internal, unexported DAL routine `dcn20_validate_apply_pipe_split_flags` in `AMDRadeonX6000Framebuffer` by searching for RIP-relative LEA references to its signature string (`"int dcn20_validate_apply_pipe_split_flags(struct dc *, struct dc_state *, int, int *, _Bool *)"`) and resolving backwards to its function prologue.
   - `wrapApplyPipeSplitFlags` calls the original validation routine to compute the target voltage level, and subsequently clears `split[i] = 0` for all 6 pipe indices (`kMaxPipes = 6`). This suppresses MPC pipe splitting entirely and enforces 1 pipe per stream matching GOP firmware behavior.

2. **UMA Scanout Address Translation**:
   - Discrete Navi 10 employs a dedicated DCN_VM aperture where display HUBP reads addresses in the GPU MC aperture.
   - Cyan Skillfish DCN 2.0.1 lacks a DCN_VM translation engine; its HUBP DMA read engines fetch display pixels directly from system physical memory (GDDR6 carveout).
   - `PS5Cyan` intercepts three `AMDRadeonX6000_AmdDalHelper` routines in `AMDRadeonX6000Framebuffer`:
     - `prepareDalDisplaySurfaceParameters` (`__ZN27AMDRadeonX6000_AmdDalHelper34prepareDalDisplaySurfaceParametersEPK16AmdFbDisplayPathP20AmdFalconUpdatePlane`): Scans the first `0x200` bytes of `AmdFalconUpdatePlane` and translates MC aperture addresses (`0xF400000000ULL`) to system physical GDDR6 carveout addresses (`gvmFbOffset`) so DAL registers receive UMA addresses.
     - `updateSurfaceInfo` (`__ZN27AMDRadeonX6000_AmdDalHelper17updateSurfaceInfoEPK20AmdFalconUpdatePlanePK16AmdFbDisplayPath`): Scans and translates MC aperture addresses in the plane descriptor, executes the original DAL update routine, and restores original values afterwards to preserve driver state.
     - `setCursorImage` (`__ZN27AMDRadeonX6000_AmdDalHelper14setCursorImageEPK21AmdFbCursorDescriptor`): Scans the first `0x80` bytes of the cursor descriptor, translates MC addresses to UMA carveout addresses, executes the original hardware cursor programming, and restores original descriptor values afterwards.
   - `toUMA` and `translateWindow`: Validates candidate words against the MC aperture window `[gvmFbBase, gvmFbBase + gvmFbSize)` (default base `0xF400000000ULL`). Because the 64-bit MC aperture is far above normal scalar integers (width, height, stride, format), scalar fields are completely immune to false-positive translation.

### Hook Verification and Fault Isolation
To ensure complete visibility and avoid silent hook failures, every route request in `kextAccel` and `kextFB` is individually evaluated and logged:
- Each routine reports `Successfully routed accelerator hook <symbol>` on success.
- Any unresolved symbol or failed detour reports `Failed to route accelerator hook <symbol> (<error_code>)` and clears the patcher error state to allow remaining hooks to proceed independently.
- `publishHdaGfx` includes a one-time execution guard and strictly adheres to IOKit ownership semantics (`IOService::getMatchingServices` consumes the matching dictionary reference; manual over-release eliminated).

### Boot Arguments
- `-ps5cyanoff`: Disables the plugin completely.
- `-ps5cyandbg`: Enables verbose SYSLOG kernel messages.
- `-ps5cyanbeta`: Allows loading on kernel versions outside Monterey.
- `-ps5cyanreuseoff`: Enables clearing of the orphaned-memory pool reuse cache bit (0x10000000) at device + 0xC90.
- `-ps5vram=<size_in_mb>`: Sets the VRAM carve-out size in MiB (e.g. `512`, `1024`, `4096`).
- `-ps5vrambase=0x...`: Overrides the physical carve-out base address.
- `-ps5vramsize=0x...`: Overrides the carve-out size in bytes.
- `-ps5vrammc=0x...`: Overrides the MC aperture base address (default `0xF400000000`).

## 3. Status Categorization: Implemented vs. Hardware Verification Milestones

### A. Implemented & CI-Verified (Compiler & Linker passing on real macOS 15 / Xcode 16.4)
- **Personality Matching**: `IOPCIMatch = 0x13fc1002` with `IOProbeScore = 65535` across HWServices, Accel, and Framebuffer.
- **PowerPlay Isolation**: Complete interception of `createPowerPlayInterface` returning 0, blocking SMU mailbox calls.
- **ASIC Hang Reset Guard**: Interception of `resetHardwareAndReplay`, `resetHardware`, and `dumpASICHangState` returning 0.
- **Metal Clock Injection**: `wrapAccelHwInfo` populating 100 MHz Ref, 2000 MHz GFX, 1750 MHz Mem, and clearing `0xE00002BC`.
- **GVM Physical Translation Layer**: `getPdeValue`, `getPteValue`, `decodePte`, `updateContiguousPTEsWithDMAUsingAddr`, `fillMapProcessPacket`, and `prepareVMInvalidateRequest` translating VRAM addresses to physical carveout (`0x470000000 - size`).
- **DCN 2.0.1 Pipe Split Suppression**: Prologue back-trace pattern match resolving `dcn20_validate_apply_pipe_split_flags` and clearing `split[i] = 0`.
- **UMA Scanout Address Translation**: Intercepting plane and cursor descriptors in `AMDRadeonX6000_AmdDalHelper` to map MC addresses to physical carveout.
- **Audio Device Pairing**: `publishHdaGfx()` dynamic injection and OpenCore `DeviceProperties` injection of `hda-gfx = onboard-1`.

### B. Hardware Verification Milestones (Requiring Bare-Metal PS5 Console Execution)
- **Milestone 1 (Metal 3 Shader Execution)**: Booting to macOS desktop, verifying `MTLDevice` instantiation without WindowServer fallback, running Metal compute/render shaders, and measuring sustained stability.
- **Milestone 2 (DCN 2.0.1 Hardware Scanout Lock)**: Verifying physical HDMI display synchronization at 1080p/4K@60Hz on a TV screen without tearing or pipe timing faults.
- **Milestone 3 (AppleGFXHDA Audio Packet Playback)**: Confirming television audio output recognition in macOS Sound preferences and audio stream stability through HDMI.
- **Milestone 4 (DualSense USB Audio Enumeration)**: Verifying physical controller 3.5mm TRRS audio output and microphone capture via native `AppleUSBAudio`.

## 4. Known Limitations & Technical Debt
- **GC 10.1.3 Identification**: Navi 10 uses GC 10.1.0; Cyan Skillfish reports GC 10.1.3. Once claimed, `HWLibs` version check requires topology remapping.
- **DCN DENTIST Clocks**: Stock DAL sizes DENTIST clock dividers assuming Navi 10's ~3.6 GHz VCO. For standard HDMI modes, GOP divider initialization carries the display; high refresh modes may require active DENTIST divider scaling.
- **HDMI Audio**: Digital HDMI audio endpoint binding is managed via AppleGFXHDA with `hda-gfx` property injection (`onboard-1`) published on the GPU provider PCI device and OpenCore DeviceProperties. Detailed architecture, DualSense USB Audio fallback, and BlackHole loopback are documented in `docs/dev/debt/ps5audio.md`.
