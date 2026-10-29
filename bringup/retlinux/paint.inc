/* PAINT colour, x_pixel, src: paint a 64x32 square at row 1300 through the GPU's I/O ports (no page tables needed), the VRAM
 * offset of the framebuffer being read from "src" (an immediate for the kernel-side tail, 0x63000 in low memory otherwise).
 * Clobbers eax, ebx, ecx, edx, esi, edi. */
.macro PAINT colour, xpix, src
    movl    \src, %esi
    addl    $(1300 * 10240 + \xpix * 4), %esi
    movl    $32, %ebx
9:  movl    $64, %ecx
    movl    %esi, %edi
8:  movw    $0x2000, %dx
    movl    %edi, %eax
    orl     $0x80000000, %eax
    outl    %eax, %dx
    movw    $0x2004, %dx
    movl    $\colour, %eax
    outl    %eax, %dx
    addl    $4, %edi
    subl    $1, %ecx
    jnz     8b
    addl    $10240, %esi
    subl    $1, %ebx
    jnz     9b
.endm
