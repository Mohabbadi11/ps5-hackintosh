ENTRY(startup_64)
SECTIONS
{
    . = 0;
    .pad   : { . = 0x200; }
    .text  : { *(.text.entry) *(.text .text.*) }
    .rodata : { *(.rodata .rodata.*) }
    .data  : { *(.data .data.*) }
    . = ALIGN(4096);
    .bss   : { __bss_start = .; *(.bss .bss.*) *(COMMON) . = ALIGN(4096); __bss_end = .; }
    /DISCARD/ : { *(.comment) *(.note*) *(.eh_frame*) }
}
