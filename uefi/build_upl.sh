#!/bin/bash
#
# Build the EDK2 Universal Payload (UefiPayloadPkg) for the PS5 inside the ps5-edk2 Docker image.
#
# Usage: uefi/build_upl.sh [extra UniversalPayloadBuild.py args]
# Needs build/edk2 (git clone --recurse-submodules https://github.com/tianocore/edk2, tag edk2-stable202505).
# Output: build/edk2/Build/UefiPayloadPkgX64/UniversalPayload.elf

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EDK2="$ROOT/build/edk2"
[ -d "$EDK2/BaseTools" ] || { echo "ERROR: $EDK2 not found"; exit 1; }

docker run --rm -v "$EDK2:/work/edk2" -w /work/edk2 ps5-edk2 bash -lc '
    set -e
    [ -x BaseTools/Source/C/bin/GenFw ] || make -C BaseTools/Source/C -j8
    ARGS=("$@"); set --
    source edksetup.sh
    python3 UefiPayloadPkg/UniversalPayloadBuild.py -t CLANGDWARF "${ARGS[@]}"
' bash "$@"
