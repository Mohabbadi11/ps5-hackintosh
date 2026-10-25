/* EbsTest: what happens to this UEFI payload when an OS loader calls ExitBootServices and SetVirtualAddressMap?
 * Draws one coloured square per milestone straight into the GOP framebuffer (usable after ExitBootServices), then an
 * animated "alive" square. Run it from the OpenCore picker (OC/Tools/EbsTest.efi). Squares, left to right:
 *   white  app started          yellow pre-ExitBootServices         green ExitBootServices returned
 *   cyan   SetVirtualAddressMap returned        magenta GetTime ok (red = error)        blue  loop reached
 */
#include <Uefi.h>
#include <Protocol/GraphicsOutput.h>

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

    for (UINT32 n = 0;; n++) {
        for (volatile UINT32 i = 0; i < 20000000; i++) { }
        Square(6, (n & 1) ? 0xFFFFFFFF : 0xFF404040);
    }
}
