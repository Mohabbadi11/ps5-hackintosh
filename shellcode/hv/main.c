/*
 * PS5 Hackintosh — Hypervisor shellcode
 *
 * Runs in HV context on each CPU after the vmexit redirect.
 * Sets up per-CPU stacks and calls the Linux boot entry.
 */

#include <stdint.h>
#include "../../include/config.h"

struct hv_args {
    uint64_t hv_base_rsp;
    uint64_t hv_stack_size;
    uint64_t boot_linux_entry;
    uint64_t linux_info_pa;
    uint64_t cr3_identity;
} __attribute__((packed));

/* Placed in .entry_point — first thing that runs */
__attribute__((section(".entry_point"), naked))
void main(void)
{
    __asm__ volatile(
        /* Read APIC ID from CPUID leaf 1 → EBX[31:24] */
        "mov $1, %%eax\n"
        "cpuid\n"
        "shr $24, %%ebx\n"
        "movzx %%bl, %%rcx\n"     /* cpu_id in rcx */

        /* Load args pointer — patched in by the loader */
        "mov $0x11BB11BB11BB11BB, %%rsi\n"

        /* Per-CPU stack: rsp = base + (cpu_id + 1) * stack_size */
        "mov 0(%%rsi), %%rax\n"   /* hv_base_rsp */
        "mov 8(%%rsi), %%rdx\n"   /* hv_stack_size */
        "inc %%rcx\n"
        "imul %%rdx, %%rcx\n"
        "add %%rcx, %%rax\n"
        "mov %%rax, %%rsp\n"

        /* Jump to boot_linux entry */
        "mov 16(%%rsi), %%rax\n"  /* boot_linux_entry */
        "mov 24(%%rsi), %%rdi\n"  /* linux_info_pa as arg0 */
        "call *%%rax\n"

        /* Halt if boot_linux returns */
        "cli\n"
        "hlt\n"
        ::: "memory"
    );
}
