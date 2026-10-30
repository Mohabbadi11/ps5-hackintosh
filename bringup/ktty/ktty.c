/* In-kernel text console for the macOS boot: XNU's whole console output (printf and kprintf, with the serial=3 boot-arg) ends
 * in serial_putc(); the PS5 has no UART and macOS' own video console never shows up, so OpenCore patches serial_putc() with
 * this routine, which draws each character straight into the scanout buffer through the GPU's I/O-port BAR
 * (0x2000: MM_INDEX, 0x2004: MM_DATA, bit 31 of the index = VRAM access). It needs no page tables and no kernel services.
 *
 * Cursor state lives in the VRAM itself, in the pixel (0, 1439) below the text area: bits 0-8 column, 9-15 row, 16 wrapped,
 * 24-31 magic 0x5A. A missing magic means first call: clear the screen. After the text area has wrapped once, every new line is
 * cleared before it is written.
 * Build: tools/make_ktty.py (clang -Os, flat binary, rewrites KTTY_FB_OFF with the boot's VRAM offset of the framebuffer). */
typedef unsigned char u8;
typedef unsigned short u16;
typedef unsigned int u32;
typedef unsigned long long u64;

#include "ktty_font.h"

/* VRAM offset of pixel (0,0): a placeholder rewritten by patch_tripwire.py. Volatile so that the compiler keeps it as one
 * 32-bit load from the blob (a constant would be folded into other immediates the patcher cannot find). */
static volatile const u32 ktty_fb_off __attribute__((used)) = 0xDEADF00Du;
#define KTTY_FB_OFF ktty_fb_off
#define PITCH       10240u
#define RING_COLS   159u                   /* left half of the screen: the running log, a bar in column 159 marks the cursor row */
#define PANIC_COLS  160u                   /* right half: everything from the first "panic(" on, so the dump is never overwritten */
#define PANIC_X0    160u                   /* first column of the right half */
#define ROWS        89u
#define FG          0xFFE0E0E0u
#define BG          0xFF000000u
#define BAR         0xFFFFFF00u

static inline void out32(u16 port, u32 v) { __asm__ volatile("outl %0, %1" :: "a"(v), "Nd"(port)); }
static inline u32 in32(u16 port) { u32 v; __asm__ volatile("inl %1, %0" : "=a"(v) : "Nd"(port)); return v; }
static inline void px(u32 off, u32 colour) { out32(0x2000, off | 0x80000000u); out32(0x2004, colour); }

static void clear_rect(u32 x0, u32 y0, u32 lines, u32 w)
{
    for (u32 y = y0; y < y0 + lines; y++)
        for (u32 x = 0; x < w; x++)
            px(KTTY_FB_OFF + y * PITCH + (x0 + x) * 4, BG);
}

static void bar(u32 row, u32 colour)
{
    for (u32 y = 0; y < 16; y++)
        for (u32 x = 0; x < 8; x++)
            px(KTTY_FB_OFF + (row * 16 + y) * PITCH + (RING_COLS * 8 + x) * 4, colour);
}

static void glyph(u32 col, u32 row, u8 c)
{
    const u8 *g = ktty_font[c - 32];
    for (u32 y = 0; y < 16; y++) {
        u8 bits = g[y];
        u32 base = KTTY_FB_OFF + (row * 16 + y) * PITCH + col * 32;
        for (u32 x = 0; x < 8; x++)
            if (bits & (0x80 >> x)) px(base + x * 4, FG);          /* the cell is already black: only the lit pixels cost I/O */
    }
}

static void kch(u8 c);

#ifdef KTTY_DUMP_PAT
static void kputs(const char *t) { while (*t) kch((u8)*t++); }
static void khex(u64 v, int digits)
{
    for (int i = digits - 1; i >= 0; i--) kch((u8)"0123456789abcdef"[(v >> (i * 4)) & 0xF]);
}
static inline u64 rdmsr64(u32 msr) { u32 lo, hi; __asm__ volatile("rdmsr" : "=a"(lo), "=d"(hi) : "c"(msr)); return ((u64)hi << 32) | lo; }

/* What does the LAPIC look like, and does the CPU take interrupts at all? The kernel's LAPIC base lives in a kernel variable whose
 * distance from this routine is known at build time (KTTY_LAPIC_DELTA); registers are read the way the kernel does it (base + reg). */
static volatile u32 *lapic_base(void)
{
    volatile u64 *pv;
    __asm__ volatile("lea ktty_main(%%rip), %0\n\tadd %1, %0" : "=&r"(pv) : "er"((long)KTTY_LAPIC_DELTA));
    return (volatile u32 *)*pv;
}

static void dump_lapic(const char *tag)
{
    volatile u32 *l = lapic_base();
    u64 rfl; __asm__ volatile("pushfq; pop %0" : "=r"(rfl));
    struct { u16 limit; u64 base; } __attribute__((packed)) idt;
    __asm__ volatile("sidt %0" : "=m"(idt));
    kputs("\nLAPIC "); kputs(tag); kputs(": base "); khex((u64)l, 16); kputs(" rflags "); khex(rfl, 4);
    kputs(" apicbase "); khex(rdmsr64(0x1B), 8);
    kputs("\n id "); khex(l[0x20 / 4], 8); kputs(" ver "); khex(l[0x30 / 4], 8); kputs(" tpr "); khex(l[0x80 / 4], 4);
    kputs(" ppr "); khex(l[0xA0 / 4], 4); kputs(" svr "); khex(l[0xF0 / 4], 4); kputs(" esr "); khex(l[0x280 / 4], 4);
    kputs("\n lvt timer "); khex(l[0x320 / 4], 8); kputs(" lint0 "); khex(l[0x350 / 4], 8); kputs(" lint1 "); khex(l[0x360 / 4], 8);
    kputs(" err "); khex(l[0x370 / 4], 8);
    kputs("\n timer init "); khex(l[0x380 / 4], 8); kputs(" cur "); khex(l[0x390 / 4], 8); kputs(" div "); khex(l[0x3E0 / 4], 4);
    kputs("\n isr "); for (int i = 7; i >= 0; i--) { khex(l[(0x100 + 16 * i) / 4], 8); kch(' '); }
    kputs("\n irr "); for (int i = 7; i >= 0; i--) { khex(l[(0x200 + 16 * i) / 4], 8); kch(' '); }
    kputs("\n idt limit "); khex(idt.limit, 4); kputs(" base "); khex(idt.base, 16); kch('\n');
}

static void dump_core(void)
{
    u64 cr0, cr4, cr8, cr3; u32 a, b, c, d;
    u64 efer = rdmsr64(0xC0000080);
    __asm__ volatile("mov %%cr0, %0; mov %%cr3, %1; mov %%cr4, %2; mov %%cr8, %3" : "=r"(cr0), "=r"(cr3), "=r"(cr4), "=r"(cr8));
    kputs("\nCORE cr0 "); khex(cr0, 8); kputs(" cr3 "); khex(cr3, 16); kputs(" cr4 "); khex(cr4, 8); kputs(" cr8 "); khex(cr8, 2);
    kputs("\n efer "); khex(efer, 8); kputs(" vm_cr "); khex(rdmsr64(0xC0010114), 8); kputs(" hwcr "); khex(rdmsr64(0xC0010015), 8);
    __asm__ volatile("cpuid" : "=a"(a), "=b"(b), "=c"(c), "=d"(d) : "a"(1), "c"(0));
    kputs("\n cpuid1 ecx "); khex(c, 8);
    __asm__ volatile("cpuid" : "=a"(a), "=b"(b), "=c"(c), "=d"(d) : "a"(0x8000000A), "c"(0));
    kputs("\n svm "); khex(a, 8); kputs(" d "); khex(d, 8);
    __asm__ volatile("cpuid" : "=a"(a), "=b"(b), "=c"(c), "=d"(d) : "a"(0x80000001), "c"(0));
    kputs(" ext1 ecx "); khex(c, 8); kputs(" syscfg "); khex(rdmsr64(0xC0010010), 8); kch('\n');
}

static void lapic_probe(void)
{
    dump_lapic("before");
    dump_core();
    /* The LAPIC takes the self-IPI (IRR) but the core never accepts a maskable interrupt, whatever the vector. An NMI ignores IF
     * and TPR: if it reaches the kernel's NMI handler the LAPIC->core path works and only INTR gating is at fault. */
    volatile u32 *l = lapic_base();
    kputs("nmi\n");
    l[0x310 / 4] = 0;
    l[0x300 / 4] = 0x00044400u;
    for (volatile u64 i = 0; i < 400000000ull; i++) { }
    dump_lapic("after nmi");
}
#endif

__attribute__((section(".text.entry"), used))
void ktty_main(u8 c)
{
    const u32 state_off = KTTY_FB_OFF + 1439u * PITCH;
#if defined(KTTY_RETURN_PAT) || defined(KTTY_DUMP_PAT)
    out32(0x2000, state_off | 0x80000000u);
    if ((in32(0x2004) >> 24) == 0x5A) {                 /* the screen is initialised: the matchers' state is valid */
#ifdef KTTY_RETURN_PAT
        static const char rpat[] = KTTY_RETURN_PAT;
        out32(0x2000, (state_off + 4) | 0x80000000u);
        u32 rst = in32(0x2004);
        u32 ridx = ((rst >> 24) == 0xA5u) ? (rst & 0xFF) : 0;
        if (c == (u8)rpat[ridx]) ridx++; else ridx = (c == (u8)rpat[0]) ? 1 : 0;
        out32(0x2000, (state_off + 4) | 0x80000000u);
        out32(0x2004, 0xA5000000u | ridx);
        if (ridx == sizeof(rpat) - 1)
            __asm__ volatile("lea ktty_main(%%rip), %%rax; add $%c0, %%rax; jmp *%%rax" :: "i"(KTTY_HALT_DELTA) : "rax");
#endif
#ifdef KTTY_DUMP_PAT
        static const char dpat[] = KTTY_DUMP_PAT;
        out32(0x2000, (state_off + 8) | 0x80000000u);
        u32 dst = in32(0x2004);
        u32 didx = ((dst >> 24) == 0xA5u) ? (dst & 0xFF) : 0;
        if (c == (u8)dpat[didx]) didx++; else didx = (c == (u8)dpat[0]) ? 1 : 0;
        int fire = (didx == sizeof(dpat) - 1);
        if (fire) didx = 0x80;                          /* fire once */
        out32(0x2000, (state_off + 8) | 0x80000000u);
        out32(0x2004, 0xA5000000u | didx);
        if (didx == 0x80 && fire) { kch(c); lapic_probe(); return; }
#endif
    }
#endif
    kch(c);
}

static void kch(u8 c)
{
    static const u8 pat[6] = { 'p', 'a', 'n', 'i', 'c', '(' };
    const u32 state_off = KTTY_FB_OFF + 1439u * PITCH;
    out32(0x2000, state_off | 0x80000000u);
    u32 st = in32(0x2004);
    if ((st >> 24) != 0x5A) {
        clear_rect(0, 0, 1439, 2560);
        st = 0x5A000000u;
        bar(0, BAR);
    }
    u32 col = st & 0x1FF, row = (st >> 9) & 0x7F, wrapped = (st >> 16) & 1, pmode = (st >> 17) & 1, midx = (st >> 18) & 7;

    if (!pmode) {                                       /* watch for "panic(": from there on write into the right half */
        if (c == pat[midx]) midx++;
        else midx = (c == 'p') ? 1 : 0;
        if (midx == 6) {
            pmode = 1; midx = 0; col = 0; row = 0; wrapped = 0;
            for (u32 i = 0; i < 6; i++) glyph(PANIC_X0 + col++, row, pat[i]);
            goto store;
        }
    }
    u32 xoff = pmode ? PANIC_X0 : 0, width = pmode ? PANIC_COLS : RING_COLS;
    int newline = 0;
    if (c == '\n') {
        newline = 1;
    } else if (c == '\r') {
        col = 0;
    } else if (c == '\t') {
        col = (col + 8) & ~7u;
        if (col >= width) newline = 1;
    } else if (c >= 32 && c < 127) {
        glyph(xoff + col, row, c);
        if (++col >= width) newline = 1;
    }
    if (newline) {
        if (!pmode) bar(row, BG);
        col = 0;
        if (++row >= ROWS) { row = 0; wrapped = 1; }
        if (wrapped) clear_rect(xoff * 8, row * 16, 16, width * 8);
        if (!pmode) bar(row, BAR);
    }
store:
    out32(0x2000, state_off | 0x80000000u);
    out32(0x2004, 0x5A000000u | (midx << 18) | (pmode << 17) | (wrapped << 16) | (row << 9) | col);
}
