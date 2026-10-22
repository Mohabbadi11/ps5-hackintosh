/* Hypervisor shellcode linker — runs from code cave at ~0x1000 */
ENTRY(main)

SECTIONS
{
    . = 0x1000;

    .shell_code : {
        *(.entry_point)
        *(.text)
        *(.data*)
        *(.rodata*)
        *(.bss)
    }

    /DISCARD/ : {
        *(.note*)
        *(.comment)
        *(.eh_frame*)
    }
}
