#!/bin/bash
# Build kexts/PS5SalinaGbE into build/kexts/PS5SalinaGbE.kext (needs Xcode with the macOS SDK; the kext is loaded by OpenCore).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/kexts/PS5SalinaGbE"
OUT="$ROOT/build/kexts/PS5SalinaGbE.kext"
SDK="$(xcrun --show-sdk-path)"
KH="$SDK/System/Library/Frameworks/Kernel.framework/Headers"
# The Xcode 26 SDK declares IONetworkController slots 6 and 7 (allocatePacketNoWait, setHardwareAssists) as used; on Monterey they are still padding.
# OpenCore's vtable patcher then refuses every IOEthernetController subclass ("Failed to patch symbol ...allocatePacketNoWait", the kext is silently
# left out). Build against a copy of the header that keeps them as padding.
OVL="$ROOT/build/kext-overlay"
rm -rf "$OVL" && mkdir -p "$OVL/IOKit/network"
python3 - "$KH/IOKit/network/IONetworkController.h" "$OVL/IOKit/network/IONetworkController.h" <<'PY'
import sys
s = open(sys.argv[1]).read()
for old, new in (("    virtual mbuf_t allocatePacketNoWait(UInt32 size);\n", ""),
                 ("OSMetaClassDeclareReservedUsed( IONetworkController,  6);", "OSMetaClassDeclareReservedUnused( IONetworkController,  6);"),
                 ("    virtual IOReturn setHardwareAssists( UInt32 hardwareAssists, UInt32 hardwareAssistsMask )\n", ""),
                 ("OSMetaClassDeclareReservedUsed( IONetworkController,  7);", "OSMetaClassDeclareReservedUnused( IONetworkController,  7);")):
    assert s.count(old) == 1, old
    s = s.replace(old, new)
open(sys.argv[2], "w").write(s)
PY
rm -rf "$OUT" && mkdir -p "$OUT/Contents/MacOS"
cp "$SRC/Info.plist" "$OUT/Contents/Info.plist"
xcrun clang++ -arch x86_64 -mmacosx-version-min=12.0 -isysroot "$SDK" -std=c++17 -O2 -Wall -Wno-unused-private-field -Wno-inconsistent-missing-override -Wno-deprecated-declarations -Wno-sign-conversion -Wno-implicit-int-conversion \
    -fno-builtin -fno-rtti -fno-exceptions -fno-common -fapple-kext -mkernel -nostdlibinc \
    -I"$OVL" -I"$KH" -I"$KH/libkern/c++" -DKERNEL -DKERNEL_PRIVATE -DDRIVER_PRIVATE -DAPPLE -DNeXT \
    -c "$SRC/PS5SalinaGbE.cpp" -o "$OUT/../PS5SalinaGbE.o"
xcrun clang++ -arch x86_64 -mmacosx-version-min=12.0 -isysroot "$SDK" -std=c++17 -O2 -fno-builtin -fno-rtti -fno-exceptions -fno-common -fapple-kext -mkernel \
    -nostdlibinc -I"$KH" -DKERNEL -DKERNEL_PRIVATE -DDRIVER_PRIVATE -DAPPLE -DNeXT -c "$SRC/kmod.cpp" -o "$OUT/../kmod.o"
xcrun ld -arch x86_64 -kext -static -no_data_const -macos_version_min 12.0 -syslibroot "$SDK" \
    -o "$OUT/Contents/MacOS/PS5SalinaGbE" "$OUT/../PS5SalinaGbE.o" "$OUT/../kmod.o" -lkmod -lkmodc++
# a kext without kmod_info is silently skipped by the prelinker
nm "$OUT/Contents/MacOS/PS5SalinaGbE" | grep -q " _kmod_info" || { echo "no kmod_info in the kext" >&2; exit 1; }
echo "built $OUT"
