/*
 * PS5 Custom DSDT for macOS Hackintosh
 * Defines the PS5 hardware topology for OpenCore/macOS.
 *
 * Compile with: iasl -tc DSDT-PS5.dsl
 * Output: DSDT-PS5.aml → place in EFI/OC/ACPI/
 */
DefinitionBlock ("DSDT-PS5.aml", "DSDT", 2, "PS5HCK", "PS5DSDT", 0x00010000)
{
    Scope (_SB)
    {
        /* ── AMD Zen 2 CPUs (8 cores / 16 threads) ──── */
        Device (PR00) { Name (_HID, "ACPI0007") Name (_UID, 0x00) }
        Device (PR01) { Name (_HID, "ACPI0007") Name (_UID, 0x01) }
        Device (PR02) { Name (_HID, "ACPI0007") Name (_UID, 0x02) }
        Device (PR03) { Name (_HID, "ACPI0007") Name (_UID, 0x03) }
        Device (PR04) { Name (_HID, "ACPI0007") Name (_UID, 0x04) }
        Device (PR05) { Name (_HID, "ACPI0007") Name (_UID, 0x05) }
        Device (PR06) { Name (_HID, "ACPI0007") Name (_UID, 0x06) }
        Device (PR07) { Name (_HID, "ACPI0007") Name (_UID, 0x07) }
        Device (PR08) { Name (_HID, "ACPI0007") Name (_UID, 0x08) }
        Device (PR09) { Name (_HID, "ACPI0007") Name (_UID, 0x09) }
        Device (PR10) { Name (_HID, "ACPI0007") Name (_UID, 0x0A) }
        Device (PR11) { Name (_HID, "ACPI0007") Name (_UID, 0x0B) }
        Device (PR12) { Name (_HID, "ACPI0007") Name (_UID, 0x0C) }
        Device (PR13) { Name (_HID, "ACPI0007") Name (_UID, 0x0D) }
        Device (PR14) { Name (_HID, "ACPI0007") Name (_UID, 0x0E) }
        Device (PR15) { Name (_HID, "ACPI0007") Name (_UID, 0x0F) }

        /* ── PCI Root ────────────────────────────────── */
        Device (PCI0)
        {
            Name (_HID, EisaId ("PNP0A08"))
            Name (_CID, EisaId ("PNP0A03"))
            Name (_ADR, Zero)
            Name (_UID, Zero)

            /* Host bridge */
            Device (HSTB)
            {
                Name (_ADR, Zero)
            }

            /* ── GPU: AMD RDNA 2 (36 CU) ────────── */
            Device (GFX0)
            {
                Name (_ADR, 0x00010000)
                Name (_SUN, One)
                Method (_DSM, 4, NotSerialized)
                {
                    If (LEqual (Arg2, Zero)) { Return (Buffer () { 0x03 }) }
                    Return (Package ()
                    {
                        "model", "AMD Radeon RDNA 2 (PS5)",
                        "device-id", Buffer () { 0xBF, 0x73, 0x00, 0x00 },
                        "hda-gfx", "onboard-1",
                        "agdpmod", "pikera"
                    })
                }
            }

            /* ── HDMI Audio ──────────────────────── */
            Device (HDAU)
            {
                Name (_ADR, 0x00010001)
                Method (_DSM, 4, NotSerialized)
                {
                    If (LEqual (Arg2, Zero)) { Return (Buffer () { 0x03 }) }
                    Return (Package ()
                    {
                        "model", "AMD HDMI Audio (PS5)",
                        "hda-gfx", "onboard-1",
                        "layout-id", Buffer () { 0x01, 0x00, 0x00, 0x00 }
                    })
                }
            }

            /* ── NVMe SSD (825 GB custom) ────────── */
            Device (NVME)
            {
                Name (_ADR, 0x00020000)
                Name (_SUN, 0x02)
            }

            /* ── xHCI USB Controller ─────────────── */
            Device (XHC0)
            {
                Name (_ADR, 0x00030000)
                Name (_SUN, 0x03)
                Device (RHUB)
                {
                    Name (_ADR, Zero)
                    /* USB-A rear */
                    Device (PRT1) { Name (_ADR, One)   Name (_UPC, Package () { 0xFF, 0x03, 0, 0 }) }
                    /* USB-A front */
                    Device (PRT2) { Name (_ADR, 0x02)  Name (_UPC, Package () { 0xFF, 0x03, 0, 0 }) }
                    /* USB-C front */
                    Device (PRT3) { Name (_ADR, 0x03)  Name (_UPC, Package () { 0xFF, 0x09, 0, 0 }) }
                }
            }

            /* ── Ethernet (Marvell) ──────────────── */
            Device (GIGE)
            {
                Name (_ADR, 0x00040000)
            }

            /* ── AHCI (BD drive + NVMe alt) ─────── */
            Device (SATA)
            {
                Name (_ADR, 0x00050000)
            }
        }

        /* ── SMBus (needed by VirtualSMC) ────────── */
        Device (SBUS)
        {
            Name (_ADR, 0x00140000)
        }
    }

    /* ── Power management ────────────────────────── */
    Scope (_GPE)
    {
        Method (_L09, 0, NotSerialized) { Notify (\_SB.PCI0, 0x02) }
    }
}
