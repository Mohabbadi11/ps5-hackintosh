/* Return to the crash-kernel Linux from anywhere (macOS panic/reboot path, or a hang trigger in ktty).
 *
 * This stub lives at physical 0x67200 and is entered, with interrupts off and CR3 = 0x64000, from the tiny kernel-side patch
 * (cli; mov $0x64000,%rax; mov %rax,%cr3; mov $0x67200,%rax; jmp *%rax). Stage 1 prepared everything it needs at fixed low
 * addresses (all identity-mapped by its own tables, no kernel service is used):
 *   0x64000 PML4, 0x65000 PDPT (64 GiB identity map), 0x66000 PDPT for 0xFFFFFF8000000000 (the kernel image, 4 GiB)
 *   0x67000 GDT (null, code32, data, code64 = 0x18), 0x67100 GDTR, 0x67110 far pointer to "next" (code64 selector)
 *   0x63010 Linux entry (startup_64 + 2 MiB), 0x63018 boot_params
 * Then it behaves like the tail of stage1_main: rsi = boot_params, jump to the real kernel. */
    .code64
#include "paint.inc"
    .globl rl_start, rl_next, rl_end
rl_start:
    PAINT 0xFFFFFF00, 2200, 0x63000                /* yellow: the kernel's CR3 switch worked, running in low memory */
    lgdt    0x67100
    PAINT 0xFFFF8000, 2300, 0x63000                /* orange: lgdt done */
    movl    $0x20, %eax                   /* CR4 = PAE only: drops SMEP/SMAP/PCID/PGE the kernel had enabled */
    movq    %rax, %cr4
    PAINT 0xFFFF00FF, 2400, 0x63000                /* magenta: CR4 written */
    rex64 ljmp *0x67110                   /* reload CS with our 64-bit code segment */
rl_next:
    PAINT 0xFF00FF00, 2480, 0x63000                /* green: CS reloaded with our GDT */
    movw    $0x10, %ax
    movw    %ax, %ds
    movw    %ax, %es
    movw    %ax, %ss
    xorl    %eax, %eax
    movw    %ax, %fs
    movw    %ax, %gs
    movl    $0xFEE00000, %r8d             /* local APIC (xAPIC MMIO) */
    movabsq $0x300000800, %rdi            /* snapshot for tools/macos_log.py, in the marks page Linux can read: +0 RFLAGS, +0x100 LAPIC */
    movq    %r15, (%rdi)
    xorl    %ecx, %ecx
1:  movl    (%r8,%rcx), %eax
    movl    %eax, 0x100(%rdi,%rcx)
    addl    $16, %ecx
    cmpl    $0x400, %ecx
    jb      1b
    /* ...then quiet it: mask its timer, software-disable it (Linux brings it back up) */
    movl    $0x10000, 0x320(%r8)
    movl    $0x000000FF, 0xF0(%r8)
    movq    0x63018, %rsi
    movq    0x63010, %rax
    jmp     *%rax
rl_end:
