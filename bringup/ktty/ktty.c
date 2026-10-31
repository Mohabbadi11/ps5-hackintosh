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

/* The LAPIC's virtual base lives in a kernel variable whose distance from this routine is known at build time (KTTY_LAPIC_DELTA). */
static volatile u32 *lapic_base(void)
{
    volatile u64 *pv;
    __asm__ volatile("lea ktty_main(%%rip), %0\n\tadd %1, %0" : "=&r"(pv) : "er"((long)KTTY_LAPIC_DELTA));
    return (volatile u32 *)*pv;
}


#ifdef KTTY_DUMP_PAT
static void kputs(const char *t) { while (*t) kch((u8)*t++); }
static void khex(u64 v, int digits)
{
    for (int i = digits - 1; i >= 0; i--) kch((u8)"0123456789abcdef"[(v >> (i * 4)) & 0xF]);
}
static inline u64 rdmsr64(u32 msr) { u32 lo, hi; __asm__ volatile("rdmsr" : "=a"(lo), "=d"(hi) : "c"(msr)); return ((u64)hi << 32) | lo; }

/* What does the LAPIC look like, and does the CPU take interrupts at all? The kernel's LAPIC base lives in a kernel variable whose
 * distance from this routine is known at build time (KTTY_LAPIC_DELTA); registers are read the way the kernel does it (base + reg). */
static inline u8 inb(u16 p) { u8 v; __asm__ volatile("inb %1, %0" : "=a"(v) : "Nd"(p)); return v; }
static inline void outb(u16 p, u8 v) { __asm__ volatile("outb %0, %1" :: "a"(v), "Nd"(p)); }
static inline void wrmsr64(u32 msr, u64 v) { __asm__ volatile("wrmsr" :: "c"(msr), "a"((u32)v), "d"((u32)(v >> 32))); }

static void dump_lapic(const char *tag)
{
    volatile u32 *l = lapic_base();
    kputs(tag); kputs(": tpr "); khex(l[0x80 / 4], 2); kputs(" lint0 "); khex(l[0x350 / 4], 8);
    kputs(" isr6/7 "); khex(l[0x160 / 4], 8); kch(' '); khex(l[0x170 / 4], 8);
    kputs(" irr6/7 "); khex(l[0x260 / 4], 8); kch(' '); khex(l[0x270 / 4], 8); kch('\n');
}

static void window(const char *tag)
{
    volatile u32 *l = lapic_base();
    kputs(tag); kputs(" 410 "); khex(l[0x410 / 4], 2); kputs(" ier "); for (int i = 7; i >= 0; i--) { khex(l[(0x480 + 16 * i) / 4], 8); kch(' '); }
    kch('\n');
    __asm__ volatile("sti");
    for (volatile u64 i = 0; i < 100000000ull; i++) { }
    __asm__ volatile("cli");
    dump_lapic(" ->");
}

/* Fired on the multi-CPU panic text ("NMIPI for unresponsive"): what the APIC IER looked like on every CPU when it started, before and after
 * the fix in tools/make_ierfix.py (each CPU leaves two pixels per row in VRAM, bottom right: x=2000.., y=1430 before, y=1431 after).
 * Pixel 0 = 0xA5000000 | LAPIC id << 8 | IERE, pixel 1 = IER6. A missing record ("--") means that CPU never ran the hook. */
static void lapic_probe(void)
{
    kputs("\nIER per LAPIC id  (before: IERE IER6 | after: IERE IER6)\n");
    for (u32 id = 0; id < 16; id++) {
        u32 v[4];
        for (u32 r = 0; r < 2; r++)
            for (u32 k = 0; k < 2; k++) {
                out32(0x2000, (KTTY_FB_OFF + (1430u + r) * PITCH + 2000u * 4 + id * 8 + k * 4) | 0x80000000u);
                v[r * 2 + k] = in32(0x2004);
            }
        kputs(" id "); khex(id, 2);
        if ((v[0] >> 24) != 0xA5 || ((v[0] >> 8) & 0xFF) != id) { kputs(" --\n"); continue; }
        kputs("  before "); khex(v[0] & 1, 1); kch(' '); khex(v[1], 8);
        kputs("  after "); khex(v[2] & 1, 1); kch(' '); khex(v[3], 8); kch('\n');
    }
}
#endif

__attribute__((section(".text.entry"), used))
void ktty_main(u8 c)
{
    const u32 state_off = KTTY_FB_OFF + 1439u * PITCH;
    /* The LAPIC reaches the kernel with AMD's interrupt-enable registers on (IERE, 0x410 bit 0) and only vectors 0xC0-0xC4 allowed in
     * IER6: the timer vector 0xDD and every IPI sat in IRR forever and the boot stalled waiting for the root device. The IER
     * registers only accept writes while IERE is set (Linux finds IERE off and every IER bit on): open all vectors as soon as the
     * kernel has mapped the LAPIC. */
    volatile u32 *lap = lapic_base();
    if ((u64)lap >= 0xffffff0000000000ull && (lap[0x410 / 4] & 1) && lap[0x4E0 / 4] != 0xFFFFFFFFu)
        for (int i = 0; i < 8; i++) lap[(0x480 + 16 * i) / 4] = 0xFFFFFFFFu;
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
