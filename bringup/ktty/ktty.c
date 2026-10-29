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

__attribute__((section(".text.entry"), used))
void ktty_main(u8 c)
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
