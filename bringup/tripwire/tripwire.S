/* Kernel tripwire (patched over the start of a XNU function by OpenCore, see tools/make_baremetal_efi.py TRIPWIRE=):
 * switches to its own identity map (first 8 GiB, 1 GiB pages, the MMIO gigabyte uncached) so it does not depend on what the
 * loader mapped, then paints a 128x64 square of colour COLOUR on the scanout buffer through the GPU's MM_INDEX/MM_DATA
 * window (BAR5 at 0xE0600000) and spins. Stage 1 leaves the VRAM offset of the linear framebuffer in the dword at phys
 * 0x63000 (0x1a000000 is used when that is empty). Page tables live at 0x64000/0x65000, below the RAM given to the OS.
 * Position independent, runs in 64-bit mode with interrupts off, never returns. */
    .code64
    .globl tw_start, tw_end
tw_start:
    cli
    cld
    movl    $0x64000, %edi                /* clear PML4 + PDPT */
    xorl    %eax, %eax
    movl    $2048, %ecx
    rep stosl
    movl    $0x65003, 0x64000             /* PML4[0] -> PDPT */
    xorl    %ecx, %ecx
1:  movl    %ecx, %eax
    shll    $30, %eax
    orl     $0x83, %eax                   /* P | RW | PS */
    cmpl    $3, %ecx
    jne     2f
    orl     $0x18, %eax                   /* PCD | PWT for 0xC0000000.. (the GPU registers) */
2:  movl    %eax, 0x65000(,%rcx,8)
    incl    %ecx
    cmpl    $8, %ecx
    jb      1b
    movl    $0x64000, %eax
    movq    %rax, %cr3
    movl    $0xE0600000, %r8d
    movl    $0, 0x18(%r8)                 /* MM_INDEX_HI */
    movl    0x63000, %esi                 /* VRAM offset of pixel (0,0) */
    testl   %esi, %esi
    jnz     3f
    movl    $0x1a000000, %esi
3:  addl    $0xABEFA0, %esi               /* row 1100, pixel 1000: below and right of the log text */
    movl    $64, %edx                     /* rows */
4:  movl    $128, %ecx                    /* pixels per row */
    movl    %esi, %edi
5:  movl    %edi, %eax
    orl     $0x80000000, %eax
    movl    %eax, (%r8)                   /* MM_INDEX */
    movl    $COLOUR, 4(%r8)               /* MM_DATA */
    addl    $4, %edi
    decl    %ecx
    jnz     5b
    addl    $10240, %esi
    decl    %edx
    jnz     4b
6:  jmp     6b
tw_end:
