// SPDX-License-Identifier: GPL-2.0-only
// See PS5SalinaGbE.hpp. PHY sequences and ring handling are a port of the Linux "mts" driver (mts_main.c, mts_phy.c).
#include "PS5SalinaGbE.hpp"

#define super IOEthernetController
OSDefineMetaClassAndStructors(PS5SalinaGbE, IOEthernetController)

#define BARRIER() __asm__ volatile("mfence" ::: "memory")
#define LOG(fmt, ...) IOLog("PS5SalinaGbE: " fmt "\n", ##__VA_ARGS__)

static const uint8_t calLut[64] = {
    0x7f, 0x7f, 0x7f, 0x7f, 0x7f, 0x7f, 0x7f, 0x7f, 0x7f, 0x7f, 0x7f, 0x7f, 0x7f, 0x7f, 0x7f, 0x7f,
    0x7b, 0x7a, 0x75, 0x73, 0x70, 0x67, 0x64, 0x62, 0x57, 0x55, 0x53, 0x51, 0x48, 0x46, 0x44, 0x42,
    0x40, 0x37, 0x35, 0x34, 0x32, 0x31, 0x30, 0x26, 0x24, 0x23, 0x22, 0x21, 0x20, 0x16, 0x15, 0x14,
    0x13, 0x12, 0x11, 0x10, 0x07, 0x06, 0x05, 0x04, 0x03, 0x02, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00,
};

// ---------------------------------------------------------------------------------------------------------------- life cycle

bool PS5SalinaGbE::init(OSDictionary *properties)
{
    if (!super::init(properties)) return false;
    lock = IOSimpleLockAlloc();
    return lock != nullptr;
}

// The PS5's Salina functions sit behind an ARI bus whose config space is a proxy: Linux reads the real registers through a window in the root
// complex (arch/x86/pci/common.c, sfc_read): the requester id at config 0x150 names the real function, and bus 0 dev 0's extended config space
// holds the window (0xd00/0xd10 or 0xd80/0xd90 select, 0xf00/0xf80 read). A BAR written through the normal path only reaches the proxy, so the
// addresses macOS "assigned" (0x066xxxxx) are not where the chip answers.
#define GBE_ECAM_BASE 0xF0000000ULL
uint32_t PS5SalinaGbE::sfcRead(uint16_t rid, uint32_t reg)
{
    if (!ecamMap) return 0xFFFFFFFF;
    volatile uint8_t *e = (volatile uint8_t *)ecamMap->getVirtualAddress();
    uint32_t busno = (rid >> 8) & 0xff, slot = (rid & 0xff) >> 3, func = rid & 7;
    if (busno == 0 || busno == 32) {
        OSWriteLittleInt32((volatile void *)e, 0xd90, 4);
        OSWriteLittleInt32((volatile void *)e, 0xd80, (32u << 24) | (slot << 19) | (func << 16) | (reg & 0xf80));
        return OSReadLittleInt32((volatile void *)e, (reg & 0x7f) | 0xf80);
    }
    if (busno < 32) {
        OSWriteLittleInt32((volatile void *)e, 0xd10, busno == 1 ? 4 : 5);
        OSWriteLittleInt32((volatile void *)e, 0xd00, (busno << 24) | (slot << 19) | (func << 16) | (reg & 0xf80));
        return OSReadLittleInt32((volatile void *)e, (reg & 0x7f) | 0xf00);
    }
    return 0xFFFFFFFF;
}

void PS5SalinaGbE::sfcWrite(uint16_t rid, uint32_t reg, uint32_t val)
{
    if (!ecamMap) return;
    volatile uint8_t *e = (volatile uint8_t *)ecamMap->getVirtualAddress();
    uint32_t busno = (rid >> 8) & 0xff, slot = (rid & 0xff) >> 3, func = rid & 7;
    if (busno == 0 || busno == 32) {
        OSWriteLittleInt32((volatile void *)e, 0xd90, 4);
        OSWriteLittleInt32((volatile void *)e, 0xd80, (32u << 24) | (slot << 19) | (func << 16) | (reg & 0xf80));
        OSWriteLittleInt32((volatile void *)e, (reg & 0x7f) | 0xf80, val);
    } else if (busno < 32) {
        OSWriteLittleInt32((volatile void *)e, 0xd10, busno == 1 ? 4 : 5);
        OSWriteLittleInt32((volatile void *)e, 0xd00, (busno << 24) | (slot << 19) | (func << 16) | (reg & 0xf80));
        OSWriteLittleInt32((volatile void *)e, (reg & 0x7f) | 0xf00, val);
    }
}

// The command register (memory/bus-master enable) of the REAL function: the proxy macOS sees does not forward it as far as we can tell.
void PS5SalinaGbE::setRealCommand(uint16_t bits, bool on)
{
    if (!ecamMap || !nicRid || nicRid == 0xffff) { if (bits & 4) pci->setBusMasterEnable(on); return; }
    uint16_t before = sfcRead(nicRid, 4) & 0xffff, cmd = on ? (before | bits) : (before & ~bits);
    sfcWrite(nicRid, 4, cmd);                      // 32-bit write: the status half goes out as 0 (write-1-to-clear, so nothing is cleared)
    LOG("real command %04x -> %04x (reads back %04x)", before, cmd, sfcRead(nicRid, 4) & 0xffff);
}

// Everything that matters, once, some seconds after bring-up, when the TV log has scrolled past the init lines.
void PS5SalinaGbE::recap()
{
    LOG("RECAP chip %06x rev %04x mac %02x:%02x:%02x:%02x:%02x:%02x nic rid %04x glue rid %04x", chipId, chipRev, mac.bytes[0], mac.bytes[1], mac.bytes[2], mac.bytes[3], mac.bytes[4], mac.bytes[5], nicRid, glueRid);
    LOG("RECAP nic bar0 %llx glue bar4 %llx real cmd %04x proxy cmd %04x tx ring %08x rx ring %08x", (unsigned long long)nicBar0Real, (unsigned long long)glueBar4Real,
        sfcRead(nicRid, 4) & 0xffff, pci->configRead16(kIOPCIConfigCommand), txRingPa, rxRingPa);
    LOG("RECAP regs 04 %08x 08 %08x 0c %08x 10 %08x 30 %08x 34 %08x 38 %08x 3c %08x 40 %08x 44 %08x 48 %08x 50 %08x 54 %08x", rd(4), rd(8), rd(0xc), rd(0x10), rd(0x30), rd(0x34), rd(0x38), rd(0x3c), rd(0x40), rd(0x44), rd(0x48), rd(0x50), rd(0x54));
}

IOMemoryMap *PS5SalinaGbE::mapPhys(uint64_t phys, uint64_t len, IOMemoryDescriptor **mdOut)
{
    IOMemoryDescriptor *md = IOMemoryDescriptor::withPhysicalAddress(phys, len, kIODirectionNone);
    if (!md) return nullptr;
    IOMemoryMap *m = md->createMappingInTask(kernel_task, 0, kIOMapAnywhere | kIOMapInhibitCache);
    if (!m) { md->release(); return nullptr; }
    *mdOut = md;
    return m;
}

IOPCIDevice *PS5SalinaGbE::findGlue()
{
    // the glue (104d:9107) is the sibling function behind the same bridge
    IORegistryEntry *parent = pci->getParentEntry(gIOServicePlane);
    if (!parent) return nullptr;
    IORegistryIterator *it = IORegistryIterator::iterateOver(parent, gIOServicePlane);
    IOPCIDevice *found = nullptr;
    if (it) {
        IORegistryEntry *e;
        while (!found && (e = it->getNextObject())) {
            IOPCIDevice *d = OSDynamicCast(IOPCIDevice, e);
            if (!d) continue;
            if (d->configRead16(kIOPCIConfigVendorID) == 0x104d && d->configRead16(kIOPCIConfigDeviceID) == 0x9107 &&
                d->getBusNumber() == pci->getBusNumber() && d->getDeviceNumber() == pci->getDeviceNumber()) found = d;
        }
        it->release();
    }
    return found;
}

bool PS5SalinaGbE::allocDma(IOBufferMemoryDescriptor **md, size_t size, void **va, uint32_t *pa)
{
    // the chip addresses 32 bits: contiguous memory below 4 GB
    *md = IOBufferMemoryDescriptor::inTaskWithPhysicalMask(kernel_task, kIODirectionInOut | kIOMemoryPhysicallyContiguous, size, 0x00000000FFFFF000ULL);
    if (!*md) return false;
    if ((*md)->prepare() != kIOReturnSuccess) { (*md)->release(); *md = nullptr; return false; }
    *va = (*md)->getBytesNoCopy();
    bzero(*va, size);
    IOByteCount seg = 0;
    uint64_t phys = (*md)->getPhysicalSegment(0, &seg, kIOMemoryMapperNone);
    if (seg < size || phys > 0xFFFFFFFFULL || phys + size > 0x100000000ULL) {
        LOG("DMA buffer of %lu bytes is not one segment below 4 GB (phys %llx, segment %lu)", (unsigned long)size, (unsigned long long)phys, (unsigned long)seg);
        return false;
    }
    *pa = (uint32_t)phys;
    return true;
}

bool PS5SalinaGbE::allocRings()
{
    // Preferred: the reserved pool in Linux's RAM (the first attempt, with buffers from the 0x01000000-0x3fffffff range, got DMA bus errors)
    poolMd = IOMemoryDescriptor::withPhysicalAddress(GBE_DMA_POOL_PA, GBE_DMA_POOL_SIZE, kIODirectionNone);
    poolMap = poolMd ? poolMd->createMappingInTask(kernel_task, 0, kIOMapAnywhere) : nullptr;
    if (poolMap) {
        uint8_t *base = (uint8_t *)poolMap->getVirtualAddress();
        bzero(base, 0x110000);
        txRing = (GbeDesc *)base;                 txRingPa = (uint32_t)GBE_DMA_POOL_PA;
        rxRing = (GbeDesc *)(base + 0x1000);      rxRingPa = (uint32_t)GBE_DMA_POOL_PA + 0x1000;
        txScratch = base + 0x2000;                txScratchPa = (uint32_t)GBE_DMA_POOL_PA + 0x2000;
        rxPool = base + 0xa2000;                  rxPoolPa = (uint32_t)GBE_DMA_POOL_PA + 0xa2000;
        LOG("DMA pool at %08x: tx ring %08x rx ring %08x tx scratch %08x rx pool %08x", (uint32_t)GBE_DMA_POOL_PA, txRingPa, rxRingPa, txScratchPa, rxPoolPa);
        return true;
    }
    LOG("DMA pool mapping failed, falling back to allocated buffers");
    void *va;
    if (!allocDma(&txRingMd, GBE_DESC_RING_BYTES, &va, &txRingPa)) return false;
    txRing = (GbeDesc *)va;
    if (!allocDma(&rxRingMd, GBE_DESC_RING_BYTES, &va, &rxRingPa)) return false;
    rxRing = (GbeDesc *)va;
    if (!allocDma(&txScratchMd, GBE_TX_SCRATCH_SIZE, &va, &txScratchPa)) return false;
    txScratch = (uint8_t *)va;
    if (!allocDma(&rxPoolMd, GBE_RX_POOL_SIZE, &va, &rxPoolPa)) return false;
    rxPool = (uint8_t *)va;
    LOG("DMA: tx ring %08x rx ring %08x tx scratch %08x rx pool %08x", txRingPa, rxRingPa, txScratchPa, rxPoolPa);
    return true;
}

void PS5SalinaGbE::freeRings()
{
    if (poolMap) { poolMap->release(); poolMap = nullptr; }
    if (poolMd) { poolMd->release(); poolMd = nullptr; }
    IOBufferMemoryDescriptor **all[] = { &txRingMd, &rxRingMd, &txScratchMd, &rxPoolMd };
    for (auto p : all) {
        if (*p) { (*p)->complete(); (*p)->release(); *p = nullptr; }
    }
    txRing = rxRing = nullptr;
    txScratch = rxPool = nullptr;
}

void PS5SalinaGbE::dumpRegs()
{
    LOG("regs 00 %08x 04 %08x 08 %08x 0c %08x 10 %08x 14 %08x 18 %08x", rd(0x00), rd(0x04), rd(0x08), rd(0x0c), rd(0x10), rd(0x14), rd(0x18));
    LOG("regs 30 %08x 34 %08x 38 %08x 44 %08x 48 %08x 50 %08x 54 %08x ac %08x", rd(0x30), rd(0x34), rd(0x38), rd(0x44), rd(0x48), rd(0x50), rd(0x54), rd(0xac));
}

// Nothing heavy here: start() runs while IOKit is still looking for the root disk. Only config-space checks; the hardware is touched by
// deferredInit(), a one-shot timer some seconds later.

bool PS5SalinaGbE::start(IOService *provider)
{
    if (!super::start(provider)) return false;
    pci = OSDynamicCast(IOPCIDevice, provider);
    if (!pci) return false;
    uint16_t vid = pci->configRead16(kIOPCIConfigVendorID), did = pci->configRead16(kIOPCIConfigDeviceID);
    LOG("start: %02x:%02x.%x vendor %04x device %04x", pci->getBusNumber(), pci->getDeviceNumber(), pci->getFunctionNumber(), vid, did);
    if (vid != 0x104d || did != 0x9104) { LOG("not the Salina GbE, leaving it alone"); return false; }
    pci->retain();
    if (!pci->open(this)) { LOG("cannot open the PCI device"); return false; }
    LOG("pci command %04x status %04x", pci->configRead16(kIOPCIConfigCommand), pci->configRead16(kIOPCIConfigStatus));
    uint8_t off = 0;
    if (pci->findPCICapability(kIOPCIMSICapability, &off)) {
        uint16_t ctl = pci->configRead16(off + 2);
        LOG("MSI control %04x", ctl);
        if (ctl & 1) pci->configWrite16(off + 2, ctl & ~1);  // polled datapath
    }

    initTimer = IOTimerEventSource::timerEventSource(this, (IOTimerEventSource::Action)&PS5SalinaGbE::initTimerFired);
    timer = IOTimerEventSource::timerEventSource(this, (IOTimerEventSource::Action)&PS5SalinaGbE::pollTimer);
    if (!initTimer || !timer || ownLoop->addEventSource(initTimer) != kIOReturnSuccess || ownLoop->addEventSource(timer) != kIOReturnSuccess) {
        pci->close(this);
        return false;
    }
    // tunables from the personality (Info.plist): InitDelayMs (45000 at boot, a few ms when the kext is loaded at run time), PollUs
    OSNumber *n = OSDynamicCast(OSNumber, getProperty("InitDelayMs"));
    if (n) initDelayMs = n->unsigned32BitValue();
    n = OSDynamicCast(OSNumber, getProperty("PollUs"));
    if (n && n->unsigned32BitValue() >= 50) pollUs = n->unsigned32BitValue();
    initTimer->setTimeoutMS(initDelayMs);
    LOG("started; hardware init in %u ms, poll every %u us", initDelayMs, pollUs);
    return true;
}

void PS5SalinaGbE::initTimerFired(OSObject *owner, IOTimerEventSource *)
{
    PS5SalinaGbE *self = OSDynamicCast(PS5SalinaGbE, owner);
    if (self) self->deferredInit();
}

void PS5SalinaGbE::deferredInit()
{
    LOG("deferred init");
    // 1. what macOS thinks (the proxy) and what the chip really decodes (the sfc window)
    LOG("proxy config: command %04x bar0 %08x %08x bar2 %08x bar4 %08x", pci->configRead16(kIOPCIConfigCommand), pci->configRead32(0x10), pci->configRead32(0x14), pci->configRead32(0x18), pci->configRead32(0x20));
    ecamMap = mapPhys(GBE_ECAM_BASE, 0x1000, &ecamMd);
    nicRid = pci->extendedConfigRead16(0x150);
    LOG("NIC requester id %04x, ECAM map %p", nicRid, ecamMap);
    uint64_t nicBar0 = 0x85000000ULL;                     // what Linux saw (lspci) on this console: the fallback
    uint64_t glueBar4 = 0x85400000ULL;
    if (ecamMap && nicRid && nicRid != 0xffff) {
        uint32_t lo = sfcRead(nicRid, 0x10), hi = sfcRead(nicRid, 0x14), cmd = sfcRead(nicRid, 0x04);
        LOG("NIC real config: command %08x bar0 %08x %08x", cmd, lo, hi);
        if (lo != 0xffffffff && (lo & 0xf) == 0xc) nicBar0 = ((uint64_t)hi << 32) | (lo & ~0xfu);
    }
    glue = nullptr;
    for (int tries = 0; tries < 10 && !glue; tries++) {
        glue = findGlue();
        if (!glue) IOSleep(100);
    }
    if (!glue) { LOG("glue function 104d:9107 not found"); return; }
    glue->retain();
    glueRid = glue->extendedConfigRead16(0x150);
    LOG("glue requester id %04x", glueRid);
    if (ecamMap && glueRid && glueRid != 0xffff) {
        uint32_t lo = sfcRead(glueRid, 0x20), hi = sfcRead(glueRid, 0x24);
        LOG("glue real config: bar0 %08x bar2 %08x bar4 %08x %08x", sfcRead(glueRid, 0x10), sfcRead(glueRid, 0x18), lo, hi);
        if (lo != 0xffffffff && (lo & 0xf) == 0xc) glueBar4 = ((uint64_t)hi << 32) | (lo & ~0xfu);
    }
    nicBar0Real = nicBar0; glueBar4Real = glueBar4;
    LOG("using NIC BAR0 %llx, glue BAR4 %llx", (unsigned long long)nicBar0, (unsigned long long)glueBar4);

    regMap = mapPhys(nicBar0, 0x1000, &regMd);
    if (!regMap) { LOG("BAR0 map failed"); return; }
    regs = (volatile uint8_t *)regMap->getVirtualAddress();
    glueMap = mapPhys(glueBar4, 0x80000, &glueMd);
    if (!glueMap) { LOG("glue BAR4 map failed"); return; }
    glueRegs = (volatile uint8_t *)glueMap->getVirtualAddress();
    uint32_t probeNic = rd(0x04), probeGlue = pcsRd(0);
    LOG("probe reads: nic 0x04 %08x, glue 0x4000 %08x", probeNic, probeGlue);
    if (probeNic == 0xffffffff || probeGlue == 0xffffffff) { LOG("the registers do not answer: not attaching an interface"); return; }

    // Linux left the chip running with its rings armed: no DMA from it until enable()
    setRealCommand(0x4, false);
    // mask and stop it (no reset here)
    LOG("DMA state as found: tx ctl %08x rx ctl %08x tx base %08x cur %08x rx base %08x cur %08x imr %08x isr %08x", rd(0x34), rd(0x38), rd(0x44), rd(0x3c), rd(0x48), rd(0x40), rd(0x54), rd(0x50));
    stopDma();
    wr(GBE_REG_ISR, rd(GBE_REG_ISR));
    LOG("DMA state after stop: tx ctl %08x rx ctl %08x imr %08x", rd(0x34), rd(0x38), rd(0x54));

    uint32_t rev = pcsRd(0);
    chipId = ((rev >> 8) & 0xff0000);          // 0x11xxxxxx -> 0x110000 (Salina), 0x12 -> 0x120000 (Salina 2)
    chipRev = rev & 0xffff;
    LOG("chip revision %08x -> chip %06x rev %04x; pcs 5c %08x 60 %08x 64 %08x 68 %08x 6c %08x", rev, chipId, chipRev, pcsRd(0x5c), pcsRd(0x60), pcsRd(0x64), pcsRd(0x68), pcsRd(0x6c));
    for (int i = 0; i < 6; i++) mac.bytes[i] = glueRegs[GBE_GLUE_MAC + i];
    LOG("MAC %02x:%02x:%02x:%02x:%02x:%02x", mac.bytes[0], mac.bytes[1], mac.bytes[2], mac.bytes[3], mac.bytes[4], mac.bytes[5]);
    dumpRegs();

    if (!allocRings()) { LOG("DMA allocation failed"); return; }


    mediumDict = OSDictionary::withCapacity(2);
    IONetworkMedium *m = IONetworkMedium::medium(kIOMediumEthernetAuto, 1000 * 1000000ULL);
    IONetworkMedium *m1000 = IONetworkMedium::medium(kIOMediumEthernet1000BaseT | kIOMediumOptionFullDuplex, 1000 * 1000000ULL);
    if (!mediumDict || !m || !m1000) return;
    IONetworkMedium::addMedium(mediumDict, m);
    IONetworkMedium::addMedium(mediumDict, m1000);
    if (!publishMediumDictionary(mediumDict)) return;
    setSelectedMedium(m);
    autoMedium = m1000;                      // the dictionary keeps both entries alive
    m->release();
    m1000->release();

    if (!attachInterface((IONetworkInterface **)&netif, false)) { LOG("attachInterface failed"); return; }
    netif->registerService();
    registerService();
    LOG("interface attached");
}


bool PS5SalinaGbE::createWorkLoop()
{
    // a loop of our own: the PHY bring-up busy-waits and must not hold the PCI family's loop
    ownLoop = IOWorkLoop::workLoop();
    return ownLoop != nullptr;
}

IOWorkLoop *PS5SalinaGbE::getWorkLoop() const { return ownLoop; }

void PS5SalinaGbE::stop(IOService *provider)
{
    running = false;
    if (initTimer) initTimer->cancelTimeout();
    if (timer) timer->cancelTimeout();
    if (regs) stopDma();
    if (outQueue) { outQueue->stop(); outQueue->flush(); }
    if (netif) { detachInterface(netif); netif->release(); netif = nullptr; }
    if (pci) pci->close(this);
    super::stop(provider);
}

void PS5SalinaGbE::free()
{
    if (initTimer) { if (ownLoop) ownLoop->removeEventSource(initTimer); initTimer->release(); initTimer = nullptr; }
    if (timer) { if (ownLoop) ownLoop->removeEventSource(timer); timer->release(); timer = nullptr; }
    if (ownLoop) { ownLoop->release(); ownLoop = nullptr; }
    freeRings();
    if (regMap) { regMap->release(); regMap = nullptr; }
    if (glueMap) { glueMap->release(); glueMap = nullptr; }
    if (ecamMap) { ecamMap->release(); ecamMap = nullptr; }
    if (regMd) { regMd->release(); regMd = nullptr; }
    if (glueMd) { glueMd->release(); glueMd = nullptr; }
    if (ecamMd) { ecamMd->release(); ecamMd = nullptr; }
    if (glue) { glue->release(); glue = nullptr; }
    if (pci) { pci->release(); pci = nullptr; }
    if (mediumDict) { mediumDict->release(); mediumDict = nullptr; }
    if (lock) { IOSimpleLockFree(lock); lock = nullptr; }
    super::free();
}

// ---------------------------------------------------------------------------------------------------------------- phy (SMI/MDIO)

int PS5SalinaGbE::smiWait()
{
    for (int i = 0; i < 10000; i++) {
        if (rd(GBE_REG_SMI) & (1u << 15)) return 0;
        IODelay(1);
    }
    smiTimeouts++;
    return -1;
}

uint16_t PS5SalinaGbE::cl22Read(uint8_t reg)
{
    wr(GBE_REG_SMI, 1u << 15);
    wr(GBE_REG_SMI, ((reg & 0x1f) << 8) | 0x4000);
    if (smiWait()) return 0;
    return rd(GBE_REG_SMI) >> 16;
}

void PS5SalinaGbE::smiWrite(uint8_t reg, uint16_t val)
{
    wr(GBE_REG_SMI, 1u << 15);
    wr(GBE_REG_SMI, ((uint32_t)val << 16) | ((reg & 0x1f) << 8) | 0x2000);
    smiWait();
}

int PS5SalinaGbE::cl45Addr(uint32_t sel)
{
    wr(GBE_REG_SMI, 1u << 15);
    wr(GBE_REG_SMI, (sel & 0xffff0000) | ((sel & 0x1f) << 8) | 0x20);
    return smiWait();
}

void PS5SalinaGbE::cl45Write(uint32_t sel, uint16_t val)
{
    if (cl45Addr(sel)) return;
    wr(GBE_REG_SMI, 1u << 15);
    wr(GBE_REG_SMI, ((uint32_t)val << 16) | ((sel & 0x1f) << 8) | 0x60);
    smiWait();
}

uint16_t PS5SalinaGbE::cl45Read(uint32_t sel)
{
    if (cl45Addr(sel)) return 0;
    wr(GBE_REG_SMI, 1u << 15);
    wr(GBE_REG_SMI, ((sel & 0x1f) << 8) | 0xe0);
    if (smiWait()) return 0;
    return rd(GBE_REG_SMI) >> 16;
}

uint8_t PS5SalinaGbE::calLutIdx(uint32_t field)
{
    field &= 0x7f;
    if (field < 2) field = 1;
    if (field >= 0x40) field = 0x40;
    return calLut[field - 1];
}

void PS5SalinaGbE::calLane(uint32_t sel, uint8_t cal, bool high)
{
    uint16_t cur = cl45Read(sel);
    if (high) cl45Write(sel, (cur & 0x00ff) | (cal << 8) | 0x8000);
    else cl45Write(sel, (cur & 0xff00) | cal | 0x80);
}

uint16_t PS5SalinaGbE::eqPreset(uint32_t field)
{
    uint32_t f = field & 0x3f;
    if (f > 0x3c) f = 0x3c;
    return (f + 3) & 0xff;
}

void PS5SalinaGbE::phyCalibrate()
{
    uint32_t v;
    v = pcsRd(0x68);
    cl45Write(0x000e001e, (v & 0x3f) << 8);
    v = pcsRd(0x68);
    cl45Write(0x0115001f, (v >> 6) & 7);

    v = pcsRd(0x60);
    calLane(0x0174001e, calLutIdx(v), true);
    v = pcsRd(0x60);
    calLane(0x0174001e, calLutIdx(v >> 0x13), false);
    v = pcsRd(0x64);
    calLane(0x0175001e, calLutIdx(v >> 6), true);
    v = pcsRd(0x64);
    calLane(0x0175001e, calLutIdx(v >> 0x19), false);

    v = pcsRd(0x5c);
    cl45Write(0x0172001e, (cl45Read(0x0172001e) & 0xc0ff) | ((v >> 0xc) & 0x3f00));
    v = pcsRd(0x60);
    cl45Write(0x0172001e, (cl45Read(0x0172001e) & 0xffc0) | ((v >> 7) & 0x3f));
    v = pcsRd(0x60);
    cl45Write(0x0173001e, (cl45Read(0x0173001e) & 0xc0ff) | ((v >> 0x12) & 0x3f00));
    v = pcsRd(0x64);
    cl45Write(0x0173001e, (cl45Read(0x0173001e) & 0xffc0) | ((v >> 0xd) & 0x3f));

    v = pcsRd(0x5c) >> 0x1a;
    cl45Write(0x0012001e, (v << 0xa) | v);
    cl45Write(0x0016001e, (eqPreset(v) << 0xa) | v);
    v = pcsRd(0x60) >> 0xd;
    cl45Write(0x0017001e, ((v & 0x3f) << 8) | (v & 0x3f));
    cl45Write(0x0018001e, (eqPreset(v) << 8) | (v & 0x3f));
    v = pcsRd(0x64);
    cl45Write(0x0019001e, ((v & 0x3f) << 8) | (v & 0x3f));
    cl45Write(0x0020001e, (eqPreset(v) << 8) | (v & 0x3f));
    v = pcsRd(0x64) >> 0x13;
    cl45Write(0x0021001e, ((v & 0x3f) << 8) | (v & 0x3f));
    cl45Write(0x0022001e, (eqPreset(v) << 8) | (v & 0x3f));

    cl45Write(0x0096001e, 0x8000);
    cl45Write(0x0037001e, 0x0033);
    cl45Write(0x0039001e, cl45Read(0x0039001e) & 0xb7ff);
    cl45Write(0x0107001f, cl45Read(0x0107001f) & 0xefff);
    cl45Write(0x0171001e, cl45Read(0x0171001e) | 0x0180);
    cl45Write(0x0039001e, cl45Read(0x0039001e) | 0x2000);
    cl45Write(0x0039001e, cl45Read(0x0039001e) & 0xdfff);
    IODelay(50);
    cl45Write(0x0171001e, cl45Read(0x0171001e) & 0xfe7f);
}

void PS5SalinaGbE::smiPaged(uint16_t a, uint16_t b, uint16_t c)
{
    uint16_t page = cl22Read(0x1f);
    smiWrite(0x1f, 0x52b5);
    smiWrite(0x11, a);
    smiWrite(0x12, b);
    smiWrite(0x10, c);
    smiWrite(0x1f, page);
}

uint16_t PS5SalinaGbE::pagedBegin(uint16_t r11, uint16_t r12)
{
    uint16_t page = cl22Read(0x1f);
    smiWrite(0x1f, 0x52b5);
    smiWrite(0x11, r11);
    smiWrite(0x12, r12);
    return page;
}

void PS5SalinaGbE::pagedFinish(uint16_t r10, uint16_t page)
{
    smiWrite(0x10, r10);
    smiWrite(0x1f, page);
}

void PS5SalinaGbE::phyStaticInit()
{
    cl45Write(0x003e001e, 0xf8f8);
    cl45Write(0x0189001e, 0x0110);
    smiPaged(0xb90a, 0x006f, 0x8f82);
    smiPaged(0xbaef, 0x002e, 0x968c);

    smiWrite(0x1f, 0x0003);                    // page 3: LED configuration
    smiWrite(0x1c, 0x0c92);
    smiWrite(0x1f, 0x0000);

    wr(GBE_REG_RX_PCODE + 4, 25000000);

    cl45Write(0x0122001e, 0xffff);
    cl45Write(0x0234001e, 0x0180);
    smiPaged(0x2e00, 0x000e, 0x8fb0);

    cl45Write(0x0238001e, 0x0120);
    if (chipId == 0x110000) cl45Write(0x0120001e, 0x9014);
    cl45Write(0x0239001e, 0x0117);
    smiPaged(0x0001, 0x0004, 0x96a2);

    clrBits(GBE_REG_RX_PCODE, 1);

    cl45Write(0x003c0007, 0x0000);
    cl45Write(0x0033001e, cl45Read(0x0033001e) & 0xefff);
    cl45Write(0x0268001f, 0x07f4);

    smiPaged(0x0004, 0x0000, 0x9686);
    smiPaged(0x0671, 0x0006, 0x8fae);
    smiPaged(0x55a0, 0x0000, 0x83aa);

    cl45Write(0x0123001e, 0xffff);

    smiPaged(0x8670, 0x0001, 0x96a6);
    smiPaged(0x0072, 0x0000, 0x96b6);
    smiPaged(0x3210, 0x0000, 0x96b8);
    smiPaged(0x024a, 0x0000, 0x96a8);

    if (chipId == 0x110000) {
        if (chipRev == 0x0100) {
            LOG("PHY tune: path A");
            smiPaged(0x704d, 0x0000, 0x9698);
            smiPaged(0x314f, 0x0002, 0x969a);
            uint16_t page = pagedBegin(0x4444, 0x0044);
            pagedFinish(0x8ecc, page);
        } else if (chipRev == 0x0200) {
            LOG("PHY tune: path C");
            smiPaged(0x5010, 0x0000, 0x96a0);
            smiPaged(0x3028, 0x0000, 0x969e);
            smiPaged(0x504d, 0x0000, 0x9698);
            uint16_t page = pagedBegin(0x194f, 0x0002);
            pagedFinish(0x969a, page);
        } else {
            LOG("PHY tune: path B (rev %04x)", chipRev);
            smiPaged(0x5010, 0x0000, 0x96a0);
            smiPaged(0x3028, 0x0000, 0x969e);
            smiPaged(0x504d, 0x0000, 0x9698);
            smiPaged(0x194f, 0x0002, 0x969a);
            cl45Write(0x014a001e, 0xee20);
            cl45Write(0x019b001e, 0x0111);
        }
    } else {
        LOG("PHY tune: path D (chip %06x)", chipId);
        smiPaged(0x5010, 0x0000, 0x96a0);
        smiPaged(0x3028, 0x0000, 0x969e);
        smiPaged(0x504d, 0x0000, 0x9698);
        smiPaged(0x194f, 0x0002, 0x969a);
        cl45Write(0x014a001e, 0xee20);
        cl45Write(0x019b001e, 0x0111);
        cl45Write(0x0144001e, 0x0200);
        smiWrite(0x1f, 0x0003);
        smiWrite(0x1d, 0x03fb);
        smiWrite(0x1f, 0x0000);
        cl45Write(0x0323001e, 0x0011);
        smiPaged(0x0036, 0x0000, 0x8f80);
        cl45Write(0x0120001e, 0x8014);
        uint16_t page = pagedBegin(0xff3f, 0x0000);
        pagedFinish(0x83ae, page);
        static const uint16_t tab[12] = { 0x0186, 0x01c5, 0x01c8, 0x010e, 0x0202, 0x0207, 0x0386, 0x03c5, 0x03c8, 0x030a, 0x0005, 0x0008 };
        for (uint32_t i = 0; i < 12; i++) cl45Write((i << 16) | 0x1e, tab[i]);
    }
    cl45Write(0x003e001e, 0x0000);
}

void PS5SalinaGbE::phyInit()
{
    LOG("phy id before reset %04x:%04x, pcs 6c %08x", cl22Read(2), cl22Read(3), pcsRd(0x6c));

    wr(GBE_REG_RESET, 9);
    IODelay(1000);

    if (~pcsRd(0x6c) & 0x80800000) LOG("SerDes not locked, skipping calibration");
    else phyCalibrate();

    phyStaticInit();

    smiWrite(4, cl22Read(4) & 0xf3ff);                         // MII_ADVERTISE
    wr(GBE_REG_LINK, rd(GBE_REG_LINK) & 0x7fffcfff);
    cl22Read(4);
    cl22Read(9);                                               // MII_CTRL1000
    smiWrite(0, 0x0800);                                       // BMCR: power down
    smiWrite(4, (cl22Read(4) & 0xfe1f) | 0x01e0);
    smiWrite(9, (cl22Read(9) & 0xfcff) | 0x0200);
    smiWrite(0, 0x1340);
    smiWrite(0, cl22Read(0) | 0x1200);                         // autoneg enable + restart

    LOG("phy id=%04x:%04x bmcr=%04x bmsr=%04x adv=%04x ctrl1000=%04x link_reg=%08x, %u SMI timeouts", cl22Read(2), cl22Read(3), cl22Read(0), cl22Read(1), cl22Read(4), cl22Read(9), rd(GBE_REG_LINK), smiTimeouts);
}

// ---------------------------------------------------------------------------------------------------------------- hardware

void PS5SalinaGbE::writeMac()
{
    wr(GBE_REG_MAC_HI, (mac.bytes[0] << 8) | mac.bytes[1]);
    wr(GBE_REG_MAC_LO, (mac.bytes[2] << 24) | (mac.bytes[3] << 16) | (mac.bytes[4] << 8) | mac.bytes[5]);
}

void PS5SalinaGbE::hwReset()
{
    wr(GBE_REG_RESET, 9);
    IODelay(1000);
}

void PS5SalinaGbE::hwInit()
{
    hwReset();
    setBits(GBE_REG_CLK_CTRL, GBE_CLK_ENABLE);
    phyInit();
    clrBits(GBE_REG_CTRL, 1u << 7);
    wr(GBE_REG_SERDES, GBE_SERDES_1G);
    wr(GBE_REG_MODE, (rd(GBE_REG_MODE) & 0xffffff6e) | 0x81);
    wr(GBE_REG_RXBUF, 0x10100);
    writeMac();
    wr(GBE_REG_COAL, 0);
}

void PS5SalinaGbE::initTxRing()
{
    for (uint32_t i = 0; i < GBE_RING_SIZE; i++) {
        txRing[i].flags = GBE_DESC_DONE | (i == GBE_RING_SIZE - 1 ? GBE_DESC_WRAP : 0);
        txRing[i].buf_addr = 0;
        txRing[i].word2 = GBE_DESC_W2_ARM;
        txRing[i].word3 = 0;
    }
    txHead = txTail = 0;
    txScratchOff = 0;
}

void PS5SalinaGbE::rxFill()
{
    for (uint32_t i = 0; i < GBE_RING_SIZE; i++) {
        rxRing[i].buf_addr = rxPoolPa + i * GBE_DESC_RX_LEN;
        rxRing[i].word2 = 0;
        rxRing[i].word3 = 0;
        BARRIER();
        rxRing[i].flags = GBE_DESC_RX_LEN | (i == GBE_RING_SIZE - 1 ? GBE_DESC_WRAP : 0);
    }
    rxHead = 0;
}

void PS5SalinaGbE::ringsHw()
{
    initTxRing();
    BARRIER();
    wr(GBE_REG_TX_RING_BASE, txRingPa);
    wr(GBE_REG_TX_RING_CUR, txRingPa);
    wr(GBE_REG_RX_RING_BASE, rxRingPa);
    wr(GBE_REG_RX_RING_CUR, rxRingPa);
    clrBits(GBE_REG_TXKICK, 1u << 6);                          // toggle bit 6: clears a stale LSO cause
    setBits(GBE_REG_TXKICK, 1u << 6);
    setRealCommand(0x6, true);                                 // memory + bus master of the real function, only now that both rings are programmed
    setBits(GBE_REG_TX_DMA_CTRL, 1);
    setBits(GBE_REG_RX_DMA_CTRL, 1);
    wr(GBE_REG_ISR, rd(GBE_REG_ISR));
    wr(GBE_REG_IMR, GBE_IMR_ALL);                              // polled: nothing is unmasked (0x54 is a mask register)
}

void PS5SalinaGbE::stopDma()
{
    wr(GBE_REG_IMR, GBE_IMR_ALL);
    wr(GBE_REG_COAL, 0);
    setBits(GBE_REG_TX_DMA_CTRL, GBE_DMA_STOP);
    int i;
    for (i = 0; i < 100000 && (rd(GBE_REG_TX_DMA_CTRL) & GBE_DMA_STOP); i++) IODelay(1);
    if (i == 100000) LOG("TX DMA did not stop (ctl %08x)", rd(GBE_REG_TX_DMA_CTRL));
    setBits(GBE_REG_RX_DMA_CTRL, GBE_DMA_STOP);
    for (i = 0; i < 100000 && (rd(GBE_REG_RX_DMA_CTRL) & GBE_DMA_STOP); i++) IODelay(1);
    if (i == 100000) LOG("RX DMA did not stop (ctl %08x)", rd(GBE_REG_RX_DMA_CTRL));
}

void PS5SalinaGbE::lsoRecover()
{
    if (lsoLogs++ < 5) LOG("LSO error, rebuilding the TX ring");
    IOSimpleLockLock(lock);
    clrBits(GBE_REG_TXKICK, 1u << 6);
    setBits(GBE_REG_TXKICK, 1u << 6);
    initTxRing();
    BARRIER();
    wr(GBE_REG_TX_RING_BASE, txRingPa);
    wr(GBE_REG_TX_RING_CUR, txRingPa);
    setBits(GBE_REG_TX_DMA_CTRL, 1);
    IOSimpleLockUnlock(lock);
}

void PS5SalinaGbE::linkCheck(bool force)
{
    uint32_t reg = rd(GBE_REG_LINK);
    bool up = reg & 1;
    if (up == linkUp && !force) return;
    linkUp = up;
    LOG("link %s (reg=%08x)", up ? "up" : "down", reg);
    setLinkStatus(up ? (kIONetworkLinkValid | kIONetworkLinkActive) : kIONetworkLinkValid, up ? autoMedium : nullptr, up ? 1000 * 1000000ULL : 0);
}

// ---------------------------------------------------------------------------------------------------------------- IOEthernetController

IOReturn PS5SalinaGbE::enable(IONetworkInterface *iface)
{
    if (running) return kIOReturnSuccess;
    LOG("enable");
    hwInit();
    rxFill();
    ringsHw();
    dumpRegs();
    outQueue = OSDynamicCast(IOBasicOutputQueue, getOutputQueue());
    if (outQueue) { outQueue->setCapacity(512); LOG("output queue start: %d", (int)outQueue->start()); }
    else LOG("no output queue");
    txStuck = 0; txTailSeen = 0;
    running = true;
    linkUp = false;
    linkCheck(true);
    timer->setTimeout(pollUs, kMicrosecondScale);
    return kIOReturnSuccess;
}

IOReturn PS5SalinaGbE::disable(IONetworkInterface *iface)
{
    if (!running) return kIOReturnSuccess;
    LOG("disable");
    running = false;
    timer->cancelTimeout();
    if (outQueue) { outQueue->stop(); outQueue->flush(); }
    stopDma();
    setLinkStatus(kIONetworkLinkValid, nullptr, 0);
    return kIOReturnSuccess;
}

IOReturn PS5SalinaGbE::getHardwareAddress(IOEthernetAddress *addr) { *addr = mac; return kIOReturnSuccess; }
IOReturn PS5SalinaGbE::setHardwareAddress(const IOEthernetAddress *addr) { mac = *addr; if (running) writeMac(); return kIOReturnSuccess; }
IOReturn PS5SalinaGbE::setPromiscuousMode(bool) { return kIOReturnSuccess; }          // the chip has no receive filter that the Linux driver programs
IOReturn PS5SalinaGbE::setMulticastMode(bool) { return kIOReturnSuccess; }
IOReturn PS5SalinaGbE::setMulticastList(IOEthernetAddress *, UInt32) { return kIOReturnSuccess; }
IOReturn PS5SalinaGbE::selectMedium(const IONetworkMedium *medium) { setSelectedMedium(medium); return kIOReturnSuccess; }
UInt32 PS5SalinaGbE::getFeatures() const { return 0; }

// Run-time tunables, set from user space with tools/ps5ctl (IORegistryEntrySetCFProperties): PollUs, RxBudget.
IOReturn PS5SalinaGbE::setProperties(OSObject *properties)
{
    OSDictionary *d = OSDynamicCast(OSDictionary, properties);
    if (!d) return kIOReturnBadArgument;
    OSNumber *n;
    if ((n = OSDynamicCast(OSNumber, d->getObject("PollUs")))) { uint32_t v = n->unsigned32BitValue(); pollUs = v < 50 ? 50 : v; LOG("PollUs %u", pollUs); }
    if ((n = OSDynamicCast(OSNumber, d->getObject("RxBudget")))) { uint32_t v = n->unsigned32BitValue(); rxBudget = v < 1 ? 1 : v; LOG("RxBudget %u", rxBudget); }
    return kIOReturnSuccess;
}
const OSString *PS5SalinaGbE::newVendorString() const { return OSString::withCString("Sony"); }
const OSString *PS5SalinaGbE::newModelString() const { return OSString::withCString("Salina GbE"); }

IOOutputQueue *PS5SalinaGbE::createOutputQueue()
{
    return IOBasicOutputQueue::withTarget(this, 512);
}

// ---------------------------------------------------------------------------------------------------------------- data path

void PS5SalinaGbE::txComplete()
{
    uint32_t tail = txTail;
    while (tail != txHead) {
        GbeDesc *d = &txRing[tail];
        uint32_t flags = d->flags, w2 = d->word2;
        if (!(flags & GBE_DESC_DONE)) break;
        if (w2 >= GBE_DESC_W2_ARM) break;
        if (dbgTxDone++ < 4) LOG("tx done slot %u flags %08x w2 %08x", tail, flags, w2);
        d->word2 = w2 | GBE_DESC_W2_ARM;
        tail = (tail + 1) % GBE_RING_SIZE;
    }
    txTail = tail;
}

UInt32 PS5SalinaGbE::outputPacket(mbuf_t m, void *)
{
    if (!running) { freePacket(m); txDrop++; return kIOReturnOutputDropped; }
    size_t len = mbuf_pkthdr_len(m);
    size_t plen = len < 60 ? 60 : len;
    if (len > GBE_MAX_FRAME) { freePacket(m); txDrop++; return kIOReturnOutputDropped; }

    IOSimpleLockLock(lock);
    txComplete();
    uint32_t head = txHead;
    if (((head + 1) % GBE_RING_SIZE) == txTail) {
        IOSimpleLockUnlock(lock);
        txStall++;
        return kIOReturnOutputStall;                         // the queue keeps the packet and retries after we resume it
    }
    uint32_t aligned = (plen + 0x7f) & ~0x7fu, off = txScratchOff;
    if (off + aligned > GBE_TX_SCRATCH_SIZE) off = 0;
    txScratchOff = off + aligned;
    if (txScratchOff >= GBE_TX_SCRATCH_SIZE) txScratchOff = 0;

    mbuf_copydata(m, 0, len, txScratch + off);
    if (plen > len) bzero(txScratch + off + len, plen - len);

    txRing[head].buf_addr = txScratchPa + off;
    txRing[head].word2 = GBE_DESC_W2_TX;
    txRing[head].word3 = 0;
    BARRIER();
    txRing[head].flags = (plen & GBE_DESC_LEN_MASK) | GBE_DESC_SOP | GBE_DESC_EOP | (head == GBE_RING_SIZE - 1 ? GBE_DESC_WRAP : 0);
    txHead = (head + 1) % GBE_RING_SIZE;
    setBits(GBE_REG_TX_DMA_CTRL, GBE_DMA_KICK);
    IOSimpleLockUnlock(lock);

    txOk++;
    if (dbgTx++ < 8) LOG("tx %lu bytes, ring head %u: flags %08x w2 %08x", (unsigned long)len, head, txRing[head].flags, txRing[head].word2);
    freePacket(m);
    return kIOReturnOutputSuccess;
}

int PS5SalinaGbE::rxPoll(int budget)
{
    int done = 0;
    uint32_t i = rxHead;
    while (done < budget && (rxRing[i].flags & GBE_DESC_DONE)) {
        uint32_t flags = rxRing[i].flags, len = flags & GBE_DESC_RX_LEN_MASK;
        if (dbgRx < 4) {
            const uint8_t *f = rxPool + i * GBE_DESC_RX_LEN;
            LOG("rx slot %u: desc %08x %08x %08x %08x, bytes %02x%02x%02x%02x%02x%02x %02x%02x%02x%02x%02x%02x %02x%02x", i, rxRing[i].flags, rxRing[i].buf_addr,
                rxRing[i].word2, rxRing[i].word3, f[0], f[1], f[2], f[3], f[4], f[5], f[6], f[7], f[8], f[9], f[10], f[11], f[12], f[13]);
            dbgRx++;
        }
        if (len >= 60 && len <= GBE_DESC_RX_LEN) {
            mbuf_t pkt = allocatePacket(len);
            if (pkt) {
                memcpy(mbuf_data(pkt), rxPool + i * GBE_DESC_RX_LEN, len);
                netif->inputPacket(pkt, len, IONetworkInterface::kInputOptionQueuePacket);
                rxOk++;
            } else rxNoMem++;
        } else rxBad++;
        rxRing[i].word2 = 0;
        rxRing[i].word3 = 0;
        BARRIER();
        rxRing[i].flags = GBE_DESC_RX_LEN | (i == GBE_RING_SIZE - 1 ? GBE_DESC_WRAP : 0);
        done++;
        i = (i + 1) % GBE_RING_SIZE;
    }
    rxHead = i;
    if (done) {
        setBits(GBE_REG_RX_DMA_CTRL, GBE_DMA_KICK);
        netif->flushInputQueue();
    }
    return done;
}

void PS5SalinaGbE::poll()
{
    uint32_t isr = rd(GBE_REG_ISR);
    if (isr) wr(GBE_REG_ISR, isr);
    isrSeen |= isr;
    if ((isr & GBE_ISR_ERRORS) && errLogs++ < 10) LOG("HW error %08x", isr & GBE_ISR_ERRORS);
    if (isr & GBE_ISR_LSO_RECOVER) lsoRecover();

    IOSimpleLockLock(lock);
    txComplete();
    setBits(GBE_REG_TX_DMA_CTRL, GBE_DMA_KICK);
    IOSimpleLockUnlock(lock);
    if (outQueue == nullptr) outQueue = OSDynamicCast(IOBasicOutputQueue, getOutputQueue());
    if (outQueue) outQueue->service();                      // restart output that stalled on a full ring

    int burst = rxPoll((int)rxBudget);
    if (burst > (int)rxBurstMax) rxBurstMax = burst;
    if (isr & (2u | 0x20u)) { setBits(GBE_REG_RX_DMA_CTRL, GBE_DMA_KICK); rxEmptyKicks++; }      // RX_EMPTY: the engine waits for a kick
    polls++;

    if (txHead != txTail && txTail == txTailSeen) { if (++txStuck >= 2000) { txStuck = 0; txTimeout(); } }
    else { txStuck = 0; txTailSeen = txTail; }

    if (++pollTick >= 1000) {
        pollTick = 0;
        linkCheck(false);
        status(false);
        publishStats();
        if (!recapDone && ++recapSecs >= 12) { recapDone = true; recap(); }
    }
}

// a transmit that never completes for 2 s: stop the TX engine, rebuild the ring (gbe_tx_timeout)
void PS5SalinaGbE::txTimeout()
{
    if (txTimeoutLogs++ < 3) LOG("TX timeout: head %u tail %u, rebuilding the ring", txHead, txTail);
    IOSimpleLockLock(lock);
    setBits(GBE_REG_TX_DMA_CTRL, GBE_DMA_STOP);
    for (int i = 0; i < 1000 && (rd(GBE_REG_TX_DMA_CTRL) & GBE_DMA_STOP); i++) IODelay(1);
    initTxRing();
    BARRIER();
    wr(GBE_REG_TX_RING_BASE, txRingPa);
    wr(GBE_REG_TX_RING_CUR, txRingPa);
    clrBits(GBE_REG_TXKICK, 1u << 6);
    setBits(GBE_REG_TXKICK, 1u << 6);
    setBits(GBE_REG_TX_DMA_CTRL, 1 | GBE_DMA_KICK);
    IOSimpleLockUnlock(lock);
}

// Counters in the IORegistry (ioreg -c PS5SalinaGbE -l | grep -A16 Stats): the kernel log of a kext is not readable over ssh here.
void PS5SalinaGbE::publishStats()
{
    OSDictionary *d = OSDictionary::withCapacity(16);
    if (!d) return;
    struct { const char *k; uint32_t v; } kv[] = {
        { "polls", polls }, { "txOk", txOk }, { "txDrop", txDrop }, { "txStall", txStall }, { "rxOk", rxOk }, { "rxBad", rxBad }, { "rxNoMem", rxNoMem },
        { "rxBurstMax", rxBurstMax }, { "rxEmptyKicks", rxEmptyKicks }, { "txHead", txHead }, { "txTail", txTail }, { "rxHead", rxHead },
        { "txTimeouts", txTimeoutLogs }, { "isrSeen", isrSeen }, { "link", rd(GBE_REG_LINK) }, { "pollUs", pollUs }, { "rxBudget", rxBudget },
    };
    for (auto &e : kv) {
        OSNumber *n = OSNumber::withNumber(e.v, 32);
        if (n) { d->setObject(e.k, n); n->release(); }
    }
    setProperty("Stats", d);
    d->release();
    rxBurstMax = 0;
}

// one line per second, and only while something changes (the console is a TV)
void PS5SalinaGbE::status(bool force)
{
    uint32_t link = rd(GBE_REG_LINK);
    bool changed = force || txHead != lastTxHead || txTail != lastTxTail || rxHead != lastRxHead || link != lastLink || isrSeen != lastIsrSeen;
    if (!changed) return;
    lastTxHead = txHead; lastTxTail = txTail; lastRxHead = rxHead; lastLink = link; lastIsrSeen = isrSeen;
    LOG("st link %08x bmsr %04x isr %08x tx %u/%u hw %u rx %u hw %u | tx ok %u drop %u stall %u | rx ok %u bad %u nomem %u",
        link, cl22Read(1), isrSeen, txHead, txTail, (rd(GBE_REG_TX_RING_CUR) - txRingPa) / 16, rxHead, (rd(GBE_REG_RX_RING_CUR) - rxRingPa) / 16,
        txOk, txDrop, txStall, rxOk, rxBad, rxNoMem);
}

void PS5SalinaGbE::pollTimer(OSObject *owner, IOTimerEventSource *t)
{
    PS5SalinaGbE *self = OSDynamicCast(PS5SalinaGbE, owner);
    if (!self || !self->running) return;
    self->poll();
    t->setTimeout(self->pollUs, kMicrosecondScale);
}
