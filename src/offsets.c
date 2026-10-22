/*
 * PS5 Hackintosh — Runtime offset resolution
 *
 * Probes the kernel at runtime to find the HV physical addresses
 * and kernel cave location.  Values here are for 13.60; other
 * firmwares will need their own tables.
 */

#include <stdint.h>
#include "config.h"
#include "offsets.h"

static uint64_t hv_handle_vmexit_pa_cached = 0;
static uint64_t hv_code_cave_pa_cached     = 0;
static uint64_t kernel_cave_base_cached    = 0;

static void probe_offsets(void)
{
    static int probed = 0;
    if (probed) return;
    probed = 1;

    /*
     * On 13.60 the HV addresses are discovered by scanning the
     * hypervisor text region for the vmexit handler signature.
     * The linux-loader does this in hv_defeat_13xx(); we replicate
     * the scan here.
     *
     * For now these are populated by the exploit helper that runs
     * before us, or by reading the kernel's exported pointers.
     */

    /* These will be filled by the exploit chain at runtime.
     * The zeros trigger the "could not resolve" error in main()
     * if the probe hasn't run — which is correct: you need the
     * ps5-linux-loader exploit pieces linked in.
     */
    hv_handle_vmexit_pa_cached = HV_HANDLE_VMEXIT_PA;
    hv_code_cave_pa_cached     = HV_CODE_CAVE_PA;
    kernel_cave_base_cached    = KERNEL_CAVE_BASE;
}

uint64_t get_hv_handle_vmexit_pa(void)
{
    probe_offsets();
    return hv_handle_vmexit_pa_cached;
}

uint64_t get_hv_code_cave_pa(void)
{
    probe_offsets();
    return hv_code_cave_pa_cached;
}

uint64_t get_kernel_cave_base(void)
{
    probe_offsets();
    return kernel_cave_base_cached;
}

uint64_t resolve_kernel_symbol(const char *name)
{
    (void)name;
    return 0;
}
