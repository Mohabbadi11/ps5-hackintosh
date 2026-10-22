/*
 * PS5 Hackintosh Loader - Loader interface
 */

#ifndef PS5_HACKINTOSH_LOADER_H
#define PS5_HACKINTOSH_LOADER_H

#include <stdint.h>
#include <stddef.h>

struct linux_info {
    uint64_t bzimage_pa;
    uint64_t bzimage_size;
    uint64_t initrd_pa;
    uint64_t initrd_size;
    char     cmdline[4096];
};

struct hackintosh_boot {
    struct linux_info linux;
    uint64_t         shellcode_hv_pa;
    uint64_t         shellcode_kernel_pa;
    uint64_t         shellcode_ap_pa;
    uint32_t         fw_version;
    uint32_t         flags;
};

#define BOOT_FLAG_VERBOSE   (1 << 0)
#define BOOT_FLAG_UART      (1 << 1)
#define BOOT_FLAG_GPU_INIT  (1 << 2)

/* loader.c */
int  fetch_hackintosh_payload(struct hackintosh_boot *boot);
int  install_page_syscore(uint64_t dst, uint64_t src, int flags);
void enter_rest_mode(void);

/* gpu_init.c */
int  ps5_gpu_pre_init(void);
void ps5_hdmi_handoff(void);

/* offsets.c */
uint64_t get_hv_handle_vmexit_pa(void);
uint64_t get_hv_code_cave_pa(void);
uint64_t get_kernel_cave_base(void);
uint64_t resolve_kernel_symbol(const char *name);

/* exploit.c */
int  hv_defeat_13xx(uint64_t hv_vmexit_pa, uint64_t hv_cave_pa,
                    const uint8_t *shellcode_hv, uint32_t shellcode_hv_len,
                    const uint8_t *shellcode_ap, uint32_t shellcode_ap_len);
int  prepare_resume(uint8_t **shellcode_kernel_out, uint32_t *len_out,
                    struct hackintosh_boot *boot);

#endif /* PS5_HACKINTOSH_LOADER_H */
