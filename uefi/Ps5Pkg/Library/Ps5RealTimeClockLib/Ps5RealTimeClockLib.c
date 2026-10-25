/** @file
  Software real time clock for the PS5: epoch + (TSC - TSC at epoch) / 1596.3 MHz.
**/

#include <Base.h>
#include <Uefi.h>
#include <Library/BaseLib.h>
#include <Library/RealTimeClockLib.h>
#include <Library/TimeBaseLib.h>

#define PS5_TSC_HZ        1596300000ULL
#define DEFAULT_EPOCH     1792929600ULL     // 2026-10-25 12:00:00 UTC

STATIC UINT64   mBaseEpoch = DEFAULT_EPOCH;
STATIC UINT64   mBaseTsc   = 0;
STATIC BOOLEAN  mHaveBase  = FALSE;

STATIC
UINT64
NowEpoch (
  VOID
  )
{
  UINT64  Tsc = AsmReadTsc ();

  if (!mHaveBase) {
    mBaseTsc  = Tsc;
    mHaveBase = TRUE;
  }

  return mBaseEpoch + DivU64x32 (Tsc - mBaseTsc, (UINT32)PS5_TSC_HZ);
}

EFI_STATUS
EFIAPI
LibGetTime (
  OUT EFI_TIME                *Time,
  OUT  EFI_TIME_CAPABILITIES  *Capabilities
  )
{
  if (Time == NULL) {
    return EFI_INVALID_PARAMETER;
  }

  EpochToEfiTime ((UINTN)NowEpoch (), Time);
  Time->TimeZone = EFI_UNSPECIFIED_TIMEZONE;
  Time->Daylight = 0;

  if (Capabilities != NULL) {
    Capabilities->Resolution = 1;
    Capabilities->Accuracy   = 50000000;
    Capabilities->SetsToZero = FALSE;
  }

  return EFI_SUCCESS;
}

EFI_STATUS
EFIAPI
LibSetTime (
  IN EFI_TIME  *Time
  )
{
  if (Time == NULL) {
    return EFI_INVALID_PARAMETER;
  }

  mBaseEpoch = EfiTimeToEpoch (Time);
  mBaseTsc   = AsmReadTsc ();
  mHaveBase  = TRUE;
  return EFI_SUCCESS;
}

EFI_STATUS
EFIAPI
LibGetWakeupTime (
  OUT BOOLEAN   *Enabled,
  OUT BOOLEAN   *Pending,
  OUT EFI_TIME  *Time
  )
{
  return EFI_UNSUPPORTED;
}

EFI_STATUS
EFIAPI
LibSetWakeupTime (
  IN BOOLEAN    Enabled,
  OUT EFI_TIME  *Time
  )
{
  return EFI_UNSUPPORTED;
}

EFI_STATUS
EFIAPI
LibRtcInitialize (
  IN EFI_HANDLE        ImageHandle,
  IN EFI_SYSTEM_TABLE  *SystemTable
  )
{
  (VOID)NowEpoch ();
  return EFI_SUCCESS;
}
