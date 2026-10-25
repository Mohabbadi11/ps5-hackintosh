/* Stage 1 of the PS5 bring-up chain: runs in place of the Linux 64-bit entry, records what the CPU/boot
 * environment looks like into a fixed physical page (outside the dump kernel's RAM), then hands over to
 * the real kernel that follows this stub in the image. */
typedef unsigned long long u64;
typedef unsigned int u32;
typedef unsigned short u16;
typedef unsigned char u8;

#define MARK_ADDR  0x300000000ULL          /* 12 GiB: RAM of the crashed kernel, not owned by us */
#define NMARK      64

static u64 pml4[512] __attribute__((aligned(4096)));
static u64 pdpt[512] __attribute__((aligned(4096)));

static void build_page_tables(void)
{
    for (u64 g = 0; g < 64; g++) {
        u64 flags = 0x83;                            /* P | RW | PS (1 GiB) */
        if (g == 3 || g == 17)
            flags |= 0x18;                           /* PCD | PWT: 0xC0000000..0xFFFFFFFF and the carve-out gig */
        pdpt[g] = (g << 30) | flags;
    }
    pml4[0] = (u64)(unsigned long)&pdpt[0] | 0x3;
    __asm__ volatile("mov %0, %%cr3" :: "r"((u64)(unsigned long)&pml4[0]) : "memory");
}

static inline u64 rdmsr(u32 msr)
{
    u32 lo, hi;
    __asm__ volatile("rdmsr" : "=a"(lo), "=d"(hi) : "c"(msr));
    return ((u64)hi << 32) | lo;
}

static inline u64 rdtsc(void)
{
    u32 lo, hi;
    __asm__ volatile("rdtsc" : "=a"(lo), "=d"(hi));
    return ((u64)hi << 32) | lo;
}

static inline void cpuid(u32 leaf, u32 sub, u32 *a, u32 *b, u32 *c, u32 *d)
{
    __asm__ volatile("cpuid" : "=a"(*a), "=b"(*b), "=c"(*c), "=d"(*d) : "a"(leaf), "c"(sub));
}


#if VARIANT == 4 || VARIANT == 5
#include "font8x16.h"
#define FB_BASE   0x46a000000ULL           /* VRAM carve-out is system RAM: VRAM offset N == phys 0x450000000 + N */
#define FB_PITCH  10240u
#define FB_W      2560u
#define FB_H      1440u
#define LOG_BASE  (MARK_ADDR + 0x1000ULL)  /* text mirror, readable from Linux afterwards */

static volatile u32 *fb = (volatile u32 *)FB_BASE;      /* moved by find_fb() when the buffer is elsewhere */
static volatile u8  *const logbuf = (volatile u8 *)LOG_BASE;
static u32 cx, cy, logn;
static u32 fg = 0xFFFFFFFFu, bg = 0xFF101040u;

static void put_char(u8 c)
{
#if VARIANT == 4
    if (logn < 0xE000) logbuf[logn++] = c;
#endif
    if (c == '\n') { cx = 0; cy++; return; }
    if (cx >= FB_W / 8) { cx = 0; cy++; }
    if (cy >= FB_H / 16) return;
    const u8 *g = font8x16[c];
    for (u32 row = 0; row < 16; row++) {
        u8 bits = g[row];
        volatile u32 *p = fb + (u64)(cy * 16 + row) * (FB_PITCH / 4) + cx * 8;
        for (u32 col = 0; col < 8; col++)
            p[col] = (bits & (0x80 >> col)) ? fg : bg;
    }
    cx++;
}

static void puts_(const char *s) { while (*s) put_char((u8)*s++); }

static void put_hex(u64 v, int digits)
{
    for (int i = digits - 1; i >= 0; i--)
        put_char("0123456789abcdef"[(v >> (i * 4)) & 0xF]);
}

/* The dumb buffer's place in the carve-out depends on what ran before; look for its signature (8 ascending words
 * 0xDEADBE00.. at pixel (0,0)) on page boundaries. Returns the physical address or 0. */
static u64 find_fb(void)
{
    for (u64 a = 0x450000000ULL; a < 0x470000000ULL; a += 0x1000) {
        volatile u32 *p = (volatile u32 *)a;
        if (p[0] == 0xDEADBE00u && p[1] == 0xDEADBE01u && p[7] == 0xDEADBE07u) {
            fb = p;
            return a;
        }
    }
    return 0;
}

static void clear_screen(void)
{
    for (u64 y = 0; y < FB_H; y++) {
        volatile u32 *p = fb + y * (FB_PITCH / 4);
        for (u32 x = 0; x < FB_W; x++) p[x] = bg;
    }
    cx = cy = 0;
}

static inline void outl(u16 port, u32 v) { __asm__ volatile("outl %0, %1" :: "a"(v), "Nd"(port)); }
static inline u32 inl(u16 port) { u32 v; __asm__ volatile("inl %1, %0" : "=a"(v) : "Nd"(port)); return v; }
static u32 pci_cfg(u32 bus, u32 dev, u32 fn, u32 off)
{
    outl(0xCF8, 0x80000000u | (bus << 16) | (dev << 11) | (fn << 8) | (off & 0xFC));
    return inl(0xCFC);
}

static void stage4_report(u64 bp)
{
    clear_screen();
    puts_("PS5 stage 1 - V4 text console (direct framebuffer, phys 0x46a000000)\n\n");
    puts_("boot_params "); put_hex(bp, 16); puts_("\n");
    u8 n820 = *(volatile u8 *)(bp + 0x1E8);
    puts_("e820 entries: "); put_hex(n820, 2); puts_("\n");
    for (u32 i = 0; i < n820 && i < 64; i++) {
        volatile u8 *e = (volatile u8 *)(bp + 0x2D0 + i * 20);
        u64 a = *(volatile u64 *)e, sz = *(volatile u64 *)(e + 8);
        u32 t = *(volatile u32 *)(e + 16);
        puts_("  "); put_hex(a, 12); puts_(" - "); put_hex(a + sz - 1, 12); puts_("  type "); put_hex(t, 1); puts_("\n");
    }
    puts_("acpi_rsdp_addr "); put_hex(*(volatile u64 *)(bp + 0x70), 16); puts_("\n");
    puts_("cmd_line_ptr   "); put_hex(*(volatile u32 *)(bp + 0x228), 8); puts_("\n\n");
    puts_("PCI devices (config mechanism 1, buses 00 20 40):\n");
    static const u32 buses[3] = { 0x00, 0x20, 0x40 };
    for (int bi = 0; bi < 3; bi++)
        for (u32 d = 0; d < 32; d++)
            for (u32 f = 0; f < 8; f++) {
                u32 id = pci_cfg(buses[bi], d, f, 0);
                if ((id & 0xFFFF) == 0xFFFF) { if (f == 0) break; continue; }
                u32 cls = pci_cfg(buses[bi], d, f, 8) >> 8;
                puts_("  "); put_hex(buses[bi], 2); put_char(':'); put_hex(d, 2); put_char('.'); put_hex(f, 1);
                puts_("  "); put_hex(id & 0xFFFF, 4); put_char(':'); put_hex(id >> 16, 4);
                puts_("  class "); put_hex(cls, 6); puts_("\n");
            }
}
#endif

#if VARIANT == 5
/* Stage 1 as a loader for the EDK2 Universal Payload: the kexec initrd is a "PS5BNDL1" bundle (uefi/mkbundle.py) with
 * segments to copy to fixed physical addresses, the entry point, the HOB list address (rcx) and a stack. */
static void copy_bytes(u64 dst, u64 src, u64 n)
{
    __asm__ volatile("cld; rep movsb" : "+D"(dst), "+S"(src), "+c"(n) :: "memory");
}

static void zero_bytes(u64 dst, u64 n)
{
    __asm__ volatile("cld; rep stosb" : "+D"(dst), "+c"(n) : "a"(0) : "memory");
}

static void stage5_launch(u64 bp)
{
    u64 img = (u64)*(volatile u32 *)(bp + 0x218) | ((u64)*(volatile u32 *)(bp + 0xC0) << 32);
    u64 isz = (u64)*(volatile u32 *)(bp + 0x21C) | ((u64)*(volatile u32 *)(bp + 0xC4) << 32);
    clear_screen();
    puts_("PS5 stage 1 - V5 loader for the UEFI payload\n\n");
    puts_("boot_params "); put_hex(bp, 16); puts_("\n");
    puts_("bundle (initrd) at "); put_hex(img, 12); puts_(" size "); put_hex(isz, 8); puts_("\n");
    u64 magic = *(volatile u64 *)img;
    if (magic != 0x314C444E42355350ULL) {          /* "PS5BNDL1" */
        puts_("bad bundle magic "); put_hex(magic, 16); puts_("\nHOLD\n");
        for (;;) __asm__ volatile("pause");
    }
    u64 entry = *(volatile u64 *)(img + 8), rcx = *(volatile u64 *)(img + 16), rsp = *(volatile u64 *)(img + 24);
    u64 fbpatch = *(volatile u64 *)(img + 32);
    u32 count = *(volatile u32 *)(img + 40);
    u64 fbaddr = (u64)(unsigned long)fb;
    puts_("entry "); put_hex(entry, 12); puts_("  hob list "); put_hex(rcx, 12); puts_("  rsp "); put_hex(rsp, 12);
    puts_("  segments "); put_hex(count, 2); puts_("\n");
    for (u32 i = 0; i < count; i++) {
        volatile u64 *e = (volatile u64 *)(img + 48 + (u64)i * 24);
        u64 dest = e[0], size = e[1], off = e[2];
        puts_("  copy "); put_hex(dest, 12); puts_(" <- "); put_hex(size, 8); puts_(" bytes\n");
        if (off == ~0ULL) zero_bytes(dest, size); else copy_bytes(dest, img + off, size);
    }
    /* hand the cursor and the framebuffer address over to the UEFI console (Ps5FbSerialPortLib keeps its state at
     * phys 0x300001f00) and patch the GOP HOB inside the copied HOB list */
    volatile u32 *cs = (volatile u32 *)0x300001f00ULL;
    cs[0] = 0x50354643U; cs[1] = 0; cs[2] = cy + 1; cs[3] = 0;
    *(volatile u64 *)0x300001f10ULL = fbaddr;
    if (fbpatch) *(volatile u64 *)fbpatch = fbaddr;
    puts_("framebuffer at "); put_hex(fbaddr, 12); puts_("\n");
    /* The crash kexec shuts the local APIC down (software-disable); UEFI's LocalApicTimerDxe assumes it is enabled,
     * otherwise BdsWait never sees a timer tick and the boot manager sleeps forever. */
    volatile u32 *lapic = (volatile u32 *)0xFEE00000ULL;
    puts_("LAPIC svr before "); put_hex(lapic[0xF0 / 4], 8);
    lapic[0x80 / 4] = 0;                              /* task priority: accept everything */
    lapic[0xF0 / 4] = 0x1FF;                          /* software enable, spurious vector 0xFF */
    lapic[0x320 / 4] = 0x10000;                       /* timer masked until UEFI programs it */
    puts_(" after "); put_hex(lapic[0xF0 / 4], 8); puts_("  id "); put_hex(lapic[0x20 / 4], 8); puts_("\n");
    puts_("\njumping to the UEFI payload...\n");
    __asm__ volatile("wbinvd" ::: "memory");
    *(volatile u64 *)(rsp - 8) = 0;                  /* fake return address, rsp ends up 8 mod 16 as after a call */
    __asm__ volatile("mov %0, %%rcx\n\tmov %1, %%rsp\n\txor %%ebp, %%ebp\n\tjmp *%2"
                     :: "r"(rcx), "r"(rsp - 8), "r"(entry) : "memory");
    __builtin_unreachable();
}
#endif

/* The image was built 2 MiB longer than the real kernel (stub in front); kexec sized the load area with
 * that bigger init_size, but the decompressor derives the end of its buffer from the same field starting at
 * the real kernel (+2 MiB), so give it back the original value or it would overrun the area by 2 MiB. */
#define STUB_SIZE 0x200000U

void stage1_main(u64 boot_params)
{
    volatile u32 *init_size = (volatile u32 *)(unsigned long)(boot_params + 0x260);
    *init_size -= STUB_SIZE;
#if VARIANT >= 1
    u64 cr0, cr3_old, cr4;
    __asm__ volatile("mov %%cr0, %0" : "=r"(cr0));
    __asm__ volatile("mov %%cr3, %0" : "=r"(cr3_old));
    __asm__ volatile("mov %%cr4, %0" : "=r"(cr4));

    build_page_tables();

    volatile u64 *m = (volatile u64 *)MARK_ADDR;
    for (int i = 0; i < NMARK; i++)
        m[i] = 0;

    u32 a, b, c, d;
    int n = 2;
    m[n++] = boot_params;
    m[n++] = cr0;
    m[n++] = cr3_old;
    m[n++] = cr4;
    m[n++] = rdmsr(0xC0000080);                      /* EFER */
    m[n++] = rdmsr(0x0000001B);                      /* IA32_APIC_BASE */
    m[n++] = rdtsc();
    cpuid(0, 0, &a, &b, &c, &d);
    m[n++] = a;
    m[n++] = ((u64)d << 32) | b;                     /* vendor "AuthenticAMD" pieces */
    m[n++] = c;
    cpuid(1, 0, &a, &b, &c, &d);
    m[n++] = a;                                      /* family/model/stepping */
    m[n++] = b;                                      /* APIC id in bits 31:24 */
    m[n++] = ((u64)d << 32) | c;
    m[n++] = (u64)(unsigned long)&pml4[0];           /* where the stub lives */
#if VARIANT == 2
#ifndef PAINT_BYTES
#define PAINT_BYTES 0xF00000ULL
#endif
    u64 t0 = rdtsc();
    /* Paint both scanout buffers (VRAM+0x1c000000 / +0x1e000000, 15 MiB each) through the GPU's MM_INDEX/MM_DATA
     * window, which reaches VRAM above the 256 MiB BAR0 aperture. One colour per 64 KiB swizzle block. */
    static const u32 palette[8] = { 0x00FF0000, 0x0000FF00, 0x000000FF, 0x00FFFFFF,
                                    0x00FFFF00, 0x0000FFFF, 0x00FF00FF, 0x00808080 };
    volatile u32 *gr = (volatile u32 *)0xE0600000ULL;
    gr[0x18 / 4] = 0;                                /* MM_INDEX_HI */
    for (int bo = 0; bo < 2; bo++) {
        u64 base = bo ? 0x1e000000ULL : 0x1c000000ULL;
        for (u64 off = 0; off < PAINT_BYTES; off += 4) {
            gr[0] = (u32)((base + off) | 0x80000000ULL);
            gr[1] = palette[((off >> 16) + bo) & 7];
#ifdef THROTTLE
            if ((off & (THROTTLE - 1)) == (THROTTLE - 4))
                (void)gr[1];                         /* non-posted read: waits for the writes before it */
#endif
        }
        gr[0] = (u32)(base | 0x80000000ULL);
        m[n++] = gr[1];                              /* read-back of the first painted word */
    }
    m[n++] = rdtsc() - t0;                           /* TSC ticks spent painting */
#ifdef DELAY_TICKS
    for (u64 t1 = rdtsc(); rdtsc() - t1 < DELAY_TICKS; )   /* keep the picture up long enough to be looked at */
        __asm__ volatile("pause");
#endif
    m[1] = n;
#endif
#if VARIANT == 3
    /* Display endurance probe: draw a tick on the linear test buffer (VRAM+0x1a000000, pitch 10240) every second for
     * HOLD_SECONDS, so whoever watches the screen can read off when the signal dies. */
    volatile u32 *gr = (volatile u32 *)0xE0600000ULL;
    const u64 LIN = 0x1a000000ULL, TSC_HZ = 1596300000ULL;
    gr[0x18 / 4] = 0;
    gr[0] = (u32)(LIN | 0x80000000ULL);
    u32 sig0 = gr[1];
    gr[0] = (u32)((LIN + 4) | 0x80000000ULL);
    u32 sig1 = gr[1];
    m[n++] = sig0;
    m[n++] = sig1;
    if (sig0 == 0xDEADBE00u && sig1 == 0xDEADBE01u) {
        u64 start = rdtsc();
        for (u32 sec = 0; sec < HOLD_SECONDS; sec++) {
            u32 color = (sec % 10 == 9) ? 0xFFFF0000u : 0xFFFFFFFFu;     /* red every 10 s */
            for (u32 y = 0; y < 40; y++) {
                for (u32 x = 0; x < 24; x++) {
                    u64 pos = LIN + (u64)(y + 10) * 10240 + (u64)(sec * 26 + x + 8) * 4;
                    gr[0] = (u32)(pos | 0x80000000ULL);
                    gr[1] = color;
                }
                gr[0] = (u32)(LIN | 0x80000000ULL);
                (void)gr[1];
            }
            while (rdtsc() - start < (u64)(sec + 1) * TSC_HZ)
                __asm__ volatile("pause");
        }
    }
    m[1] = n;
#endif
#if VARIANT == 4
    {
        u64 fbaddr = find_fb();
        m[n++] = fbaddr;
        if (fbaddr) {
            stage4_report(boot_params);
            u64 start = rdtsc();
            while (rdtsc() - start < (u64)HOLD_SECONDS * 1596300000ULL)
                __asm__ volatile("pause");
        }
        m[n++] = logn;
        m[1] = n;
    }
#endif
#if VARIANT == 5
    {
        u64 fbaddr = find_fb();
        m[n++] = fbaddr;
        if (fbaddr)
            stage5_launch(boot_params);
        m[n++] = 0xBAD0F8;                           /* no linear framebuffer: go back to Linux */
        m[1] = n;
    }
#endif
    m[0] = 0x0031425554533550ULL;                   /* "P5STUB1" tag, written last */
    m[1] = n;
#endif
}
