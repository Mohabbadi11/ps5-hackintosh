/* Kernel tripwire (patched over the start of a XNU function by OpenCore, see tools/make_baremetal_efi.py TRIPWIRE=):
 * paints a 128x64 square (bottom right) of colour COLOUR on the scanout buffer through the GPU's MM_INDEX/MM_DATA window (BAR5 at
 * 0xE0600000, below 4 GiB so it is reachable with the loader's identity map), then spins. Stage 1 leaves the VRAM offset
 * of the linear framebuffer in the dword at phys 0x63000. Position independent, uses only rax/rcx/rdx/rsi/rdi/r8. */
    .code64
    .globl tw_start, tw_end
tw_start:
    cli
    movl    $0xE0600000, %r8d
    movl    $0, 0x18(%r8)                /* MM_INDEX_HI */
    movl    0x63000, %esi                /* VRAM offset of pixel (0,0) */
    addl    $0xABEFA0, %esi              /* row 1100, pixel 1000: below and right of the log text */
    movl    $64, %edx                    /* rows */
1:  movl    $128, %ecx                   /* pixels per row */
    movl    %esi, %edi
2:  movl    %edi, %eax
    orl     $0x80000000, %eax
    movl    %eax, (%r8)                  /* MM_INDEX */
    movl    $COLOUR, 4(%r8)              /* MM_DATA */
    addl    $4, %edi
    decl    %ecx
    jnz     2b
    addl    $10240, %esi
    decl    %edx
    jnz     1b
3:  jmp     3b
tw_end:
