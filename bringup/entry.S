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

    .section .bss
    .balign 16
stack_bottom:
    .skip   32768
stack_top:
