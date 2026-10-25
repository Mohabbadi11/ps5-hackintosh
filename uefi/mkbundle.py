#!/usr/bin/env python3
"""Pack the EDK2 Universal Payload ELF plus a ready-made HOB list into a "PS5 bundle" for stage 1.

Stage 1 (bringup/stub.c, VARIANT 5) receives the bundle as the kexec initrd, copies each segment to its physical
address, loads rsp/rcx and jumps to the payload entry (_ModuleEntryPoint(HobList), MS x64 ABI: rcx = HOB list).

Bundle layout (little endian):
    u8[8]  magic "PS5BNDL1"
    u64    entry          physical address to jump to
    u64    rcx            first argument (HOB list address)
    u64    rsp            initial stack pointer
    u64    fbpatch        physical address of the GOP HOB's FrameBufferBase (stage 1 patches the found framebuffer in)
    u32    count, u32 pad
    count * { u64 dest, u64 size, u64 offset }   offset == 0xFFFF_FFFF_FFFF_FFFF means "zero-fill"
    ...    data
"""
import argparse, struct, sys, uuid

# ---- physical layout (all inside the crash-kernel RAM that stage 1 and the payload share) ---------------------------
BASE        = 0x68000000          # payload image base (must match the -l used for the build: 1744830464)
FV_BASE     = BASE + 0x00100000   # DXE FV, then BDS FV
HOB_BASE    = BASE + 0x00800000   # HOB list region 0x68800000-0x68900000
HOB_TOP     = HOB_BASE + 0x00100000
STACK_TOP   = BASE + 0x00A00000   # 256 KiB stack just below
STACK_SIZE  = 0x00040000
RESERVED_LO, RESERVED_HI = BASE, BASE + 0x00A00000    # reported as allocated (BootServicesData)

# ---- PS5 facts ------------------------------------------------------------------------------------------------------
FB_BASE, FB_PITCH, FB_W, FB_H = 0x46a000000, 10240, 2560, 1440
RSDP = 0x7fd8e014
ECAM_BASE, ECAM_SIZE = 0xF0000000, 0x8000000      # e820 "reserved" window, to be confirmed with MSR C001_0058

# RAM handed to UEFI (and later macOS). Taken from the stock Arch kernel's e820 map, minus what stage 1 uses.
RAM = [
    (0x00100000, 0x01000000),
    (0x40000000, 0x60000000),
    (0x60c00000, 0x62800000),
    (0x64829000, 0x7a000000),     # includes the payload area; the top 0x7a000000-0x7f000000 holds kexec's segments
    (0x7f000000, 0x7f9d0000),
    (0x100000000, 0x300000000),
    (0x300100000, 0x450000000),   # 0x300000000-0x300100000 is the marks/log area
    (0x470000000, 0x47f300000),
]
RESERVED = [
    (0x7a000000, 0x7f000000),     # stage 1 + kexec segments (kernel image, boot_params, initrd)
    (0x7f9d0000, 0xc4400000),     # firmware, ACPI tables (RSDP 0x7fd8e014), NVS, PCI holes
    (0x300000000, 0x300100000),   # stage-1 marks and console log
]
MMIO = [
    (0xc4400000, 0x100000000),
    (0x450000000, 0x470000000),   # VRAM carve-out (framebuffer lives here)
    (0x47f300000, 0x480000000),
]

ATTR_RAM  = 0x00003c07   # present|initialized|tested | UC|WC|WT|WB
ATTR_MMIO = 0x00000c03   # present|initialized | UC|WC
ATTR_RSVD = 0x00000003
ATTR_IO   = 0x00000003

G = lambda s: uuid.UUID(s).bytes_le
GUID_EXTRA_DATA   = G("15a5baf6-1c91-467d-9dfb-319d178d4bb4")
GUID_ACPI_TABLE   = G("9f9a9506-5597-4515-bab6-8bcde784ba87")
GUID_PCI_ROOT     = G("ec4ebacb-2638-416e-be80-e5fa4b511901")
GUID_GFX_INFO     = G("39f62cce-6825-4669-bb56-541aba753a07")
GUID_GFX_DEV      = G("e5cb2ac9-d35d-4430-936e-1de332478de7")
GUID_ACPI_BOARD   = G("0ad3d31b-b3d8-4506-ae71-2ef11006d90f")

EFI_RESOURCE_SYSTEM_MEMORY, EFI_RESOURCE_MMIO, EFI_RESOURCE_IO, EFI_RESOURCE_MEM_RESERVED = 0, 1, 2, 5


