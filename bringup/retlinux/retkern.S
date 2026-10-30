/* Kernel-side half of the return to Linux (patched over _halt_all_cpus by OpenCore, see tools/make_baremetal_efi.py RETURN=1).
 * Position independent, runs in the kernel's own context: marks progress with a red square, then switches to the tables stage 1
 * prepared and jumps into the low-memory stub. 0xDEADF00D is the framebuffer's VRAM offset, rewritten by patch_tripwire.py. */
    .code64
#include "paint.inc"
    .globl rk_start, rk_end
rk_start:
    pushfq
    popq    %rax
    movq    %rax, %r15                   /* RFLAGS at the moment of the trigger, saved for the dump */
    cli
    PAINT 0xFFFF0000, 2100, $0xDEADF00D          /* red: the return path was entered */
    movq    $0x64000, %rax
    movq    %rax, %cr3
    movq    $0x67200, %rax
    jmp     *%rax
rk_end:
