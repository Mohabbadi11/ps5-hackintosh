/*
 * PS5 USB port mapping SSDT
 * Maps the three physical USB ports (2x USB-A, 1x USB-C)
 * Compile: iasl -tc SSDT-PS5-USB.dsl
 */
DefinitionBlock ("SSDT-PS5-USB.aml", "SSDT", 2, "PS5HCK", "PS5USB", 0x00010000)
{
    External (_SB.PCI0.XHC0, DeviceObj)
    External (_SB.PCI0.XHC0.RHUB, DeviceObj)

    Scope (_SB.PCI0.XHC0)
    {
        Name (XPRW, Package () { 0x0D, 0x03 })
        Method (_PRW, 0, NotSerialized) { Return (XPRW) }

        /* ACPI companion for xHCI */
        Method (_DSM, 4, NotSerialized)
        {
            If (LEqual (Arg2, Zero)) { Return (Buffer () { 0x03 }) }
            Return (Package ()
            {
                "acpi-wake-type", Buffer () { 0x01 }
            })
        }
    }

    Scope (_SB.PCI0.XHC0.RHUB)
    {
        /* USB 3.0 port count: 3 physical (USB-A rear, USB-A front, USB-C front) */
        /* USB 2.0 companions: same 3 ports */
        Name (USBC, 3)
    }
}
