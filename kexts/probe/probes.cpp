// Throw-away kexts that tell which part of PS5SalinaGbE OpenCore refuses to inject (see tools/build_probes.sh).
// PROBE_A: plain IOService. PROBE_B: also uses symbols of IOPCIFamily/IONetworkingFamily. PROBE_C: derives from IOEthernetController.
#include <IOKit/IOLib.h>
#include <IOKit/IOService.h>
#include <IOKit/pci/IOPCIDevice.h>
#include <IOKit/network/IOEthernetController.h>
#include <IOKit/network/IONetworkMedium.h>
#include <IOKit/network/IOBasicOutputQueue.h>

#define super IOService
class PROBE_NAME : public IOService {
    OSDeclareDefaultStructors(PROBE_NAME)
public:
    bool start(IOService *p) APPLE_KEXT_OVERRIDE
    {
        if (!super::start(p)) return false;
#if defined(PROBE_B)
        IOLog(STR(PROBE_NAME) ": loaded (pci cast %p, medium %p)\n", OSDynamicCast(IOPCIDevice, p), IONetworkMedium::medium(kIOMediumEthernetAuto, 1000000000ULL));
#else
        IOLog(STR(PROBE_NAME) ": loaded\n");
#endif
        registerService();
        return true;
    }
};
OSDefineMetaClassAndStructors(PROBE_NAME, IOService)

#if defined(PROBE_C)
class PROBE_ETH : public IOEthernetController {
    OSDeclareDefaultStructors(PROBE_ETH)
public:
    bool init(OSDictionary *d) APPLE_KEXT_OVERRIDE { IOLog(STR(PROBE_NAME) ": ethernet class init\n"); return IOEthernetController::init(d); }
    IOReturn getHardwareAddress(IOEthernetAddress *a) APPLE_KEXT_OVERRIDE { bzero(a, sizeof(*a)); return kIOReturnSuccess; }
    UInt32 outputPacket(mbuf_t m, void *) APPLE_KEXT_OVERRIDE { freePacket(m); return kIOReturnOutputDropped; }
};
#undef super
#define super IOEthernetController
OSDefineMetaClassAndStructors(PROBE_ETH, IOEthernetController)
#endif
