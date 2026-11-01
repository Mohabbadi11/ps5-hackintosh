#!/bin/bash
# Build kexts/PS5Cyan (a Lilu plugin) into build/kexts/PS5Cyan.kext. Needs Xcode with the macOS SDK and the Lilu sources (BSD-3-Clause), fetched
# to build/ext/Lilu-src at the version the EFI ships.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NAME=PS5Cyan
SRC="$ROOT/kexts/$NAME"
LILU_VERSION=1.7.2
LILU="$ROOT/build/ext/Lilu-src"
MKSDK="$ROOT/build/ext/MacKernelSDK"       # Lilu's headers insist on acidanthera's MacKernelSDK (BSD-3-Clause) instead of the Xcode kernel headers
mkdir -p "$ROOT/build/ext"
[ -d "$LILU/Lilu/Headers" ] || git clone -q --depth 1 --branch "$LILU_VERSION" https://github.com/acidanthera/Lilu.git "$LILU" 2>/dev/null
[ -d "$MKSDK/Headers" ] || git clone -q --depth 1 https://github.com/acidanthera/MacKernelSDK.git "$MKSDK" 2>/dev/null
OUT="$ROOT/build/kexts/$NAME.kext"
SDK="$(xcrun --show-sdk-path)"
rm -rf "$OUT" && mkdir -p "$OUT/Contents/MacOS"
cp "$SRC/Info.plist" "$OUT/Contents/Info.plist"
CXXFLAGS=(-arch x86_64 -mmacosx-version-min=12.0 -isysroot "$SDK" -std=c++17 -O2 -Wall -Wno-unused-private-field -Wno-inconsistent-missing-override -Wno-deprecated-declarations
          -fno-builtin -fno-rtti -fno-exceptions -fno-common -fapple-kext -mkernel -nostdlibinc -I"$LILU/Lilu" -I"$LILU" -I"$MKSDK/Headers"
          -D__ACIDANTHERA_MAC_SDK -DKERNEL -DKERNEL_PRIVATE -DDRIVER_PRIVATE -DAPPLE -DNeXT -DLILU_KEXTPATCH_SUPPORT=1 -DPRODUCT_NAME=$NAME -DMODULE_VERSION=0.1.0 -DDEBUG=0)
OBJ="$ROOT/build/kexts/$NAME-obj"; rm -rf "$OBJ"; mkdir -p "$OBJ"
xcrun clang++ "${CXXFLAGS[@]}" -c "$SRC/kern_start.cpp" -o "$OBJ/kern_start.o"
xcrun clang++ "${CXXFLAGS[@]}" -c "$LILU/Lilu/Library/plugin_start.cpp" -o "$OBJ/plugin_start.o"
xcrun clang++ "${CXXFLAGS[@]}" -c "$SRC/kmod.cpp" -o "$OBJ/kmod.o"
xcrun ld -arch x86_64 -kext -static -no_data_const -macos_version_min 12.0 -syslibroot "$SDK" -o "$OUT/Contents/MacOS/$NAME" "$OBJ"/*.o -L"$MKSDK/Library/x86_64" -lkmod -lkmodc++
nm "$OUT/Contents/MacOS/$NAME" | grep -q " _kmod_info" || { echo "no kmod_info in the plugin" >&2; exit 1; }
if nm "$OUT/Contents/MacOS/$NAME" | grep -q "chkstk"; then echo "the plugin calls ___chkstk_darwin" >&2; exit 1; fi
echo "built $OUT"
