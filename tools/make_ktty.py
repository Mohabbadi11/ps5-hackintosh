#!/usr/bin/env python3
"""Build the kernel text console patch (bringup/ktty/ktty.c) as OpenCore Kernel>Patch entries for Monterey (21.6.0):
  _serial_init          -> mov eax,1; ret          (the kernel believes a UART is present, so it routes console output to serial_putc)
  _serial_putc_options  -> blob: jmp main at +0x00 (serial_putc_options), jmp main at +0x70 (serial_putc, 0x70 further on in
                           the kernel), main + font from +0x80, overwriting the unused audit MAC checks that follow
Prints nothing; imported by make_baremetal_efi.py (KTTY=1)."""
import os, subprocess, tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
LLVM = "/opt/homebrew/opt/llvm@18/bin"
PLACEHOLDER = bytes.fromhex("0df0adde")          # 0xDEADF00D little endian


def _putc_options():
    out = subprocess.run(["/usr/bin/nm", str(ROOT / "build/ext/kernel/BootKernelExtensions-monterey.kc")], capture_output=True, text=True).stdout
    for l in out.splitlines():
        p = l.split()
        if len(p) == 3 and p[2] == "_serial_putc_options": return int(p[0], 16)


def halt_delta():
    """Distance from ktty_main (blob + 0x80, patched at _serial_putc_options) to the patched _halt_all_cpus, from the Monterey KC."""
    # nm prints the kernel's symbols and then aborts on the first kext it cannot parse: keep what it printed
    out = subprocess.run(["/usr/bin/nm", str(ROOT / "build/ext/kernel/BootKernelExtensions-monterey.kc")], capture_output=True, text=True).stdout
    sym = {l.split()[2]: int(l.split()[0], 16) for l in out.splitlines() if len(l.split()) == 3 and l.split()[1] == "T"}
    return sym["_halt_all_cpus"] - (sym["_serial_putc_options"] + 0x80)


LAPIC_VBASE = 0xffffff80012fc8a8        # the kernel variable holding the LAPIC's virtual base (legacy_read/legacy_write, Monterey 21.6.0)


def build_blob():
    with tempfile.TemporaryDirectory() as td:
        obj, elf, binf = f"{td}/k.o", f"{td}/k.elf", f"{td}/k.bin"
        subprocess.check_call([f"{LLVM}/clang", "-target", "x86_64-unknown-none-elf", "-ffreestanding", "-fno-stack-protector",
                               "-mno-red-zone", "-mno-sse", "-mno-mmx", "-mno-avx", "-fPIE", "-fno-builtin", "-Os",
                               "-fvisibility=hidden", f"-DKTTY_HALT_DELTA={halt_delta()}", f"-DKTTY_LAPIC_DELTA={LAPIC_VBASE - (0xffffff80003b6990 * 0 + _putc_options() + 0x80)}"] + ([f'-DKTTY_RETURN_PAT="{os.environ["KTTY_RETURN"]}"'] if os.environ.get("KTTY_RETURN") else []) +
                              ([f'-DKTTY_DUMP_PAT="{os.environ["KTTY_DUMP"]}"'] if os.environ.get("KTTY_DUMP") else []) +
                              ["-c", str(ROOT / "bringup/ktty/ktty.c"), "-o", obj])
        Path(f"{td}/l.ld").write_text("ENTRY(ktty_main)\nSECTIONS { . = 0; .text : { *(.text.entry) *(.text .text.*) } "
                                      ".rodata : { *(.rodata .rodata.*) } /DISCARD/ : { *(.comment) *(.note*) *(.eh_frame*) } }\n")
        subprocess.check_call([f"{LLVM}/ld.lld", "-nostdlib", "-static", "-T", f"{td}/l.ld", obj, "-o", elf])
        subprocess.check_call([f"{LLVM}/llvm-objcopy", "-O", "binary", elf, binf])
        main = Path(binf).read_bytes()
    blob = bytearray(b"\xCC" * 0x80)
    blob[0:2] = bytes([0xEB, 0x7E])              # +0x00: jmp +0x7e -> 0x80
    blob[0x70:0x72] = bytes([0xEB, 0x0E])        # +0x70: jmp +0x0e -> 0x80
    blob += main
    assert len(blob) <= 0x1ca0, f"blob too big: {len(blob)}"   # up to mac_policy_list_busy (the audit MAC checks and mac_audit_* are unused at boot)
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
