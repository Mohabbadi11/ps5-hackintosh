/** @file
  PS5 reset: load an empty IDT and take a breakpoint exception, which triple-faults the CPU.
**/

#include <Base.h>
#include <Library/BaseLib.h>
#include <Library/DebugLib.h>
#include <Library/ResetSystemLib.h>

STATIC
VOID
TripleFault (
  VOID
  )
{
  IA32_DESCRIPTOR  Idtr;

  DEBUG ((DEBUG_INFO, "Ps5ResetSystemLib: triple fault reset\n"));
  Idtr.Base  = 0;
  Idtr.Limit = 0;
  AsmWriteIdtr (&Idtr);
  CpuBreakpoint ();
  CpuDeadLoop ();
}

VOID
EFIAPI
ResetCold (
  VOID
  )
{
  TripleFault ();
}

VOID
EFIAPI
ResetWarm (
  VOID
  )
{
  TripleFault ();
}

VOID
EFIAPI
ResetShutdown (
  VOID
  )
{
  TripleFault ();
}

VOID
EFIAPI
ResetPlatformSpecific (
  IN UINTN       DataSize,
  IN VOID        *ResetData
  )
{
  TripleFault ();
}

VOID
EFIAPI
ResetSystem (
  IN EFI_RESET_TYPE  ResetType,
  IN EFI_STATUS      ResetStatus,
  IN UINTN           DataSize,
  IN VOID            *ResetData OPTIONAL
  )
{
  TripleFault ();
}
