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

#define KTTY_FB_OFF 0xDEADF00Du            /* placeholder: VRAM offset of pixel (0,0), rewritten by patch_tripwire.py */
#define PITCH       10240u
#define COLS        320u
#define ROWS        89u
#define FG          0xFFE0E0E0u
#define BG          0xFF000000u

static inline void out32(u16 port, u32 v) { __asm__ volatile("outl %0, %1" :: "a"(v), "Nd"(port)); }
static inline u32 in32(u16 port) { u32 v; __asm__ volatile("inl %1, %0" : "=a"(v) : "Nd"(port)); return v; }
static inline void px(u32 off, u32 colour) { out32(0x2000, off | 0x80000000u); out32(0x2004, colour); }

static void clear_rows(u32 first_line, u32 lines, u32 width_px)
{
    for (u32 y = first_line; y < first_line + lines; y++)
        for (u32 x = 0; x < width_px; x++)
            px(KTTY_FB_OFF + y * PITCH + x * 4, BG);
}

__attribute__((section(".text.entry"), used))
void ktty_main(u8 c)
{
    const u32 state_off = KTTY_FB_OFF + 1439u * PITCH;
    out32(0x2000, state_off | 0x80000000u);
    u32 st = in32(0x2004);
    if ((st >> 24) != 0x5A) {
        clear_rows(0, 1439, 2560);
        st = 0x5A000000u;
    }
    u32 col = st & 0x1FF, row = (st >> 9) & 0x7F, wrapped = (st >> 16) & 1;
    int newline = 0;

    if (c == '\n') {
        newline = 1;
    } else if (c == '\r') {
        col = 0;
    } else if (c == '\t') {
        col = (col + 8) & ~7u;
        if (col >= COLS) newline = 1;
    } else if (c >= 32 && c < 127) {
        const u8 *g = ktty_font[c - 32];
        for (u32 y = 0; y < 16; y++) {
            u8 bits = g[y];
            u32 base = KTTY_FB_OFF + (row * 16 + y) * PITCH + col * 32;
            for (u32 x = 0; x < 8; x++)
                px(base + x * 4, (bits & (0x80 >> x)) ? FG : BG);
        }
        if (++col >= COLS) newline = 1;
    }
    if (newline) {
        col = 0;
        if (++row >= ROWS) { row = 0; wrapped = 1; }
        if (wrapped) clear_rows(row * 16, 16, 1024);
    }
    out32(0x2000, state_off | 0x80000000u);
    out32(0x2004, 0x5A000000u | (wrapped << 16) | (row << 9) | col);
}
