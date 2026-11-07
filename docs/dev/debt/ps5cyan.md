# Technical Debt & Architecture: PS5Cyan Lilu Plugin

## 1. Overview and Purpose
`PS5Cyan` is a Lilu plugin kernel extension engineered specifically for macOS Monterey (XNU 21.6.0) on the PlayStation 5 AMD Oberon APU (Zen 2 + Cyan Skillfish GPU, PCI `1002:13fc`).

Its architectural goal is to adapt Apple's stock `AMDRadeonX6000` driver family for the PS5's customized RDNA 1 silicon without requiring a from-scratch driver implementation.

## 2. Step 1 & Step 2 Architecture: Device Binding and SMU Isolation

### Hardware Constraint
The PS5 GPU lacks a standard PC AMD SMU (System Management Unit / MP1) interface accessible to the OS. On the PS5, the SMU mailbox is locked down and owned exclusively by Sony's secure crypto coprocessor / power management firmware. If Apple's `AMDRadeonX6000` driver attempts to send Navi 10 SMU messages (clocks, voltages, fan speeds), the console hard-locks or triggers an immediate kernel panic.

### Implementation Details
1. **Device Binding (Stage 1)**:
   Apple's stock `AMDRadeonX6000` kexts do not include `0x13fc1002` in their `IOPCIMatch` dictionaries. `PS5Cyan` declares personalities for:
   - `com.apple.kext.AMDRadeonX6000HWServices` (`AMDRadeonX6000_AMDRadeonHWServices`)
   - `com.apple.kext.AMDRadeonX6000` (`AMDRadeonX6000_AMDNavi10GraphicsAccelerator`)
   - `com.apple.kext.AMDRadeonX6000Framebuffer` (`AMDRadeonX6000_AMDFramebuffer`)
   with `IOPCIMatch = 0x13fc1002` and `IOProbeScore = 65535` so `IOPCIFamily` matches and attaches the AMD driver stack.

2. **PowerPlay Isolation and Hang Reset Guard (Stage 2)**:
   `PS5Cyan` intercepts the PowerPlay interface constructors:
   - `__ZN42AMDRadeonX6000_AMDRadeonHWServicesAbstract24createPowerPlayInterfaceEP18PowerPlayCallbacks`
   - `__ZN30AMDRadeonX6000_AMDRadeonHWLibs24createPowerPlayInterfaceEP18PowerPlayCallbacks`
   and routes them to `blockPowerPlay()`, which returns `0` (null) immediately. As a result, no PowerPlay object is created, and no SMU mailbox message is ever generated.

   In addition, `PS5Cyan` intercepts ASIC hang-recovery routines in `AMDRadeonX6000`:
   - `__ZN30AMDRadeonX6000_AMDAccelChannel22resetHardwareAndReplayEv`
   - `__ZN26AMDRadeonX6000_AMDHardware13resetHardwareEjPj`
   - `__ZN26AMDRadeonX6000_AMDHardware17dumpASICHangStateEb`
   routing them to `blockHangReset()` (returns `0`) to prevent Apple's hang recovery from sending SMU reset messages that hang the console.

3. **Boot Arguments**:
   - `-ps5cyanoff`: Disables the plugin completely.
   - `-ps5cyandbg`: Enables verbose SYSLOG kernel messages.
   - `-ps5cyanbeta`: Allows loading on kernel versions outside Monterey.

## 3. Known Limitations & Technical Debt
- **GC 10.1.3 Identification**: Navi 10 uses GC 10.1.0; Cyan Skillfish reports GC 10.1.3. Once claimed, `HWLibs` version check requires a bypass hook (Stage 3).
- **Metal Clocks**: Because PowerPlay is stubbed, clock queries return zero. `AMDAccelDevice::getHardwareInfo` requires dummy clock injection to prevent `WindowServer` Metal device creation failure (Stage 3).
- **VRAM Carve-out**: Unified GDDR6 carveout (base `0x470000000 - size`) requires GVM page-table translation (Stage 4).
- **Display Scanout**: DCN 2.0.1 pipe 5 split elimination and HDMI scanout mapping pending (Stage 5).
