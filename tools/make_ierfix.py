#!/usr/bin/env python3
"""AMD's extended APIC interrupt-enable registers (IERE, 0x410 bit 0, and IER0..7 at 0x480+16*n) come up set with almost every vector
masked (IER6 = 0x1f): XNU's timer vector 0xDD and every IPI sit in IRR and are never delivered. Linux finds IERE off and all of IER on.
XNU does not know these registers, so open them at the start of `_lapic_configure` (BSP only: i386_init, i386_smp_init, wake from sleep) and at the
start of `_lapic_init_slave` (every AP, called from _vstart); an AP that keeps the closed IER ignores IPIs (TLB shootdown timeouts at cpus>1).

Patch for the Monterey KC (21.6.0), as OpenCore Kernel>Patch entries (prints nothing; imported by make_baremetal_efi.py):
  _lapic_configure (push rbp; mov rbp,rsp; push r14 = 6 bytes)          -> jmp stub 1
  _lapic_init_slave (push rbp; mov rbp,rsp; mov ecx,0x1b = 9 bytes)       -> jmp stub 2
  _nfs4_parsefattr (dead NFSv4 code)                                      -> stub 1 at +0, stub 2 at +0x80: IER fix, the displaced instructions, jmp back
IER registers only accept writes while IERE is set, so the fix is: if IERE then IER0..7 = 0xFFFFFFFF."""
import struct, subprocess, tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
LLVM = "/opt/homebrew/opt/llvm@18/bin"
KC = ROOT / "build/ext/kernel/BootKernelExtensions-monterey.kc"
STUB_SYM = "_nfs4_parsefattr"
LAPIC_VBASE = 0xffffff80012fc8a8           # the kernel variable holding the LAPIC's virtual base (Monterey 21.6.0)
PROLOGUE = bytes.fromhex("554889e54156")    # push rbp; mov rbp, rsp; push r14
SLAVE_PROLOGUE = bytes.fromhex("554889e5b91b000000")    # push rbp; mov rbp, rsp; mov ecx, 0x1b (the MSR number _lapic_init_slave reads next)
STUB2_OFFSET = 0x80


def _symbols():
    out = subprocess.run(["/usr/bin/nm", str(KC)], capture_output=True, text=True).stdout
    return {l.split()[2]: int(l.split()[0], 16) for l in out.splitlines() if len(l.split()) == 3 and l.split()[1] in ("T", "t", "S", "D", "s", "d")}


def _kernel_bytes(va, n):
    d = KC.read_bytes()
    text_va, text_off = 0xffffff8000210000, 0x10000            # __TEXT_EXEC of the Monterey KC
    return d[text_off + (va - text_va):text_off + (va - text_va) + n]


def build_stub(stub_va, back_va, displaced):
    lines = [".code64", ".globl stub", "stub:",
             "    movq lapic_vbase(%rip), %rax", "    testq %rax, %rax", "    jz 1f",
             "    movl 0x410(%rax), %ecx", "    testl $1, %ecx", "    jz 1f",
             "    movl $0xFFFFFFFF, %ecx"]
    lines += [f"    movl %ecx, {0x480 + 16 * i:#x}(%rax)" for i in range(8)]
    lines += ["1:", *[f"    {i}" for i in displaced], "    jmp back"]
    with tempfile.TemporaryDirectory() as td:
        Path(f"{td}/s.S").write_text("\n".join(lines) + "\n")
        subprocess.check_call([f"{LLVM}/clang", "-target", "x86_64-unknown-none-elf", "-c", f"{td}/s.S", "-o", f"{td}/s.o"])
        subprocess.check_call([f"{LLVM}/ld.lld", "-nostdlib", "-static", f"-Ttext={stub_va:#x}", "-e", "stub",
                               f"--defsym=lapic_vbase={LAPIC_VBASE:#x}", f"--defsym=back={back_va:#x}", f"{td}/s.o", "-o", f"{td}/s.elf"])
        subprocess.check_call([f"{LLVM}/llvm-objcopy", "-O", "binary", f"{td}/s.elf", f"{td}/s.bin"])
        return Path(f"{td}/s.bin").read_bytes()


def patches():
    def entry(sym, find, code, comment, limit=0):
        return {"Arch": "x86_64", "Base": sym, "Comment": comment, "Count": 1, "Enabled": True, "Find": find,
                "Identifier": "kernel", "Limit": limit, "Mask": b"", "MaxKernel": "", "MinKernel": "",
                "Replace": code, "ReplaceMask": b"", "Skip": 0}
    sym = _symbols()
    cfg, slave, stub_va = sym["_lapic_configure"], sym["_lapic_init_slave"], sym[STUB_SYM]
    assert _kernel_bytes(cfg, len(PROLOGUE)) == PROLOGUE, "unexpected _lapic_configure prologue"
    assert _kernel_bytes(slave, len(SLAVE_PROLOGUE)) == SLAVE_PROLOGUE, "unexpected _lapic_init_slave prologue"
    stub1 = build_stub(stub_va, cfg + len(PROLOGUE), ["pushq %rbp", "movq %rsp, %rbp", "pushq %r14"])
    stub2 = build_stub(stub_va + STUB2_OFFSET, slave + len(SLAVE_PROLOGUE), ["pushq %rbp", "movq %rsp, %rbp", "movl $0x1b, %ecx"])
    assert len(stub1) <= STUB2_OFFSET and len(stub2) < 0x80
    blob = stub1 + b"\x90" * (STUB2_OFFSET - len(stub1)) + stub2
    jmp1 = b"\xE9" + struct.pack("<i", stub_va - (cfg + 5)) + b"\x90"
    jmp2 = b"\xE9" + struct.pack("<i", stub_va + STUB2_OFFSET - (slave + 5)) + b"\x90" * (len(SLAVE_PROLOGUE) - 5)
    return [entry("_lapic_configure", PROLOGUE, jmp1, "ier: _lapic_configure jumps to the IER fix", limit=0x10),
            entry("_lapic_init_slave", SLAVE_PROLOGUE, jmp2, "ier: _lapic_init_slave (every AP) jumps to the IER fix", limit=0x10),
            entry(STUB_SYM, b"", blob, "ier: open AMD's APIC IER vectors (unused NFSv4 code)")]


if __name__ == "__main__":
    for p in patches():
        print(p["Comment"], len(p["Replace"]), p["Replace"][:16].hex())
