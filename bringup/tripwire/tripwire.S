/* Kernel tripwire (patched over the start of a XNU function by OpenCore, see tools/make_baremetal_efi.py TRIPWIRE=):
 * paints a 64x32 square of colour COLOUR on the scanout buffer and spins.
 *
 * It uses the GPU's I/O-port BAR (0x2000: +0 MM_INDEX, +4 MM_DATA; bit 31 of the index selects VRAM), so it needs no page
 * tables and no knowledge of the mode it is entered in: only opcodes that mean the same in 32- and 64-bit code (no
 * inc/dec register forms, which are REX prefixes in 64-bit mode). The VRAM offset of the linear framebuffer differs per boot,
 * so the 32-bit immediate in the second instruction is rewritten by tools/patch_tripwire.py (run on the console, which can
 * look the buffer up before launching UEFI); VRAM_OFFSET is only the default. */
    .code32
    .globl tw_start, tw_end
tw_start:
    cli
    movl    $VRAM_OFFSET, %esi            /* offset of pixel (0,0); patched */
    addl    $0xABF220, %esi               /* row 1100, pixel 1640: to the right of the firmware milestones, clear of the log text */
    movl    $32, %ebx                     /* rows */
1:  movl    $64, %ecx                     /* pixels per row */
    movl    %esi, %edi
2:  movw    $0x2000, %dx
    movl    %edi, %eax
    orl     $0x80000000, %eax
    outl    %eax, %dx                     /* MM_INDEX */
    movw    $0x2004, %dx
    movl    $COLOUR, %eax
    outl    %eax, %dx                     /* MM_DATA */
    addl    $4, %edi
    subl    $1, %ecx
    jnz     2b
    addl    $10240, %esi
    subl    $1, %ebx
    jnz     1b
3:  jmp     3b
tw_end:
