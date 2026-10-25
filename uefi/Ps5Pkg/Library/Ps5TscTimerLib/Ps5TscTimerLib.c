/** @file
  TSC-based TimerLib with a fixed 1596.3 MHz frequency.
**/

#include <Base.h>
#include <Library/BaseLib.h>
#include <Library/TimerLib.h>

#define PS5_TSC_HZ  1596300000ULL

STATIC
UINT64
TicksFromNs (
  UINT64  Ns
  )
{
  //
  // Ns * 1.5963 without overflowing 64 bits for the delays UEFI uses (seconds): split into whole seconds and rest.
  //
  UINT64  Sec = DivU64x32 (Ns, 1000000000U);
  UINT64  Rem = Ns - MultU64x32 (Sec, 1000000000U);

  return MultU64x64 (Sec, PS5_TSC_HZ) + DivU64x32 (MultU64x64 (Rem, PS5_TSC_HZ), 1000000000U);
}

STATIC
UINTN
Wait (
  UINT64  Ticks
  )
{
  UINT64  Start = AsmReadTsc ();

  while ((AsmReadTsc () - Start) < Ticks) {
    CpuPause ();
  }

  return 0;
}

UINTN
EFIAPI
MicroSecondDelay (
  IN UINTN  MicroSeconds
  )
{
  return Wait (TicksFromNs ((UINT64)MicroSeconds * 1000));
}

UINTN
EFIAPI
NanoSecondDelay (
  IN UINTN  NanoSeconds
  )
{
  return Wait (TicksFromNs (NanoSeconds));
}

UINT64
EFIAPI
GetPerformanceCounter (
  VOID
  )
{
  return AsmReadTsc ();
}

UINT64
EFIAPI
GetPerformanceCounterProperties (
  OUT UINT64  *StartValue   OPTIONAL,
  OUT UINT64  *EndValue     OPTIONAL
  )
{
  if (StartValue != NULL) {
    *StartValue = 0;
  }

  if (EndValue != NULL) {
    *EndValue = MAX_UINT64;
  }

  return PS5_TSC_HZ;
}

UINT64
EFIAPI
GetTimeInNanoSecond (
  IN UINT64  Ticks
  )
{
  UINT64  Sec = DivU64x32 (Ticks, (UINT32)PS5_TSC_HZ);
  UINT64  Rem = Ticks - MultU64x32 (Sec, (UINT32)PS5_TSC_HZ);

  return MultU64x32 (Sec, 1000000000U) + DivU64x32 (MultU64x32 (Rem, 1000000000U), (UINT32)PS5_TSC_HZ);
}
