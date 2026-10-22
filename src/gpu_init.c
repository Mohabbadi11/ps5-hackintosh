/*
 * PS5 Hackintosh — GPU initialization
 *
 * Performs HDMI handoff for 13.60 to avoid black screen on boot.
 * Runs PS5-specific HDMI ops (transmitter, voltage swing, MP3 init,
 * HDCP, output enable) before handing display to the guest OS.
 */

#include <stdint.h>
#include "config.h"
#include "offsets.h"
#include "loader.h"

typedef int (*hdmi_op_fn)(void);

int ps5_gpu_pre_init(void)
{
#if FW_VERSION >= 0x1300 && FW_VERSION < 0x1400
    volatile uint64_t *ops = (volatile uint64_t *)PHYS_TO_DMAP(PS5_HDMI_OPS_ADDR);
    int rc;

    for (int i = 0; i < PS5_HDMI_OP_COUNT; i++) {
        hdmi_op_fn fn = (hdmi_op_fn)ops[i];
        if (!fn)
            continue;
        rc = fn();
        if (rc != 0)
            return rc;
    }
#endif
    return 0;
}

void ps5_hdmi_handoff(void)
{
    ps5_gpu_pre_init();
}
