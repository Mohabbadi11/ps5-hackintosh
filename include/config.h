/*
 * PS5 Hackintosh Loader - Configuration
 * Hardware profile: AMD Zen 2 (Oberon) + RDNA 2 (36 CU)
 */

#ifndef PS5_HACKINTOSH_CONFIG_H
#define PS5_HACKINTOSH_CONFIG_H

#include <stdint.h>

/* ── Firmware ────────────────────────────────────────── */
#ifndef FW_VERSION
#define FW_VERSION 0x1360
#endif

/* ── Memory layout ───────────────────────────────────── */
#define KERNEL_CAVE_BASE       0x200000000ULL
#define KERNEL_CAVE_BZIMAGE    (KERNEL_CAVE_BASE + 0x1000)
#define KERNEL_CAVE_INITRD     (KERNEL_CAVE_BASE + 0x4000000)
#define KERNEL_CAVE_LINUX_INFO (KERNEL_CAVE_BASE)

#define BZIMAGE_MAX_SIZE       (64  * 1024 * 1024)  /* 64 MiB */
#define INITRD_MAX_SIZE        (512 * 1024 * 1024)  /* 512 MiB */

#define PAGE_SIZE              0x1000
#define ALIGN_UP(x, a)         (((x) + (a) - 1) & ~((a) - 1))

/* ── Hypervisor ──────────────────────────────────────── */
#define HV_STACK_SIZE          0x4000
#define HV_MAX_CPUS            16

/* ── PS5 hardware IDs ────────────────────────────────── */
#define PS5_CPU_FAMILY         0x17   /* Zen 2 */
#define PS5_CPU_MODEL          0x60   /* Oberon */
#define PS5_GPU_DEVICE_ID      0x73A0 /* RDNA 2 custom, close to Navi 22 */
#define PS5_GPU_VENDOR_ID      0x1002 /* AMD */

/* ── macOS target ────────────────────────────────────── */
#define MACOS_SMBIOS_MODEL     "iMacPro1,1"
#define MACOS_GPU_SPOOF_ID     0x73BF /* Navi 22 (RX 6600 XT) */

/* ── USB paths ───────────────────────────────────────── */
#define USB_BZIMAGE_PATH       "/bzImage"
#define USB_INITRD_PATH        "/initramfs.cpio.gz"
#define USB_CMDLINE_PATH       "/cmdline.txt"
#define USB_MACOS_IMG_PATH     "/macos/macOS.img"
#define USB_OPENCORE_PATH      "/macos/EFI"

/* ── Boot cmdline ────────────────────────────────────── */
#define DEFAULT_CMDLINE \
    "console=tty0 " \
    "earlyprintk=ttyS0,115200 " \
    "root=/dev/ram0 " \
    "rdinit=/init " \
    "amdgpu.dpm=0 " \
    "amdgpu.runpm=0 " \
    "amdgpu.force_1080p=1 " \
    "video=DP-1:1920x1080@60 " \
    "iommu=pt " \
    "amd_iommu=on " \
    "kvm_amd.nested=1 " \
    "default_hugepagesz=2M " \
    "hugepages=4096 " \
    "ps5_hackintosh=1"

/* ── UART ────────────────────────────────────────────── */
#define UART_BASE              0x3F8
#define UART_BAUD              115200

#endif /* PS5_HACKINTOSH_CONFIG_H */
