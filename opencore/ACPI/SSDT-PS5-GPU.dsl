/*
 * PS5 GPU SSDT — RDNA 2 device properties for WhateverGreen
 * Compile: iasl -tc SSDT-PS5-GPU.dsl
 */
DefinitionBlock ("SSDT-PS5-GPU.aml", "SSDT", 2, "PS5HCK", "PS5GPU", 0x00010000)
{
    External (_SB.PCI0.GFX0, DeviceObj)

    Scope (_SB.PCI0.GFX0)
    {
        /* Force AMD RDNA 2 initialization */
        Method (XDSM, 4, NotSerialized)
        {
            Return (Package ()
            {
                "agdpmod", "pikera",
                "rebuild-device-tree", "No",
                "disable-gpu-wake", Buffer () { 0x01, 0x00, 0x00, 0x00 },
                "force-online", Buffer () { 0x01, 0x00, 0x00, 0x00 },
                "CFG_FB_LIMIT", Buffer () { 0x04, 0x00, 0x00, 0x00 }
            })
        }
    }
}
