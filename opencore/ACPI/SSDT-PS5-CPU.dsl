/*
 * PS5 CPU SSDT — AMD Zen 2 power management for macOS
 * Compile: iasl -tc SSDT-PS5-CPU.dsl
 */
DefinitionBlock ("SSDT-PS5-CPU.aml", "SSDT", 2, "PS5HCK", "PS5CPU", 0x00010000)
{
    External (_SB.PR00, DeviceObj)

    Scope (_SB.PR00)
    {
        Method (_PPC, 0, NotSerialized) { Return (Zero) }
        Method (_PSS, 0, NotSerialized)
        {
            Return (Package ()
            {
                /* Freq(MHz), Power(mW), Lat(us), BMlat(us), Ctrl, Status */
                Package () { 3500, 105000, 10, 10, 0x00, 0x00 },
                Package () { 3200,  90000, 10, 10, 0x01, 0x01 },
                Package () { 2800,  75000, 10, 10, 0x02, 0x02 },
                Package () { 2400,  60000, 10, 10, 0x03, 0x03 },
                Package () { 2000,  45000, 10, 10, 0x04, 0x04 },
                Package () { 1600,  30000, 10, 10, 0x05, 0x05 }
            })
        }
    }
}
