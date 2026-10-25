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
ClearRow (
  UINT32  Row
  )
{
  //
  // The screen is a ring of text rows: when the bottom is reached output restarts at the top, wiping one row at a
  // time, so the most recent lines (and the ones just before them) always stay readable.
  //
  UINT32  Y;
  UINT32  X;
  UINT32  *P;

  for (Y = Row * 16; Y < Row * 16 + 16; Y++) {
    P = (UINT32 *)(UINTN)(FbBase () + (UINT64)Y * FB_PITCH);
    for (X = 0; X < FB_W; X++) {
      P[X] = 0xFF101040U;
    }

    for (X = 0; X < FB_W * 4; X += 64) {
      AsmFlushCacheLine ((VOID *)((UINTN)P + X));
    }
  }
}

RETURN_STATUS
EFIAPI
SerialPortInitialize (
  VOID
  )
{
  return RETURN_SUCCESS;
}

STATIC
VOID
DrawStatus (
  CONSOLE_STATE  *S
  )
{
  //
  // Heartbeat in the top-right corner: number of SerialPortWrite calls, cursor row/col and the TSC in ~seconds.
  // If this stops changing the CPU is no longer printing; if it keeps changing the log is just not moving.
  //
  STATIC UINT32  Calls = 0;
  UINT32         Col   = COLS - 34;
  UINT32         I;
  UINT64         Secs  = DivU64x32 (AsmReadTsc (), 1596300000U);
  CHAR8          Line[40];
  STATIC CONST CHAR8  Hex[] = "0123456789abcdef";

  Calls++;
  Line[0] = 'N'; Line[1] = '=';
  for (I = 0; I < 6; I++) {
    Line[2 + I] = Hex[(Calls >> ((5 - I) * 4)) & 0xF];
  }

  Line[8] = ' '; Line[9] = 'R'; Line[10] = '=';
  Line[11] = Hex[(S->Row >> 4) & 0xF]; Line[12] = Hex[S->Row & 0xF];
  Line[13] = ' '; Line[14] = 'T'; Line[15] = '=';
  for (I = 0; I < 6; I++) {
    Line[16 + I] = Hex[(Secs >> ((5 - I) * 4)) & 0xF];
  }

  for (I = 0; I < 22; I++) {
    DrawGlyph (Col + I, 0, (UINT8)Line[I]);
  }
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
      S->Row = (S->Row + 1) % ROWS;
      ClearRow (S->Row);
      continue;
    }

    if (S->Col >= COLS) {
      S->Col = 0;
      S->Row = (S->Row + 1) % ROWS;
      ClearRow (S->Row);
    }

    DrawGlyph (S->Col, S->Row, Ch);
    S->Col++;
  }

  DrawStatus (S);
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
