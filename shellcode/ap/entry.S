; PS5 Hackintosh — AP (Application Processor) entry
; Position-independent shellcode for secondary CPUs.
; Clears nested paging (NP_ENABLE) so TMRs stop applying on 13.60.

section .entry_point
global _start

_start:
    ; Read VMCB from MSR (VM_HSAVE_PA)
    mov ecx, 0xC0010117
    rdmsr
    shl rdx, 32
    or  rax, rdx          ; rax = VMCB physical address

    ; Map VMCB via DMAP
    mov rbx, 0xFFFF800000000000
    or  rax, rbx          ; rax = VMCB virtual (DMAP)

    ; Read NESTED_CTRL (offset 0x90 in VMCB control area)
    mov rdx, [rax + 0x90]

    ; Clear NP_ENABLE (bit 0) to disable nested paging
    and rdx, ~1
    mov [rax + 0x90], rdx

    ; Signal completion and halt
    mov byte [rax + 0x400], 0xAA  ; marker in VMCB save area
    cli
    hlt

section .text
    ; pad to page boundary
    align 4096
