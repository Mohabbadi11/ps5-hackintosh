/** @file
  Draws "HB=<ticks> T=<seconds>" on row 2 of the PS5 framebuffer every 500 ms from a UEFI timer event.
**/

#include <Uefi.h>
#include <Library/BaseLib.h>
#include <Library/DebugLib.h>
#include <Library/UefiBootServicesTableLib.h>
#include <Library/IoLib.h>
#include <Guid/EventGroup.h>
#include "font8x16.h"

#define FB_DEFAULT  0x46a000000ULL
#define FB_PTR      0x300001f10ULL
#define QUIET_PTR   0x300001f18ULL
#define CARVE_PTR   0x300001f20ULL    // physical base of the VRAM carve-out, written by stage 1 (0 = the 512 MB default)
#define FB_PITCH    10240U
#define COLS        320U
#define STATUS_ROW  2U
#define PS5_TSC_HZ  1596300000U

STATIC UINT32  mTicks;

STATIC
UINT64
CarveBase (
  VOID
  )
{
  UINT64  Base = *(volatile UINT64 *)(UINTN)CARVE_PTR;

  return (Base != 0) ? Base : 0x450000000ULL;
}

//
// Milestone squares for debugging what an OS loader's ExitBootServices does: painted through the GPU's MM_INDEX/MM_DATA
// window (BAR5 at 0xE0600000), so they work whatever page tables are active. Square N sits at row 1100, pixel 1000 + 160 N.
//
STATIC
VOID
Milestone (
  UINT32  Index,
  UINT32  Colour
  )
{
  UINT32  Offset;
  UINT32  Row;
  UINT32  Pixel;
  UINT64  Fb = *(volatile UINT64 *)(UINTN)FB_PTR;

  if (Fb == 0) {
    Fb = FB_DEFAULT;
  }

  MmioWrite32 (0xE0600000ULL + 0x18, 0);
  Offset = (UINT32)(Fb - CarveBase ()) + 1100 * FB_PITCH + (1000 + 160 * Index) * 4;
  for (Row = 0; Row < 64; Row++) {
    for (Pixel = 0; Pixel < 128; Pixel++) {
      MmioWrite32 (0xE0600000ULL, (Offset + Row * FB_PITCH + Pixel * 4) | 0x80000000U);
      MmioWrite32 (0xE0600004ULL, Colour);
    }
  }
}

//
// The same square through the GPU's I/O-port BAR (0x2000), the only path that works in kernel code with unknown page tables.
//
STATIC
VOID
MilestoneIo (
  UINT32  Index,
  UINT32  Colour
  )
{
  UINT32  Offset;
  UINT32  Row;
  UINT32  Pixel;
  UINT64  Fb = *(volatile UINT64 *)(UINTN)FB_PTR;

  if (Fb == 0) {
    Fb = FB_DEFAULT;
  }

  Offset = (UINT32)(Fb - CarveBase ()) + 1100 * FB_PITCH + (1000 + 160 * Index) * 4;
  for (Row = 0; Row < 64; Row++) {
    for (Pixel = 0; Pixel < 128; Pixel++) {
      IoWrite32 (0x2000, (Offset + Row * FB_PITCH + Pixel * 4) | 0x80000000U);
      IoWrite32 (0x2004, Colour);
    }
  }
}

STATIC
VOID
EFIAPI
OnBeforeExitBs (
  IN EFI_EVENT  Event,
  IN VOID       *Context
  )
{
  Milestone (0, 0xFFFFFF00U);          // yellow: BeforeExitBootServices signalled
}

STATIC
VOID
EFIAPI
OnExitBs (
  IN EFI_EVENT  Event,
  IN VOID       *Context
  )
{
  Milestone (1, 0xFF00FF00U);          // green: ExitBootServices signalled
  MilestoneIo (2, 0xFF0000FFU);        // blue: the same through the I/O-port BAR
}

STATIC
VOID
Glyph (
  UINT64  Fb,
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
    P = (UINT32 *)(UINTN)(Fb + (UINT64)(Row * 16 + Line) * FB_PITCH + (UINT64)Col * 32);
    for (Bit = 0; Bit < 8; Bit++) {
      P[Bit] = (Bits & (0x80 >> Bit)) ? 0xFF00FF00U : 0xFF101040U;      // green so it stands out from the log
    }

    AsmFlushCacheLine (P);
  }
}

STATIC
VOID
EFIAPI
OnTimer (
  IN EFI_EVENT  Event,
  IN VOID       *Context
  )
{
  STATIC CONST CHAR8  Hex[] = "0123456789abcdef";
  UINT64              Fb    = *(volatile UINT64 *)(UINTN)FB_PTR;
  UINT64              Secs  = DivU64x32 (AsmReadTsc (), PS5_TSC_HZ);
  CHAR8               Line[24];
  UINT32              I;

  if (Fb == 0) {
    Fb = FB_DEFAULT;
  }

  mTicks++;
  if (*(volatile UINT32 *)(UINTN)QUIET_PTR != 0) {
    return;
  }
  Line[0] = 'H'; Line[1] = 'B'; Line[2] = '=';
  for (I = 0; I < 6; I++) {
    Line[3 + I] = Hex[(mTicks >> ((5 - I) * 4)) & 0xF];
  }

  Line[9] = ' '; Line[10] = 'T'; Line[11] = '=';
  for (I = 0; I < 6; I++) {
    Line[12 + I] = Hex[(Secs >> ((5 - I) * 4)) & 0xF];
  }

  for (I = 0; I < 18; I++) {
    Glyph (Fb, COLS - 34 + I, STATUS_ROW, (UINT8)Line[I]);
  }
}

EFI_STATUS
EFIAPI
HeartbeatEntry (
  IN EFI_HANDLE        ImageHandle,
  IN EFI_SYSTEM_TABLE  *SystemTable
  )
{
  EFI_EVENT   Event;
  EFI_STATUS  Status;

  Status = gBS->CreateEvent (EVT_TIMER | EVT_NOTIFY_SIGNAL, TPL_CALLBACK, OnTimer, NULL, &Event);
  if (!EFI_ERROR (Status)) {
    Status = gBS->SetTimer (Event, TimerPeriodic, 5000000);      // 500 ms
  }

  gBS->CreateEventEx (EVT_NOTIFY_SIGNAL, TPL_CALLBACK, OnBeforeExitBs, NULL, &gEfiEventBeforeExitBootServicesGuid, &Event);
  gBS->CreateEventEx (EVT_NOTIFY_SIGNAL, TPL_CALLBACK, OnExitBs, NULL, &gEfiEventExitBootServicesGuid, &Event);
  DEBUG ((DEBUG_INFO, "Ps5HeartbeatDxe: timer started: %r\n", Status));
  return EFI_SUCCESS;
}
