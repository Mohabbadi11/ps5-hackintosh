#!/bin/bash
# Build kexts/PS5SalinaGbE into build/kexts/PS5SalinaGbE.kext (needs Xcode with the macOS SDK; the kext is loaded by OpenCore).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/kexts/PS5SalinaGbE"
OUT="$ROOT/build/kexts/PS5SalinaGbE.kext"
SDK="$(xcrun --show-sdk-path)"
KH="$SDK/System/Library/Frameworks/Kernel.framework/Headers"
rm -rf "$OUT" && mkdir -p "$OUT/Contents/MacOS"
cp "$SRC/Info.plist" "$OUT/Contents/Info.plist"
xcrun clang++ -arch x86_64 -mmacosx-version-min=12.0 -isysroot "$SDK" -std=c++17 -O2 -Wall -Wno-unused-private-field -Wno-inconsistent-missing-override -Wno-deprecated-declarations -Wno-sign-conversion -Wno-implicit-int-conversion \
    -fno-builtin -fno-rtti -fno-exceptions -fno-common -fapple-kext -mkernel -nostdlibinc \
    -I"$KH" -I"$KH/libkern/c++" -DKERNEL -DKERNEL_PRIVATE -DDRIVER_PRIVATE -DAPPLE -DNeXT \
    -c "$SRC/PS5SalinaGbE.cpp" -o "$OUT/../PS5SalinaGbE.o"
xcrun ld -arch x86_64 -kext -static -no_data_const -macos_version_min 12.0 -syslibroot "$SDK" \
    -o "$OUT/Contents/MacOS/PS5SalinaGbE" "$OUT/../PS5SalinaGbE.o" -lkmod -lkmodc++
echo "built $OUT"
