/* Kernel shellcode linker — replaces ACPI waking vector */
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

    .kdata : {
        *(.kdata)
    }

    /DISCARD/ : {
        *(.note*)
        *(.comment)
        *(.eh_frame*)
    }
}
