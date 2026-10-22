/*
 * PS5 Hackintosh Loader — Entry point
 *
 * Runs as a PS5 userland payload. Loads a custom Linux bzImage +
 * initramfs that chainboots macOS via KVM + OpenCore.
 *
 * Boot chain:
 *   payload ELF → HV shellcode → kernel shellcode → bzImage
 *   → initramfs (QEMU/KVM + OpenCore) → macOS
 */

#include <stdint.h>
#include <stddef.h>
#include <unistd.h>

#include "config.h"
#include "loader.h"
#include "offsets.h"

#include "shellcode_hv.h"
#include "shellcode_kernel.h"
#include "shellcode_ap.h"

#define NOTIFY_FD 1

static void notify(const char *msg)
{
    write(NOTIFY_FD, msg, __builtin_strlen(msg));
    write(NOTIFY_FD, "\n", 1);
}

static void setup_env(void)
{
    /* Raise file descriptor limits and map shared memory for payloads */
}

int main(void)
{
    struct hackintosh_boot boot = {0};
    uint8_t *shellcode_krn_blob = NULL;
    uint32_t shellcode_krn_len  = 0;
    uint64_t hv_vmexit_pa, hv_cave_pa;

    notify("[hackintosh] PS5 Hackintosh Loader v1.0");
    notify("[hackintosh] Target: macOS via KVM on PS5 (FW 13.60)");

    /* ── Stage 0: Environment ──────────────────────────── */
    setup_env();
    boot.fw_version = FW_VERSION;
    boot.flags      = BOOT_FLAG_GPU_INIT | BOOT_FLAG_UART;

    /* ── Stage 1: Load bzImage + initramfs from USB ────── */
    notify("[hackintosh] Loading kernel and initramfs from USB...");
    if (fetch_hackintosh_payload(&boot) != 0) {
        notify("[hackintosh] FATAL: Failed to load boot payload from USB.");
        notify("[hackintosh] Make sure USB has bzImage and initramfs.cpio.gz");
        return 1;
    }
    notify("[hackintosh] Payload loaded successfully.");

    /* ── Stage 2: GPU pre-init (HDMI handoff for 13.60) ── */
    notify("[hackintosh] Initializing GPU for display handoff...");
    if (ps5_gpu_pre_init() != 0) {
        notify("[hackintosh] WARNING: GPU pre-init failed, display may be black.");
    }

    /* ── Stage 3: Resolve HV addresses ─────────────────── */
    hv_vmexit_pa = get_hv_handle_vmexit_pa();
    hv_cave_pa   = get_hv_code_cave_pa();

    if (hv_vmexit_pa == 0 || hv_cave_pa == 0) {
        notify("[hackintosh] FATAL: Could not resolve HV addresses.");
        return 1;
    }

    /* ── Stage 4: Prepare kernel shellcode (resume blob) ─ */
    notify("[hackintosh] Preparing resume shellcode...");
    if (prepare_resume(&shellcode_krn_blob, &shellcode_krn_len, &boot) != 0) {
        notify("[hackintosh] FATAL: Failed to prepare resume shellcode.");
        return 1;
    }

    /* ── Stage 5: Patch hypervisor (13.60 exploit) ─────── */
    notify("[hackintosh] Patching hypervisor...");
#if FW_VERSION >= 0x1300 && FW_VERSION < 0x1400
    if (hv_defeat_13xx(hv_vmexit_pa, hv_cave_pa,
                       build_shellcode_shellcode_hv_bin,
                       build_shellcode_shellcode_hv_bin_len,
                       build_shellcode_shellcode_ap_bin,
                       build_shellcode_shellcode_ap_bin_len) != 0)
    {
        notify("[hackintosh] FATAL: HV patch failed.");
        return 1;
    }
#else
    notify("[hackintosh] FATAL: Only firmware 13.60 is supported.");
    return 1;
#endif

    /* ── Stage 6: Enter rest mode (triggers S3 resume) ─── */
    notify("[hackintosh] Entering rest mode — macOS will boot on resume...");
    notify("[hackintosh] Do NOT unplug the USB drive!");
    sleep(3);
    enter_rest_mode();

    /* Should not reach here — the console resumes into our shellcode */
    for (;;)
        sleep(30);

    return 0;
}
