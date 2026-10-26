#!/bin/bash
# Build EbsTest.efi (needs the edk2 headers in build/edk2 and llvm@18).
set -euo pipefail
cd "$(dirname "$0")"
L="${LLVM_BIN:-/opt/homebrew/opt/llvm@18/bin}"; E=../../build/edk2/MdePkg/Include
"$L/clang" -target x86_64-unknown-windows -ffreestanding -fshort-wchar -mno-red-zone -fno-stack-protector -fno-builtin -O1 \
    -I$E -I$E/X64 -c ebstest.c -o ebstest.o
"$L/clang" -target x86_64-unknown-windows -c -DCOLOUR=0xFFFF0000 -DVRAM_OFFSET=0x1a000000 ../tripwire/tripwire.S -o tripwire.o
"$L/lld-link" /subsystem:efi_application /entry:EfiMain /nodefaultlib /out:EbsTest.efi ebstest.o tripwire.o