def hob(htype, payload):
    return struct.pack("<HHI", htype, 8 + len(payload), 0) + payload


def pad8(b):
    return b + b"\0" * (-len(b) % 8)


def resource_hob(rtype, attr, start, length):
    return hob(3, b"\0" * 16 + struct.pack("<IIQQ", rtype, attr, start, length))


def guid_hob(guid, data):
    return hob(4, pad8(guid + data))


def memalloc_hob(base, length, mtype):
    return hob(2, b"\0" * 16 + struct.pack("<QQI4x", base, length, mtype))


def generic_header(length, revision=1):
    return struct.pack("<BBH", revision, 0, length)


def build_hobs(fvs):
    """fvs: list of (identifier, base, size)."""
    body = b""
    body += hob(6, struct.pack("<BB6x", 40, 16))                               # CPU: 40-bit memory, 16-bit I/O
    for s, e in RAM:
        body += resource_hob(EFI_RESOURCE_SYSTEM_MEMORY, ATTR_RAM, s, e - s)
    for s, e in RESERVED:
        body += resource_hob(EFI_RESOURCE_MEM_RESERVED, ATTR_RSVD, s, e - s)
    for s, e in MMIO:
        body += resource_hob(EFI_RESOURCE_MMIO, ATTR_MMIO, s, e - s)
    body += resource_hob(EFI_RESOURCE_IO, ATTR_IO, 0x0, 0x10000)
    body += memalloc_hob(RESERVED_LO, RESERVED_HI - RESERVED_LO, 4)            # EfiBootServicesData

    entries = b"".join(struct.pack("<16sQQ", i.encode().ljust(16, b"\0"), b, sz) for i, b, sz in fvs)
    extra = generic_header(4 + 4 + len(entries)) + struct.pack("<I", len(fvs)) + entries
    body += guid_hob(GUID_EXTRA_DATA, extra)

    body += guid_hob(GUID_ACPI_TABLE, generic_header(12) + struct.pack("<Q", RSDP))

    # ACPI_BOARD_INFO: Sony's FADT is not parsed (no PM1 timer/reset we can rely on); give the PCIe config window.
    board = struct.pack("<B2xB", 1, 0) + struct.pack("<QQQQQQQ", 0, 0, 0, 0, 0, ECAM_BASE, ECAM_SIZE)
    body += guid_hob(GUID_ACPI_BOARD, board)

    global FB_PATCH_OFFSET
    FB_PATCH_OFFSET = None
    gfx = struct.pack("<QI", FB_BASE, FB_PITCH * FB_H)
    gfx += struct.pack("<IIII", 0, FB_W, FB_H, 1)                               # version, w, h, PixelBlueGreenRedReserved8Bit
    gfx += struct.pack("<IIII", 0x00FF0000, 0x0000FF00, 0x000000FF, 0xFF000000) # masks (unused for BGRX)
    gfx += struct.pack("<I", FB_PITCH // 4)
    FB_PATCH_OFFSET = 56 + len(body) + 8 + 16             # PHIT(56) + HOBs so far + this HOB's header(8) + GUID(16)
    body += guid_hob(GUID_GFX_INFO, gfx)
    body += guid_hob(GUID_GFX_DEV, struct.pack("<HHHHBB", 0x1002, 0x13fc, 0xFFFF, 0xFFFF, 0xFF, 0xFF))

    # One root bridge covering buses 00-7f; resources were assigned by the console firmware, keep them.
    ap = lambda b, l: struct.pack("<QQQ", b, l, 0)
    rb = struct.pack("<IQQBBQ", 0, 0, 0, 1, 0, 0)                               # segment, supports, attrs, dma4g, noext, alloc
    rb += ap(0x00, 0x7f) + ap(0x2000, 0xffff) + ap(0x80000000, 0xe06fffff) + ap(0, 0) + ap(0, 0) + ap(0, 0)
    rb += struct.pack("<II", 0x0a0841d0, 0)                                     # EISA PNP0A08, UID 0
    pci = generic_header(4 + 2 + len(rb)) + struct.pack("<BB", 1, 1) + rb
    body += guid_hob(GUID_PCI_ROOT, pci)

    # PHIT first, then the rest, then the end marker
    end = hob(0xFFFF, b"")
    phit_len = 56
    free_bottom = HOB_BASE + phit_len + len(body) + len(end)
    free_bottom = (free_bottom + 0xFFF) & ~0xFFF
    phit = hob(1, struct.pack("<IIQQQQQ", 9, 0, HOB_TOP, HOB_BASE, HOB_TOP - 0x1000, free_bottom,
                              HOB_BASE + phit_len + len(body)))
    assert len(phit) == phit_len
    blob = phit + body + end
    assert HOB_BASE + len(blob) <= free_bottom <= HOB_TOP
    return blob


def parse_elf(path):
    d = open(path, "rb").read()
    assert d[:4] == b"\x7fELF" and d[4] == 2
    (e_type, e_machine, _, e_entry, e_phoff, e_shoff, _, _, e_phentsize, e_phnum, e_shentsize, e_shnum,
     e_shstrndx) = struct.unpack_from("<HHIQQQIHHHHHH", d, 16)
    loads = []
    for i in range(e_phnum):
        p_type, _, p_off, p_vaddr, _, p_filesz, p_memsz, _ = struct.unpack_from("<IIQQQQQQ", d, e_phoff + i * e_phentsize)
        if p_type == 1:
            loads.append((p_vaddr, p_off, p_filesz, p_memsz))
    secs = {}
    shstr = struct.unpack_from("<IIQQQQIIQQ", d, e_shoff + e_shstrndx * e_shentsize)
    stroff = shstr[4]
    for i in range(e_shnum):
        n, t, _, addr, off, size, *_ = struct.unpack_from("<IIQQQQIIQQ", d, e_shoff + i * e_shentsize)
        name = d[stroff + n: d.index(b"\0", stroff + n)].decode()
        secs[name] = (t, addr, off, size)
    return d, e_entry, loads, secs


def main():
    ap_ = argparse.ArgumentParser()
    ap_.add_argument("elf")
    ap_.add_argument("out")
    a = ap_.parse_args()
    d, entry, loads, secs = parse_elf(a.elf)

    img_size = max(v + m for v, _, _, m in loads)
    image = bytearray(img_size)
    for v, off, fsz, msz in loads:
        image[v:v + fsz] = d[off:off + fsz]
    # dynamic relocations (.rela, section type RELA at addresses outside any LOAD segment): only RELATIVE are expected
    t, _, roff, rsz = secs[".rela"]
    nrel = 0
    for i in range(rsz // 24):
        r_off, r_info, r_add = struct.unpack_from("<QQq", d, roff + i * 24)
        rtype = r_info & 0xFFFFFFFF
        if rtype == 8:
            struct.pack_into("<Q", image, r_off, BASE + r_add)
            nrel += 1
        elif rtype != 0:
            sys.exit(f"unsupported dynamic relocation type {rtype}")
    print(f"image {img_size:#x} bytes, {nrel} relative relocations, entry {BASE + entry:#x}")

    fvs = []
    fvdata = []
    cur = FV_BASE
    for ident, sec in (("uefi_fv", ".upld.uefi_fv"), ("bds_fv", ".upld.bds_fv")):
        _, _, off, size = secs[sec]
        blob = d[off:off + size]
        fv_len = struct.unpack_from("<Q", blob, 32)[0]          # EFI_FIRMWARE_VOLUME_HEADER.FvLength
        assert fv_len <= size, (ident, fv_len, size)
        fvs.append((ident, cur, fv_len))
        fvdata.append((cur, blob[:fv_len]))
        cur = (cur + fv_len + 0xFFFF) & ~0xFFFF
        print(f"{ident}: {fv_len:#x} bytes at {fvs[-1][1]:#x}")
    assert cur <= HOB_BASE, "FVs overlap the HOB region"

    hobs = build_hobs(fvs)
    print(f"HOB list: {len(hobs):#x} bytes at {HOB_BASE:#x}")

    segments = [(BASE, bytes(image))] + fvdata + [(HOB_BASE, hobs)]
    hdr = struct.pack("<8sQQQQII", b"PS5BNDL1", BASE + entry, HOB_BASE, STACK_TOP - 0x40,
                      HOB_BASE + FB_PATCH_OFFSET, len(segments), 0)
    table_len = len(segments) * 24
    off = len(hdr) + table_len
    table, data = b"", b""
    for dest, blob in segments:
        table += struct.pack("<QQQ", dest, len(blob), off + len(data))
        data += blob
        data += b"\0" * (-len(data) % 16)
    open(a.out, "wb").write(hdr + table + data)
    print(f"bundle {a.out}: {len(hdr) + len(table) + len(data):#x} bytes, {len(segments)} segments")


if __name__ == "__main__":
    main()
