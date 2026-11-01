// ps5ctl <Key> <number> ...: set run-time tunables of the Salina GbE kext (PollUs, RxBudget). Run as root on the console's macOS.
// Build on the host: clang -arch x86_64 -mmacosx-version-min=12.0 -framework IOKit -framework CoreFoundation tools/ps5ctl.c -o build/ps5ctl
#include <IOKit/IOKitLib.h>
#include <CoreFoundation/CoreFoundation.h>
#include <stdio.h>
#include <stdlib.h>

int main(int argc, char **argv)
{
    if (argc < 3 || argc % 2 == 0) { fprintf(stderr, "usage: %s Key number [Key number ...]\n", argv[0]); return 2; }
    io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("PS5SalinaGbE"));
    if (!svc) { fprintf(stderr, "PS5SalinaGbE is not running\n"); return 1; }
    CFMutableDictionaryRef d = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    for (int i = 1; i + 1 < argc; i += 2) {
        int v = atoi(argv[i + 1]);
        CFStringRef k = CFStringCreateWithCString(NULL, argv[i], kCFStringEncodingUTF8);
        CFNumberRef n = CFNumberCreate(NULL, kCFNumberIntType, &v);
        CFDictionarySetValue(d, k, n);
        CFRelease(k); CFRelease(n);
    }
    kern_return_t kr = IORegistryEntrySetCFProperties(svc, d);
    printf("IORegistryEntrySetCFProperties: 0x%x\n", kr);
    return kr != KERN_SUCCESS;
}
