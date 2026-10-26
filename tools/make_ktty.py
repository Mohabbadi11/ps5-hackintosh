#!/usr/bin/env python3
"""Build the kernel text console patch (bringup/ktty/ktty.c) as OpenCore Kernel>Patch entries for Monterey (21.6.0):
  _serial_init          -> mov eax,1; ret          (the kernel believes a UART is present, so it routes console output to serial_putc)
  _serial_putc_options  -> blob: jmp main at +0x00 (serial_putc_options), jmp main at +0x70 (serial_putc, 0x70 further on in
                           the kernel), main + font from +0x80, overwriting the unused audit MAC checks that follow
Prints nothing; imported by make_baremetal_efi.py (KTTY=1)."""
import subprocess, tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
LLVM = "/opt/homebrew/opt/llvm@18/bin"
PLACEHOLDER = bytes.fromhex("0df0adde")          # 0xDEADF00D little endian


def build_blob():
    with tempfile.TemporaryDirectory() as td:
        obj, elf, binf = f"{td}/k.o", f"{td}/k.elf", f"{td}/k.bin"
        subprocess.check_call([f"{LLVM}/clang", "-target", "x86_64-unknown-none-elf", "-ffreestanding", "-fno-stack-protector",
                               "-mno-red-zone", "-mno-sse", "-mno-mmx", "-mno-avx", "-fPIE", "-fno-builtin", "-Os",
                               "-fvisibility=hidden", "-c", str(ROOT / "bringup/ktty/ktty.c"), "-o", obj])
        Path(f"{td}/l.ld").write_text("ENTRY(ktty_main)\nSECTIONS { . = 0; .text : { *(.text.entry) *(.text .text.*) } "
                                      ".rodata : { *(.rodata .rodata.*) } /DISCARD/ : { *(.comment) *(.note*) *(.eh_frame*) } }\n")
        subprocess.check_call([f"{LLVM}/ld.lld", "-nostdlib", "-static", "-T", f"{td}/l.ld", obj, "-o", elf])
        subprocess.check_call([f"{LLVM}/llvm-objcopy", "-O", "binary", elf, binf])
        main = Path(binf).read_bytes()
    blob = bytearray(b"\xCC" * 0x80)
    blob[0:2] = bytes([0xEB, 0x7E])              # +0x00: jmp +0x7e -> 0x80
    blob[0x70:0x72] = bytes([0xEB, 0x0E])        # +0x70: jmp +0x0e -> 0x80
    blob += main
    assert len(blob) <= 0xAA0, f"blob too big: {len(blob)}"   # up to mac_proc_check_getauid (all audit MAC checks, unused at boot)
    assert PLACEHOLDER in blob
    return bytes(blob)


def patches():
    def entry(sym, code, comment):
        return {"Arch": "x86_64", "Base": sym, "Comment": comment, "Count": 1, "Enabled": True, "Find": b"",
                "Identifier": "kernel", "Limit": 0, "Mask": b"", "MaxKernel": "", "MinKernel": "",
                "Replace": code, "ReplaceMask": b"", "Skip": 0}
    return [entry("_serial_init", bytes.fromhex("b801000000c3"), "ktty: serial_init always succeeds"),
            entry("_serial_putc_options", build_blob(), "ktty: text console in serial_putc")]


if __name__ == "__main__":
    import sys
    b = build_blob()
    print(len(b), "bytes; placeholder count", b.count(PLACEHOLDER))
    if len(sys.argv) > 1:                          # C header for bringup/ebstest
        with open(sys.argv[1], "w") as f:
            f.write("static const unsigned char ktty_blob[%d] = {\n" % len(b))
            for i in range(0, len(b), 16):
                f.write("  " + ",".join("0x%02x" % x for x in b[i:i + 16]) + ",\n")
            f.write("};\n")
