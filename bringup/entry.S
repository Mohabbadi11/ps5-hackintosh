    .section .text.entry, "ax"
    .code64
    .globl startup_64
startup_64:
    cli
    cld
    movq    %rsi, %r12                  /* boot_params, callee-saved across stage1_main */
    leaq    __bss_start(%rip), %rdi
    leaq    __bss_end(%rip), %rcx
    subq    %rdi, %rcx
    xorl    %eax, %eax
    rep stosb
    leaq    stack_top(%rip), %rsp
    movq    %r12, %rdi
    call    stage1_main
    movq    %r12, %rsi
    leaq    startup_64(%rip), %rax
    addq    $0x200000, %rax             /* real kernel's 64-bit entry: image base + 2 MiB + 0x200 */
    jmp     *%rax

    .globl ps5_isr
ps5_isr:
    pushq   %rax
    movl    $0xFEE000B0, %eax           /* local APIC EOI register (movl zero-extends; movq would sign-extend it) */
    movl    $0, (%rax)
    popq    %rax
    iretq

    .section .bss
    .balign 16
stack_bottom:
    .skip   32768
stack_top:

/* ---- framebuffer mirror core (stage 1 V5) --------------------------------------------------------------------------
 * An application processor is woken with INIT/SIPI and parked in a loop that copies the framebuffer that UEFI and macOS
 * draw into (a RAM alias below 4 GiB: XNU keeps the framebuffer address in 32 bits) onto the real scanout buffer in the
 * VRAM carve-out. The code is copied to AP_TRAMP and entered in real mode; everything it needs is addressed absolutely. */
    .equ AP_TRAMP, 0x62000
    .equ AP_DATA,  0x63000              /* +0 src, +8 dst, +0x10 qword count, +0x20 cr3, +0x40 frame counter */

    .section .text.entry
    .globl ap_tramp_start
    .globl ap_tramp_end
ap_tramp_start:
    .code16
    cli
    cld
    movw    %cs, %ax
    movw    %ax, %ds
    lgdtl   (ap_gdtr - ap_tramp_start)
    movl    $0x00000011, %eax           /* PE | ET, CD/NW clear: INIT leaves the caches disabled */
    movl    %eax, %cr0
    ljmpl   $0x08, $(AP_TRAMP + (ap_pm - ap_tramp_start))

    .code32
ap_pm:
    movw    $0x10, %ax
    movw    %ax, %ds
    movw    %ax, %es
    movw    %ax, %ss
    movl    %cr4, %eax
    orl     $0x20, %eax                 /* PAE */
    movl    %eax, %cr4
    movl    (AP_DATA + 0x20), %eax
    movl    %eax, %cr3
    movl    $0xC0000080, %ecx
    rdmsr
    orl     $0x100, %eax                /* EFER.LME */
    wrmsr
    movl    $0x277, %ecx                /* IA32_PAT: entry 4 = write-combining, the rest at their defaults */
    movl    $0x00070406, %eax
    movl    $0x00070401, %edx
    wrmsr
    movl    %cr0, %eax
    orl     $0x80000000, %eax           /* PG */
    movl    %eax, %cr0
    ljmpl   $0x18, $(AP_TRAMP + (ap_lm - ap_tramp_start))

    .code64
ap_lm:
    xorl    %eax, %eax
    movw    %ax, %ds
    movw    %ax, %es
    movw    %ax, %ss
    movl    $0x70000, %esp
    lidtq   (AP_TRAMP + (ap_idtr - ap_tramp_start))
1:  movq    (AP_DATA + 0x00), %rsi
    movq    (AP_DATA + 0x08), %rdi
    movq    (AP_DATA + 0x10), %rcx
    cld
    rep movsq
    incq    (AP_DATA + 0x40)
    pause
    jmp     1b
ap_iret:                                /* NMI: acknowledge and carry on */
    iretq
ap_hang:
    hlt
    jmp     ap_hang

    .balign 16
ap_gdt:
    .quad   0
    .quad   0x00CF9A000000FFFF          /* 0x08 code32 */
    .quad   0x00CF92000000FFFF          /* 0x10 data */
    .quad   0x00AF9A000000FFFF          /* 0x18 code64 */
ap_gdtr:
    .word   ap_gdtr - ap_gdt - 1
    .long   AP_TRAMP + (ap_gdt - ap_tramp_start)
    .balign 16
ap_idt:                                 /* vectors 0 and 1 hang, 2 (NMI) returns */
    .word   (AP_TRAMP + (ap_hang - ap_tramp_start)) & 0xFFFF, 0x18, 0x8E00, (AP_TRAMP + (ap_hang - ap_tramp_start)) >> 16
    .long   0, 0
    .word   (AP_TRAMP + (ap_hang - ap_tramp_start)) & 0xFFFF, 0x18, 0x8E00, (AP_TRAMP + (ap_hang - ap_tramp_start)) >> 16
    .long   0, 0
    .word   (AP_TRAMP + (ap_iret - ap_tramp_start)) & 0xFFFF, 0x18, 0x8E00, (AP_TRAMP + (ap_iret - ap_tramp_start)) >> 16
    .long   0, 0
ap_idtr:
    .word   ap_idtr - ap_idt - 1
    .quad   AP_TRAMP + (ap_idt - ap_tramp_start)
ap_tramp_end:
