// SPDX-License-Identifier: MIT
// Read-only probe of the PS5's Cyan Skillfish GPU (PCI 1002:13fc) from macOS: maps the 512 KiB register BAR and publishes a handful of
// status registers as properties, so `ioreg -l -c PS5GpuProbe` shows what state Linux left the GPU in. Writes nothing to the device.
// Register offsets are the Linux amdgpu ones (GC_BASE segment 0 = 0x1260, MMHUB 0x1a000, NBIO segment 2 = 0xd20), in dwords.
#include <IOKit/IOLib.h>
#include <IOKit/pci/IOPCIDevice.h>
#include <IOKit/IOService.h>

class PS5GpuProbe : public IOService {
    OSDeclareDefaultStructors(PS5GpuProbe)
    IOMemoryMap *regs = nullptr;
public:
    bool start(IOService *provider) override;
    void stop(IOService *provider) override;
};

#define super IOService
OSDefineMetaClassAndStructors(PS5GpuProbe, IOService)

#define LOG(fmt, ...) IOLog("PS5GpuProbe: " fmt "\n", ##__VA_ARGS__)

struct Reg { const char *name; uint32_t dword; };
static const Reg probes[] = {
    {"GRBM_STATUS", 0x2004}, {"GRBM_STATUS2", 0x2002}, {"GRBM_STATUS_SE0", 0x2005}, {"GRBM_SOFT_RESET", 0x2008},
    {"CP_STAT", 0x21a0}, {"CP_ME_CNTL", 0x21b6}, {"CP_MEC_CNTL", 0x208d}, {"GB_ADDR_CONFIG", 0x263e},
    {"CC_GC_SHADER_ARRAY_CONFIG", 0x226f}, {"RLC_STAT", 0x5e64}, {"RLC_GPM_STAT", 0x60ce},
    {"SDMA0_STATUS_REG", 0x1285}, {"SDMA1_STATUS_REG", 0x1885},
    {"MMHUB_FB_LOCATION_BASE", 0x1a86c}, {"MMHUB_FB_LOCATION_TOP", 0x1a86d}, {"MMHUB_FB_OFFSET", 0x1a86e},
    {"RCC_CONFIG_MEMSIZE", 0xde3},
};

bool PS5GpuProbe::start(IOService *provider)
{
    if (!super::start(provider)) return false;
    IOPCIDevice *pci = OSDynamicCast(IOPCIDevice, provider);
    if (!pci) return false;
    regs = pci->mapDeviceMemoryWithRegister(kIOPCIConfigBaseAddress5);
    if (!regs) { LOG("BAR5 not mappable"); return false; }
    volatile uint32_t *r = (volatile uint32_t *)regs->getVirtualAddress();
    LOG("BAR5 at phys 0x%llx, length 0x%llx", (unsigned long long)regs->getPhysicalAddress(), (unsigned long long)regs->getLength());
    OSDictionary *d = OSDictionary::withCapacity(32);
    for (const Reg &p : probes) {
        if ((uint64_t)p.dword * 4 + 4 > regs->getLength()) continue;
        uint32_t v = r[p.dword];
        LOG("%s [0x%x] = 0x%08x", p.name, p.dword, v);
        OSNumber *n = OSNumber::withNumber(v, 32);
        d->setObject(p.name, n);
        n->release();
    }
    setProperty("registers", d);
    d->release();
    registerService();
    return true;
}

void PS5GpuProbe::stop(IOService *provider)
{
    if (regs) { regs->release(); regs = nullptr; }
    super::stop(provider);
}
