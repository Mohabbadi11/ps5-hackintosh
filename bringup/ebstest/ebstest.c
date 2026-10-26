/* EbsTest: what happens to this UEFI payload when an OS loader calls ExitBootServices and SetVirtualAddressMap?
 * Draws one coloured square per milestone straight into the GOP framebuffer (usable after ExitBootServices), then an
 * animated "alive" square. Run it from the OpenCore picker (OC/Tools/EbsTest.efi). Squares, left to right:
 *   white  app started          yellow pre-ExitBootServices         green ExitBootServices returned
 *   cyan   SetVirtualAddressMap returned        magenta GetTime ok (red = error)        blue  loop reached, then 16 blinks, an orange square and the tripwire's red square at the bottom right
 */
#include <Uefi.h>
#include <Protocol/GraphicsOutput.h>
#include "ktty_blob.h"

static volatile UINT32 *Fb;
static UINTN Pitch;

static void Square(UINTN idx, UINT32 colour)
{
    for (UINTN y = 0; y < 64; y++)
        for (UINTN x = 0; x < 64; x++)
            Fb[(y + 20) * Pitch + idx * 80 + x + 20] = colour;
}

EFI_STATUS EFIAPI EfiMain(EFI_HANDLE Image, EFI_SYSTEM_TABLE *St)
{
    EFI_GUID GopGuid = EFI_GRAPHICS_OUTPUT_PROTOCOL_GUID;
    EFI_GRAPHICS_OUTPUT_PROTOCOL *Gop;
    if (St->BootServices->LocateProtocol(&GopGuid, NULL, (VOID **)&Gop) != EFI_SUCCESS)
        return EFI_NOT_FOUND;
    Fb = (volatile UINT32 *)(UINTN)Gop->Mode->FrameBufferBase;
    Pitch = Gop->Mode->Info->PixelsPerScanLine;
    for (UINTN y = 0; y < 110; y++)
        for (UINTN x = 0; x < 700; x++)
            Fb[y * Pitch + x] = 0xFF000000;
    Square(0, 0xFFFFFFFF);

    UINTN MapSize = 0, MapKey, DescSize;
    UINT32 DescVer;
    EFI_MEMORY_DESCRIPTOR *Map;
    St->BootServices->GetMemoryMap(&MapSize, NULL, &MapKey, &DescSize, &DescVer);
    MapSize += 8 * DescSize;
    UINTN Alloc = MapSize;
    if (St->BootServices->AllocatePool(EfiLoaderData, Alloc, (VOID **)&Map) != EFI_SUCCESS)
        return EFI_OUT_OF_RESOURCES;

    Square(1, 0xFFFFFF00);
    EFI_STATUS Status = EFI_SUCCESS;
    for (int attempt = 0; attempt < 4; attempt++) {
        MapSize = Alloc;
        Status = St->BootServices->GetMemoryMap(&MapSize, Map, &MapKey, &DescSize, &DescVer);
        if (Status != EFI_SUCCESS) break;
        Status = St->BootServices->ExitBootServices(Image, MapKey);
        if (Status == EFI_SUCCESS) break;
    }
    if (Status != EFI_SUCCESS) {
        Square(2, 0xFFFF0000);
        for (;;) __asm__ volatile("pause");
    }
    Square(2, 0xFF00FF00);

    for (UINT8 *p = (UINT8 *)Map; p < (UINT8 *)Map + MapSize; p += DescSize) {
        EFI_MEMORY_DESCRIPTOR *d = (EFI_MEMORY_DESCRIPTOR *)p;
        d->VirtualStart = d->PhysicalStart;
    }
    Status = St->RuntimeServices->SetVirtualAddressMap(MapSize, DescSize, DescVer, Map);
    Square(3, Status == EFI_SUCCESS ? 0xFF00FFFF : 0xFFFF0000);

    EFI_TIME Time;
    Status = St->RuntimeServices->GetTime(&Time, NULL);
    Square(4, Status == EFI_SUCCESS ? 0xFFFF00FF : 0xFFFF0000);
    Square(5, 0xFF0000FF);

    for (UINT32 n = 0; n < 16; n++) {
        for (volatile UINT32 i = 0; i < 20000000; i++) { }
        Square(6, (n & 1) ? 0xFFFFFFFF : 0xFF404040);
    }
    /* 1. time the I/O-port painting of a 64x32 square (IO port 0x2000 = MM_INDEX, 0x2004 = MM_DATA) and show the elapsed
     *    TSC as a bar below the squares, 1 pixel per 4 ms; 2. run a copy of the tripwire code with this boot's framebuffer
     *    offset patched in (it paints a red square and never returns). */
    Square(7, 0xFFFF8000);
    UINT32 Off = (UINT32)((UINTN)Fb - 0x450000000ULL);
    UINT64 T0, T1;
    __asm__ volatile("rdtsc; shlq $32, %%rdx; orq %%rdx, %%rax" : "=a"(T0) :: "rdx");
    for (UINTN y = 0; y < 32; y++)
        for (UINTN x = 0; x < 64; x++) {
            UINT32 Idx = (Off + (UINT32)(1100 + y) * 10240 + (UINT32)(1640 + x) * 4) | 0x80000000U;
            __asm__ volatile("outl %0, %w1" :: "a"(Idx), "Nd"((UINT16)0x2000));
            __asm__ volatile("outl %0, %w1" :: "a"((UINT32)0xFF00FF00), "Nd"((UINT16)0x2004));
        }
    __asm__ volatile("rdtsc; shlq $32, %%rdx; orq %%rdx, %%rax" : "=a"(T1) :: "rdx");
    UINT64 Ms4 = (T1 - T0) / (1596300ULL * 4);
    for (UINTN y = 90; y < 100; y++)
        for (UINTN x = 0; x < Ms4 && x < 700; x++)
            Fb[y * Pitch + x] = 0xFFFFFFFF;
    /* 3. run the kernel text console (bringup/ktty) on a test text: 130 numbered lines, so the screen wraps once */
    static UINT8 Blob[sizeof(ktty_blob)] __attribute__((aligned(16)));
    for (UINTN i = 0; i < sizeof(ktty_blob); i++) Blob[i] = ktty_blob[i];
    for (UINTN i = 0; i + 4 <= sizeof(Blob); i++)
        if (*(UINT32 *)(Blob + i) == 0xDEADF00DU) *(UINT32 *)(Blob + i) = Off;
    __attribute__((sysv_abi)) void (*Putc)(UINT8) = (__attribute__((sysv_abi)) void (*)(UINT8))(Blob + 0x80);   /* System V ABI: first argument in rdi */
    for (UINT32 n = 0; n < 130; n++) {
        char Line[64] = "ktty test line 000 - the quick brown fox 0123456789 {}[]()<>\n";
        Line[15] = '0' + (n / 100) % 10; Line[16] = '0' + (n / 10) % 10; Line[17] = '0' + n % 10;
        for (UINTN i = 0; Line[i]; i++) Putc((UINT8)Line[i]);
    }
    for (;;) { }
}
