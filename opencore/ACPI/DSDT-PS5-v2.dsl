/*
 * Intel ACPI Component Architecture
 * AML/ASL+ Disassembler version 20260408 (64-bit version)
 * Copyright (c) 2000 - 2026 Intel Corporation
 * 
 * Disassembling to symbolic ASL+ operators
 *
 * Disassembly of DSDT.aml
 *
 * Original Table Header:
 *     Signature        "DSDT"
 *     Length           0x000001F4 (500)
 *     Revision         0x02
 *     Checksum         0x40
 *     OEM ID           "SIE   "
 *     OEM Table ID     "PPR     "
 *     OEM Revision     0x20121002 (538054658)
 *     Compiler ID      "INTL"
 *     Compiler Version 0x20150619 (538248729)
 */
DefinitionBlock ("", "DSDT", 2, "SIE   ", "PPR     ", 0x20121002)
{
    Scope (_PR)
    {
        Processor (C000, 0x00, 0x00000000, 0x00){}
        Processor (C001, 0x01, 0x00000000, 0x00){}
        Processor (C002, 0x02, 0x00000000, 0x00){}
        Processor (C003, 0x03, 0x00000000, 0x00){}
        Processor (C004, 0x04, 0x00000000, 0x00){}
        Processor (C005, 0x05, 0x00000000, 0x00){}
        Processor (C006, 0x06, 0x00000000, 0x00){}
        Processor (C007, 0x07, 0x00000000, 0x00){}
        Processor (C008, 0x08, 0x00000000, 0x00){}
        Processor (C009, 0x09, 0x00000000, 0x00){}
        Processor (C00A, 0x0A, 0x00000000, 0x00){}
        Processor (C00B, 0x0B, 0x00000000, 0x00){}
        Processor (C00C, 0x0C, 0x00000000, 0x00){}
        Processor (C00D, 0x0D, 0x00000000, 0x00){}
        Processor (C00E, 0x0E, 0x00000000, 0x00){}
        Processor (C00F, 0x0F, 0x00000000, 0x00){}
    }

    Name (_S0, Package (0x04)  // _S0_: S0 System State
    {
        Zero, 
        Zero, 
        Zero, 
        Zero
    })
    Name (_S3, Package (0x04)  // _S3_: S3 System State
    {
        0x03, 
        0x03, 
        Zero, 
        Zero
    })
    Name (_S5, Package (0x04)  // _S5_: S5 System State
    {
        0x05, 
        0x05, 
        Zero, 
        Zero
    })
    Name (WKST, Package (0x02)
    {
        Zero, 
        Zero
    })
    Method (_PTS, 1, NotSerialized)  // _PTS: Prepare To Sleep
    {
        WKST [Zero] = Zero
        WKST [One] = Zero
    }

    Method (_TTS, 1, NotSerialized)  // _TTS: Transition To State
    {
    }

    Method (_WAK, 1, NotSerialized)  // _WAK: Wake
    {
        Return (WKST) /* \WKST */
    }

    Scope (_SI)
    {
        Method (_SST, 1, NotSerialized)  // _SST: System Status
        {
        }
    }

    Scope (_GPE)
    {
    }

    Name (GINT, One)
    Method (_PIC, 1, NotSerialized)  // interrupt model, at the ACPI-standard root location
    {
        GINT = Arg0
    }
    Scope (_SB)
    {
        Method (_PIC, 1, NotSerialized)  // _PIC: Interrupt Model
        {
            GINT = Arg0
        }

        Name (PRT0, Package (0x01)
        {
            Package (0x04)
            {
                0x0007FFFF, 
                Zero, 
                Zero, 
                0x13
            }
        })
        Device (PCI0)
        {
            Name (_HID, EisaId ("PNP0A08"))  // PCI Express root bridge
            Name (_CID, EisaId ("PNP0A03"))
            Name (_UID, Zero)
            Name (CRS0, ResourceTemplate ()
            {
                // Windows the PS5 firmware already programmed into its two PCIe bridges
                // (read from Linux /proc/iomem and lspci on the console).
                WordBusNumber (ResourceProducer, MinFixed, MaxFixed, PosDecode,
                    0x0000, 0x0000, 0x007F, 0x0000, 0x0080)
                WordIO (ResourceProducer, MinFixed, MaxFixed, PosDecode, EntireRange,
                    0x0000, 0x2000, 0x2FFF, 0x0000, 0x1000)
                DWordMemory (ResourceProducer, PosDecode, MinFixed, MaxFixed, NonCacheable, ReadWrite,
                    0x00000000, 0x80000000, 0xC43FFFFF, 0x00000000, 0x44400000)
                DWordMemory (ResourceProducer, PosDecode, MinFixed, MaxFixed, NonCacheable, ReadWrite,
                    0x00000000, 0xD0000000, 0xE06FFFFF, 0x00000000, 0x10700000)
                QWordMemory (ResourceProducer, PosDecode, MinFixed, MaxFixed, NonCacheable, ReadWrite,
                    0x0000000000000000, 0x0000000980000000, 0x000000099FFFFFFF, 0x0000000000000000, 0x0000000020000000)
            })
            Method (_CRS, 0, NotSerialized)
            {
                Return (CRS0)
            }
            Method (_OSC, 4, NotSerialized)  // _OSC: Operating System Capabilities
                        {
                            CreateDWordField (Arg3, Zero, CDW1)
                            If ((Arg0 == ToUUID ("33db4d5b-1ff7-401c-9657-7441c03dd766") /* PCI Host Bridge Device */))
                            {
                                CreateDWordField (Arg3, 0x04, CDW2)
                                CreateDWordField (Arg3, 0x08, CDW3)
                                Local0 = CDW3 /* \_SB_.PCI0._OSC.CDW3 */
                                Local0 &= 0x1E
                                If ((Arg1 != One))
                                {
                                    CDW1 |= 0x08
                                }
            
                                If ((CDW3 != Local0))
                                {
                                    CDW1 |= 0x10
                                }
            
                                CDW3 = Local0
                            }
                            Else
                            {
                                CDW1 |= 0x04
                            }
            
                            Return (Arg3)
                        }
            Method (_BBN, 0, NotSerialized)  // _BBN: BIOS Bus Number
            {
                Return (Zero)
            }

            Method (_STA, 0, NotSerialized)  // _STA: Status
            {
                Return (0x0F)
            }

            Method (_PRT, 0, NotSerialized)  // _PRT: PCI Routing Table
            {
                Return (PRT0) /* \_SB_.PRT0 */
            }
}
    }

    Scope (\_SB.PCI0)
    {
        Device (SF8)
        {
            Name (_ADR, 0x001F0000)
            Device (RTC)
                            {
                                Name (_HID, EisaId ("PNP0B00") /* AT Real-Time Clock */)  // _HID: Hardware ID
                                Name (_CRS, Buffer (0x0D)  // _CRS: Current Resource Settings
                                {
                                    /* 0000 */  0x47, 0x01, 0x70, 0x00, 0x70, 0x00, 0x01, 0x08,  // G.p.p...
                                    /* 0008 */  0x22, 0x00, 0x01, 0x79, 0x00                     // "..y.
                                })
                            }
        }
    }
}

