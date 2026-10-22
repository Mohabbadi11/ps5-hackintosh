/*
 * PS5 Hackintosh — Kernel shellcode
 *
 * Entered on S3 resume instead of the ACPI FirmwareWakingVector.
 * Disables CFI, activates UART, runs HDMI ops for 13.60,
 * then calls boot_linux() with our bzImage + initramfs.
 */

#include <stdint.h>
#include "../../include/config.h"

/* Args block — pointer patched in at 0x11AA11AA11AA11AA */
struct kernel_args {
    uint64_t fw_version;
    uint64_t fun_printf;
    uint64_t kernel_cfi_check;
    uint64_t activate_uart;
    uint64_t smp_rendezvous;
    uint64_t hdmi_ops;
    uint32_t hdmi_op_count;
    uint32_t reserved;
    uint64_t linux_info_pa;
    uint64_t hv_shellcode_pa;
    uint64_t hv_shellcode_size;
    uint64_t boot_linux_fn;
} __attribute__((packed));

typedef int  (*printf_fn)(const char *, ...);
typedef void (*void_fn)(void);
typedef int  (*hdmi_op_fn)(void);
typedef void (*boot_linux_fn_t)(uint64_t linux_info_pa);
typedef void (*smp_fn)(void (*)(void *), void (*)(void *),
                       void (*)(void *), void *);

/* Read args pointer (patched by loader) */
static volatile uint64_t args_marker = 0x11AA11AA11AA11AAULL;

static struct kernel_args *get_args(void)
{
    return (struct kernel_args *)(uintptr_t)args_marker;
}

__attribute__((section(".entry_point")))
void main(uint64_t add1, uint64_t add2)
{
    (void)add1;
    (void)add2;

    struct kernel_args *args = get_args();
    if (!args || !args->fun_printf)
        for (;;) __asm__("hlt");

    printf_fn kprintf = (printf_fn)args->fun_printf;
    kprintf("SCK> PS5 Hackintosh kernel shellcode entered\n");

    /* Activate UART for debug output */
    if (args->activate_uart) {
        void_fn activate = (void_fn)args->activate_uart;
        activate();
        kprintf("SCK> UART activated\n");
    }

    /* Disable kernel CFI check (write RET) */
    if (args->kernel_cfi_check) {
        *(volatile uint8_t *)args->kernel_cfi_check = 0xC3;
        kprintf("SCK> CFI check disabled\n");
    }

    /* Run PS5 HDMI ops (13.60 — prevents black screen) */
    if (args->fw_version >= 0x1300 && args->fw_version < 0x1400) {
        if (args->hdmi_ops && args->hdmi_op_count > 0) {
            volatile uint64_t *ops = (volatile uint64_t *)args->hdmi_ops;
            for (uint32_t i = 0; i < args->hdmi_op_count; i++) {
                hdmi_op_fn fn = (hdmi_op_fn)ops[i];
                if (fn) {
                    int rc = fn();
                    kprintf("SCK> HDMI op %u → %d\n", i, rc);
                }
            }
        }
    }

    kprintf("SCK> Booting Hackintosh kernel...\n");

    /* SMP rendezvous — start all CPUs into the HV shellcode */
    if (args->smp_rendezvous && args->hv_shellcode_pa) {
        smp_fn rendezvous = (smp_fn)args->smp_rendezvous;
        rendezvous(NULL, (void (*)(void *))args->hv_shellcode_pa,
                   NULL, (void *)args->linux_info_pa);
    }

    /* BSP calls boot_linux directly */
    if (args->boot_linux_fn) {
        boot_linux_fn_t boot = (boot_linux_fn_t)args->boot_linux_fn;
        boot(args->linux_info_pa);
    }

    kprintf("SCK> FATAL: boot_linux returned\n");
    for (;;)
        __asm__("hlt");
}
