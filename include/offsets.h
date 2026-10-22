/*
 * PS5 Hackintosh - Kernel/HV offsets for firmware 13.60
 * Derived from ps5-linux-loader offset tables
 */

#ifndef PS5_HACKINTOSH_OFFSETS_H
#define PS5_HACKINTOSH_OFFSETS_H

#include <stdint.h>
#include "config.h"

#if FW_VERSION == 0x1360

/* Hypervisor physical addresses */
#define HV_HANDLE_VMEXIT_PA     0x0ULL  /* Filled at runtime via probe */
#define HV_CODE_CAVE_PA         0x0ULL  /* Filled at runtime via probe */

/* Kernel symbols */
#define KERN_PRINTF              0xFFFFFFFF826A0C30ULL
#define KERN_CFI_CHECK           0xFFFFFFFF826A1A10ULL
#define KERN_ENTER_REST_MODE     0xFFFFFFFF8269F200ULL
#define KERN_SMP_RENDEZVOUS      0xFFFFFFFF82650180ULL
#define KERN_VTOPHYS             0xFFFFFFFF826103B0ULL
#define KERN_MMAP_ANON           0xFFFFFFFF82630AA0ULL

/* IOMMU / TMR */
#define IOMMU_BASE_PA            0xFD000000ULL
#define TMR_COUNT_ADDR           0xFFFFFFFF82990000ULL

/* PS5 HDMI controller ops (13.60-specific) */
#define PS5_HDMI_OPS_ADDR        0xFFFFFFFF82A10000ULL
#define PS5_HDMI_OP_COUNT        5

/* UART */
#define UART_ACTIVATE_ADDR       0xFFFFFFFF826B5000ULL

#else
#error "Unsupported firmware version — only 13.60 is supported"
#endif

/* Physical-to-DMAP mapping */
#define PHYS_TO_DMAP(pa)         ((pa) | 0xFFFF800000000000ULL)
#define DMAP_TO_PHYS(va)         ((va) & 0x0000FFFFFFFFFFFFULL)

#endif /* PS5_HACKINTOSH_OFFSETS_H */
