/** @file
  SerialPortLib backed by the PS5 scanout framebuffer.

  The VRAM carve-out is ordinary system RAM (physical 0x450000000 + VRAM offset). Stage 1 (bringup/) leaves a linear
  2560x1440 XR24 buffer at VRAM offset 0x1a000000 (physical 0x46a000000, pitch 10240). Everything written here is also
  copied to a log page that Linux can read back over SSH after the console returns.
**/

#include <Base.h>
#include <Library/BaseLib.h>
#include <Library/SerialPortLib.h>
#include "font8x16.h"

#define FB_DEFAULT 0x46a000000ULL
#define FB_PTR     0x300001f10ULL       // stage 1 stores the framebuffer address it found here
#define FB_PITCH   10240U
#define FB_W       2560U
#define FB_H       1440U
#define LOG_BASE   0x300002000ULL      // stage 1 uses 0x300000000..0x300001fff
#define LOG_SIZE   0x40000U

#define COLS       (FB_W / 8)
#define ROWS       (FB_H / 16)

//
// Console state lives at a fixed physical page so every module (entry, DXE core, drivers) shares one cursor.
//
#define STATE_BASE 0x300001f00ULL
typedef struct {
  UINT32  Magic;
  UINT32  Col;
  UINT32  Row;
  UINT32  LogLen;
} CONSOLE_STATE;

#define STATE_MAGIC 0x50354643U      // "P5FC"

STATIC CONSOLE_STATE *
State (
  VOID
  )
{
  CONSOLE_STATE  *S = (CONSOLE_STATE *)(UINTN)STATE_BASE;

  if (S->Magic != STATE_MAGIC) {
    S->Magic  = STATE_MAGIC;
    S->Col    = 0;
    S->Row    = 0;
    S->LogLen = 0;
  }

  return S;
}

STATIC
UINT64
FbBase (
  VOID
  )
{
  UINT64  V = *(volatile UINT64 *)(UINTN)FB_PTR;

  return (V != 0) ? V : FB_DEFAULT;
}

STATIC
VOID
DrawGlyph (
  UINT32  Col,
  UINT32  Row,
  UINT8   Ch
  )
{
  UINT32  Line;
  UINT32  Bit;
  UINT32  *P;

  for (Line = 0; Line < 16; Line++) {
    UINT8  Bits = font8x16[Ch][Line];
    P = (UINT32 *)(UINTN)(FbBase () + (UINT64)(Row * 16 + Line) * FB_PITCH + (UINT64)Col * 32);
    for (Bit = 0; Bit < 8; Bit++) {
      P[Bit] = (Bits & (0x80 >> Bit)) ? 0xFFFFFFFFU : 0xFF101040U;
    }
  }

  //
  // The scanout engine reads DRAM, not the CPU caches: push the 16 glyph lines (32 bytes each) out.
  //
  for (Line = 0; Line < 16; Line++) {
    AsmFlushCacheLine ((VOID *)(UINTN)(FbBase () + (UINT64)(Row * 16 + Line) * FB_PITCH + (UINT64)Col * 32));
  }
}

STATIC
VOID
Scroll (
  VOID
  )
{
  //
  // Out of rows: wipe the screen and start over at the top (cheap, keeps the newest output visible).
  //
  UINT32  Y;
  UINT32  X;
  UINT32  *P;

  for (Y = 0; Y < FB_H; Y++) {
    P = (UINT32 *)(UINTN)(FbBase () + (UINT64)Y * FB_PITCH);
    for (X = 0; X < FB_W; X++) {
      P[X] = 0xFF101040U;
    }
  }

  AsmWbinvd ();
}

RETURN_STATUS
EFIAPI
SerialPortInitialize (
  VOID
  )
{
  return RETURN_SUCCESS;
}

UINTN
EFIAPI
SerialPortWrite (
  IN UINT8  *Buffer,
  IN UINTN  NumberOfBytes
  )
{
  CONSOLE_STATE  *S;
  UINTN          I;
  UINT8          Ch;
  UINT8          *Log;

  S   = State ();
  Log = (UINT8 *)(UINTN)LOG_BASE;

  for (I = 0; I < NumberOfBytes; I++) {
    Ch = Buffer[I];
    if (S->LogLen < LOG_SIZE) {
      Log[S->LogLen++] = Ch;
    }

    if (Ch == '\r') {
      S->Col = 0;
      continue;
    }

    if (Ch == '\n') {
      S->Col = 0;
      S->Row++;
    } else {
      if (S->Col >= COLS) {
        S->Col = 0;
        S->Row++;
      }

      if (S->Row >= ROWS) {
        Scroll ();
        S->Row = 0;
      }

      DrawGlyph (S->Col, S->Row, Ch);
      S->Col++;
    }

    if (S->Row >= ROWS) {
      Scroll ();
      S->Row = 0;
    }
  }

  return NumberOfBytes;
}

UINTN
EFIAPI
SerialPortRead (
  OUT UINT8  *Buffer,
  IN  UINTN  NumberOfBytes
  )
{
  return 0;
}

BOOLEAN
EFIAPI
SerialPortPoll (
  VOID
  )
{
  return FALSE;
}

RETURN_STATUS
EFIAPI
SerialPortSetControl (
  IN UINT32  Control
  )
{
  return RETURN_UNSUPPORTED;
}

RETURN_STATUS
EFIAPI
SerialPortGetControl (
  OUT UINT32  *Control
  )
{
  return RETURN_UNSUPPORTED;
}

RETURN_STATUS
EFIAPI
SerialPortSetAttributes (
  IN OUT UINT64              *BaudRate,
  IN OUT UINT32              *ReceiveFifoDepth,
  IN OUT UINT32              *Timeout,
  IN OUT EFI_PARITY_TYPE     *Parity,
  IN OUT UINT8               *DataBits,
  IN OUT EFI_STOP_BITS_TYPE  *StopBits
  )
{
  return RETURN_UNSUPPORTED;
}
