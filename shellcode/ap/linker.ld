/* AP shellcode — position independent, runs at carrier page PA */
ENTRY(_start)

SECTIONS
{
    . = 0;

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
