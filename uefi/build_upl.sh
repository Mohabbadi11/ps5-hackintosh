#!/bin/bash
#
# Build the EDK2 Universal Payload (UefiPayloadPkg) for the PS5 inside the ps5-edk2 Docker image, with the PS5 console
# (uefi/Ps5Pkg, text drawn into the display carve-out) swapped in for the 16550 serial port.
#
# Usage: uefi/build_upl.sh [extra UniversalPayloadBuild.py args]
# Needs build/edk2 (git clone --recurse-submodules https://github.com/tianocore/edk2, tag edk2-stable202505).
# Output: build/edk2/Build/UefiPayloadPkgX64/UniversalPayload.elf

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EDK2="$ROOT/build/edk2"
[ -d "$EDK2/BaseTools" ] || { echo "ERROR: $EDK2 not found"; exit 1; }

docker run --rm -v "$EDK2:/work/edk2" -v "$ROOT/uefi:/work/ps5:ro" -w /work/edk2 ps5-edk2 bash -lc '
    set -e
    [ -x BaseTools/Source/C/bin/GenFw ] || make -C BaseTools/Source/C -j8
    ARGS=("$@"); set --
    export PACKAGES_PATH=/work/edk2:/work/ps5
    source edksetup.sh >/dev/null
    python3 - <<PY
import re
s = open("UefiPayloadPkg/UefiPayloadPkg.dsc").read()
s = re.sub(r"(?m)^(\s*)SerialPortLib\|.*$", r"\1SerialPortLib|Ps5Pkg/Library/Ps5FbSerialPortLib/Ps5FbSerialPortLib.inf", s)
s = re.sub(r"(?m)^(\s*)PlatformHookLib\|UefiPayloadPkg/Library/PlatformHookLib/PlatformHookLib.inf",
           r"\1PlatformHookLib|MdeModulePkg/Library/BasePlatformHookLibNull/BasePlatformHookLibNull.inf", s)
s = re.sub(r"(?m)^(\s*)ResetSystemLib\|UefiPayloadPkg/Library/ResetSystemLib/ResetSystemLib.inf",
           r"\1ResetSystemLib|Ps5Pkg/Library/Ps5ResetSystemLib/Ps5ResetSystemLib.inf", s)
s = re.sub(r"(?m)^(\s*)TimerLib\|.*$", r"\1TimerLib|Ps5Pkg/Library/Ps5TscTimerLib/Ps5TscTimerLib.inf", s)
# the PS5 has no CMOS RTC: swap the PC RTC driver for the generic one backed by a software clock
s = s.replace("  PcAtChipsetPkg/PcatRealTimeClockRuntimeDxe/PcatRealTimeClockRuntimeDxe.inf",
              "  EmbeddedPkg/RealTimeClockRuntimeDxe/RealTimeClockRuntimeDxe.inf")
s = re.sub(r"(?m)^(\s*)TimerLib\|(Ps5Pkg/.*)$",
           r"\1TimerLib|\2\n\1RealTimeClockLib|Ps5Pkg/Library/Ps5RealTimeClockLib/Ps5RealTimeClockLib.inf\n"
           r"\1TimeBaseLib|EmbeddedPkg/Library/TimeBaseLib/TimeBaseLib.inf", s, count=1)
s = re.sub(r"(?m)^(\s*)PciSegmentLib\|.*$", r"\1PciSegmentLib|MdePkg/Library/BasePciSegmentLibPci/BasePciSegmentLibPci.inf", s)
s = re.sub(r"(?m)^.*gPcAtChipsetPkgTokenSpaceGuid\.PcdRtc.*\n", "", s)    # RTC ports are unused now
s = s.replace("UefiPayloadPkg/UefiPayloadPkg.fdf", "UefiPayloadPkg/Ps5Payload.fdf")
open("UefiPayloadPkg/Ps5Payload.dsc", "w").write(s)
f = open("UefiPayloadPkg/UefiPayloadPkg.fdf").read()
f = f.replace("  INF PcAtChipsetPkg/PcatRealTimeClockRuntimeDxe/PcatRealTimeClockRuntimeDxe.inf",
              "  INF EmbeddedPkg/RealTimeClockRuntimeDxe/RealTimeClockRuntimeDxe.inf")
open("UefiPayloadPkg/Ps5Payload.fdf", "w").write(f)
PY
    python3 UefiPayloadPkg/UniversalPayloadBuild.py -t CLANGDWARF -c UefiPayloadPkg/Ps5Payload.dsc \
        -D TIMER_SUPPORT=LAPIC -D SERIAL_DRIVER_ENABLE=FALSE -D PS2_KEYBOARD_ENABLE=FALSE -D PS2_MOUSE_ENABLE=FALSE \
        -D SD_ENABLE=FALSE -D ATA_ENABLE=FALSE -D NETWORK_DRIVER_ENABLE=FALSE -D MAX_LOGICAL_PROCESSORS=1 -D PCIE_BASE_SUPPORT=FALSE "${ARGS[@]}"
' bash "$@"
