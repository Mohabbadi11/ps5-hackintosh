#!/bin/bash
# Build the three throw-away probe kexts (A plain, B uses PCI/networking symbols, C derives from IOEthernetController) into build/kexts-probe/.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SDK="$(xcrun --show-sdk-path)"
KH="$SDK/System/Library/Frameworks/Kernel.framework/Headers"
OUTD="$ROOT/build/kexts-probe"
rm -rf "$OUTD" && mkdir -p "$OUTD"
build() {  # name defines libs
    local name="$1" def="$2" libs="$3"
    local out="$OUTD/$name.kext"
    mkdir -p "$out/Contents/MacOS"
    python3 - "$name" "$libs" "$out/Contents/Info.plist" <<'PY'
import plistlib, sys
name, libs, path = sys.argv[1:4]
L = {"com.apple.kpi.bsd": "8.0.0", "com.apple.kpi.iokit": "8.0.0", "com.apple.kpi.libkern": "8.0.0", "com.apple.kpi.mach": "8.0.0"}
if libs == "net":
    L.update({"com.apple.iokit.IONetworkingFamily": "1.5.0", "com.apple.iokit.IOPCIFamily": "2.9", "com.apple.kpi.unsupported": "8.0.0"})
bid = "local.ps5.probe." + name
plistlib.dump({
    "CFBundleDevelopmentRegion": "en", "CFBundleExecutable": name, "CFBundleIdentifier": bid, "CFBundleInfoDictionaryVersion": "6.0",
    "CFBundleName": name, "CFBundlePackageType": "KEXT", "CFBundleShortVersionString": "1.0", "CFBundleVersion": "1.0.0",
    "IOKitPersonalities": {name: {"CFBundleIdentifier": bid, "IOClass": name, "IOProviderClass": "IOResources", "IOResourceMatch": "IOBSD"}},
    "OSBundleLibraries": L, "OSBundleRequired": "Root"}, open(path, "wb"))
PY
    xcrun clang++ -arch x86_64 -mmacosx-version-min=12.0 -isysroot "$SDK" -std=c++17 -O2 -fno-builtin -fno-rtti -fno-exceptions -fno-common -fapple-kext -mkernel \
        -nostdlibinc -I"$KH" -I"$KH/libkern/c++" -DKERNEL -DKERNEL_PRIVATE -DDRIVER_PRIVATE -DAPPLE -DNeXT -Wno-inconsistent-missing-override -Wno-deprecated-declarations \
        -DSTR2\(x\)=\#x -DSTR\(x\)=STR2\(x\) -DPROBE_NAME="$name" -DPROBE_ETH="${name}Eth" $def -c "$ROOT/kexts/probe/probes.cpp" -o "$OUTD/$name.o"
    sed "s/PS5SalinaGbE/$name/g; s/local.ps5.driver.$name/local.ps5.probe.$name/g" "$ROOT/kexts/PS5SalinaGbE/kmod.cpp" > "$OUTD/$name.kmod.cpp"
    xcrun clang++ -arch x86_64 -mmacosx-version-min=12.0 -isysroot "$SDK" -std=c++17 -O2 -fno-builtin -fno-rtti -fno-exceptions -fno-common -fapple-kext -mkernel \
        -nostdlibinc -I"$KH" -DKERNEL -DKERNEL_PRIVATE -DDRIVER_PRIVATE -DAPPLE -DNeXT -c "$OUTD/$name.kmod.cpp" -o "$OUTD/$name.kmod.o"
    xcrun ld -arch x86_64 -kext -static -no_data_const -macos_version_min 12.0 -syslibroot "$SDK" -o "$out/Contents/MacOS/$name" \
        "$OUTD/$name.o" "$OUTD/$name.kmod.o" -lkmod -lkmodc++ 2>/dev/null
    nm "$out/Contents/MacOS/$name" | grep -q " _kmod_info" || { echo "no kmod_info in $name" >&2; exit 1; }
    rm -f "$OUTD/$name".*.o "$OUTD/$name.o" "$OUTD/$name.kmod.cpp"
    echo "built $out"
}
build PS5ProbeA "-DPROBE_A" plain
build PS5ProbeB "-DPROBE_B" net
build PS5ProbeC "-DPROBE_C" net
