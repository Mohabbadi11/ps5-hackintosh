#include <Headers/kern_api.hpp>
#include <Headers/kern_patcher.hpp>
#include <Headers/kern_util.hpp>
#include <Headers/plugin_start.hpp>
#include <IOKit/IOService.h>
#include <libkern/c++/OSData.h>
#include <libkern/c++/OSDictionary.h>
#include <libkern/c++/OSIterator.h>

extern "C" boolean_t PE_parse_boot_argn(const char *arg_string, void *arg_ptr, int max_len);

static const char *pathHWServices = "/System/Library/Extensions/AMDRadeonX6000HWServices.kext/Contents/MacOS/AMDRadeonX6000HWServices";
static const char *pathHWLibs = "/System/Library/Extensions/AMDRadeonX6000HWServices.kext/Contents/PlugIns/AMDRadeonX6000HWLibs.kext/Contents/MacOS/AMDRadeonX6000HWLibs";
static const char *pathAccel = "/System/Library/Extensions/AMDRadeonX6000.kext/Contents/MacOS/AMDRadeonX6000";
static const char *pathFB = "/System/Library/Extensions/AMDRadeonX6000Framebuffer.kext/Contents/MacOS/AMDRadeonX6000Framebuffer";

static KernelPatcher::KextInfo kextHWServices {"com.apple.kext.AMDRadeonX6000HWServices", &pathHWServices, 1, {true}, {}, KernelPatcher::KextInfo::Unloaded};
static KernelPatcher::KextInfo kextHWLibs {"com.apple.kext.AMDRadeonX6000HWLibs", &pathHWLibs, 1, {true}, {}, KernelPatcher::KextInfo::Unloaded};
static KernelPatcher::KextInfo kextAccel {"com.apple.kext.AMDRadeonX6000", &pathAccel, 1, {true}, {}, KernelPatcher::KextInfo::Unloaded};
static KernelPatcher::KextInfo kextFB {"com.apple.kext.AMDRadeonX6000Framebuffer", &pathFB, 1, {true}, {}, KernelPatcher::KextInfo::Unloaded};

static uint32_t blockedPowerPlay = 0;

static long blockPowerPlay(void *, void *)
{
    blockedPowerPlay++;
    SYSLOG("ps5cyan", "PowerPlay interface blocked (%u)", blockedPowerPlay);
    return 0;
}

static long blockHangReset(void *, void *)
{
    SYSLOG("ps5cyan", "Blocked ASIC hang reset");
    return 0;
}

static bool publishedHdaGfx = false;

static void publishHdaGfx()
{
    if (publishedHdaGfx) return;
    OSDictionary *matching = IOService::serviceMatching("IOPCIDevice");
    if (matching == nullptr) return;
    OSIterator *iter = IOService::getMatchingServices(matching);
    if (iter == nullptr) return;
    publishedHdaGfx = true;
    while (auto *obj = iter->getNextObject()) {
        auto *entry = OSDynamicCast(IORegistryEntry, obj);
        if (entry == nullptr) continue;
        auto *vendor = OSDynamicCast(OSData, entry->getProperty("vendor-id"));
        auto *device = OSDynamicCast(OSData, entry->getProperty("device-id"));
        if (vendor != nullptr && device != nullptr && vendor->getLength() >= 2 && device->getLength() >= 2) {
            uint16_t vid = *reinterpret_cast<const uint16_t *>(vendor->getBytesNoCopy());
            uint16_t did = *reinterpret_cast<const uint16_t *>(device->getBytesNoCopy());
            if (vid == 0x1002 && did == 0x13fc) {
                entry->setProperty("hda-gfx", "onboard-1");
                SYSLOG("ps5cyan", "Published hda-gfx on provider PCI device (1002:13fc)");
            }
        }
        auto *classCode = OSDynamicCast(OSData, entry->getProperty("class-code"));
        if (vendor != nullptr && classCode != nullptr && vendor->getLength() >= 2 && classCode->getLength() >= 3) {
            uint16_t vid = *reinterpret_cast<const uint16_t *>(vendor->getBytesNoCopy());
            const uint8_t *cc = reinterpret_cast<const uint8_t *>(classCode->getBytesNoCopy());
            if (vid == 0x1002 && cc[1] == 0x03 && cc[2] == 0x04) {
                entry->setProperty("hda-gfx", "onboard-1");
                SYSLOG("ps5cyan", "Published hda-gfx on audio PCI device");
            }
        }
    }
    iter->release();
}

static mach_vm_address_t orgAccelHwInfo = 0;

static uint32_t wrapAccelHwInfo(void *device, uint8_t *out)
{
    uint32_t ret = FunctionCast(wrapAccelHwInfo, orgAccelHwInfo)(device, out);
    if (out != nullptr) {
        uint64_t *ref = reinterpret_cast<uint64_t *>(out + 0xC0);
        uint64_t *sys = reinterpret_cast<uint64_t *>(out + 0xC8);
        uint64_t *mem = reinterpret_cast<uint64_t *>(out + 0xD0);
        uint64_t *cg  = reinterpret_cast<uint64_t *>(out + 0xD8);
        if (*ref == 0) *ref = 10000;
        if (*sys == 0) *sys = 200000;
        if (*mem == 0) *mem = 175000;
        if (*cg == 0)  *cg  = 10000;
        if (ret == 0xE00002BC) ret = 0;
        SYSLOG("ps5cyan", "Injected Metal device clocks (2000 MHz GFX, 1750 MHz Mem)");
    }
    if (device != nullptr) {
        bool disableReuse = false;
        PE_parse_boot_argn("-ps5cyanreuseoff", &disableReuse, sizeof(disableReuse));
        if (disableReuse) {
            *reinterpret_cast<uint32_t *>(static_cast<uint8_t *>(device) + 0xC90) &= ~0x10000000U;
        }
        publishHdaGfx();
    }
    return ret;
}

static constexpr uint64_t kPteSystem = 1ULL << 1;
static constexpr uint64_t kPteAddrMask = 0x0000FFFFFFFFF000ULL;
static constexpr uint64_t kPdeAddrMask = 0x0000FFFFFFFFFFC0ULL;
static constexpr uint64_t kDefaultFbBase = 0xF400000000ULL;
static constexpr size_t kPlaneScanBytes = 0x200;
static constexpr size_t kCursorScanBytes = 0x80;
static constexpr size_t kMaxSaved = 8;
static constexpr size_t kMaxPipes = 6;
static const char kApplyPipeSplitFlags[] = "int dcn20_validate_apply_pipe_split_flags(struct dc *, struct dc_state *, int, int *, _Bool *)";

static uint64_t gvmFbOffset = 0x450000000ULL;
static uint64_t gvmFbSize = 0x20000000ULL;
static uint64_t gvmFbBase = kDefaultFbBase;

static bool toUMA(uint64_t &addr)
{
    const uint64_t base = gvmFbBase != 0 ? gvmFbBase : kDefaultFbBase;
    const uint64_t top = base + gvmFbSize;
    if (addr < base || addr >= top) return false;
    addr = addr - base + gvmFbOffset;
    return true;
}

static size_t translateWindow(void *base, size_t length, uint64_t *saved, size_t *savedOff, size_t maxSaved)
{
    if (base == nullptr) return 0;
    size_t count = 0;
    auto *words = static_cast<uint64_t *>(base);
    for (size_t i = 0; i < length / sizeof(uint64_t); i++) {
        uint64_t value = words[i];
        if (!toUMA(value)) continue;
        if (saved != nullptr && savedOff != nullptr) {
            if (count >= maxSaved) break;
            saved[count] = words[i];
            savedOff[count] = i;
        }
        words[i] = value;
        count++;
    }
    return count;
}

static void restoreWindow(void *base, const uint64_t *saved, const size_t *savedOff, size_t count)
{
    if (base == nullptr || saved == nullptr || savedOff == nullptr) return;
    auto *words = static_cast<uint64_t *>(base);
    for (size_t i = 0; i < count; i++) {
        words[savedOff[i]] = saved[i];
    }
}

static mach_vm_address_t orgPrepareSurface = 0;

static uint64_t wrapPrepareSurface(void *self, const void *displayPath, void *plane)
{
    const uint64_t ret = FunctionCast(wrapPrepareSurface, orgPrepareSurface)(self, displayPath, plane);
    translateWindow(plane, kPlaneScanBytes, nullptr, nullptr, 0);
    return ret;
}

static mach_vm_address_t orgUpdateSurfaceInfo = 0;

static uint64_t wrapUpdateSurfaceInfo(void *self, const void *plane, const void *displayPath)
{
    uint64_t saved[kMaxSaved];
    size_t off[kMaxSaved];
    auto *mutablePlane = const_cast<void *>(plane);
    const size_t n = translateWindow(mutablePlane, kPlaneScanBytes, saved, off, kMaxSaved);
    const uint64_t ret = FunctionCast(wrapUpdateSurfaceInfo, orgUpdateSurfaceInfo)(self, plane, displayPath);
    restoreWindow(mutablePlane, saved, off, n);
    return ret;
}

static mach_vm_address_t orgSetCursorImage = 0;

static uint64_t wrapSetCursorImage(void *self, const void *cursor)
{
    uint64_t saved[kMaxSaved];
    size_t off[kMaxSaved];
    auto *mutableCursor = const_cast<void *>(cursor);
    const size_t n = translateWindow(mutableCursor, kCursorScanBytes, saved, off, kMaxSaved);
    const uint64_t ret = FunctionCast(wrapSetCursorImage, orgSetCursorImage)(self, cursor);
    restoreWindow(mutableCursor, saved, off, n);
    return ret;
}

static mach_vm_address_t orgApplyPipeSplitFlags = 0;

static int wrapApplyPipeSplitFlags(void *dc, void *context, int vlevel, int *split, bool *merge)
{
    const int ret = FunctionCast(wrapApplyPipeSplitFlags, orgApplyPipeSplitFlags)(dc, context, vlevel, split, merge);
    if (split != nullptr) {
        for (size_t i = 0; i < kMaxPipes; i++) {
            if (split[i] != 0) split[i] = 0;
        }
    }
    return ret;
}

static mach_vm_address_t findFunctionByString(mach_vm_address_t start, size_t size, const char *str, size_t len)
{
    size_t strOff = 0;
    if (!KernelPatcher::findPattern(str, nullptr, len, reinterpret_cast<const void *>(start), size, &strOff)) {
        return 0;
    }
    const mach_vm_address_t strAddr = start + strOff;
    const uint8_t *p = reinterpret_cast<const uint8_t *>(start);

    mach_vm_address_t found = 0;
    for (size_t i = 0; i + 7 <= size; i++) {
        if ((p[i] != 0x48 && p[i] != 0x4C) || p[i + 1] != 0x8D || (p[i + 2] & 0xC7) != 0x05) {
            continue;
        }
        int32_t disp;
        __builtin_memcpy(&disp, p + i + 3, sizeof(disp));
        if (static_cast<mach_vm_address_t>(static_cast<int64_t>(start + i + 7) + disp) != strAddr) {
            continue;
        }
        mach_vm_address_t fn = 0;
        for (size_t j = i; j >= 4 && i - j < 0x8000; j--) {
            if (p[j] == 0x55 && p[j + 1] == 0x48 && p[j + 2] == 0x89 && p[j + 3] == 0xE5) {
                const uint8_t prev = p[j - 1];
                if ((j % 16) == 0 || prev == 0xC3 || prev == 0xCC || prev == 0x90 || prev == 0x00) {
                    fn = start + j;
                    break;
                }
            }
        }
        if (fn == 0 || (found != 0 && found != fn)) {
            return 0;
        }
        found = fn;
    }
    return found;
}

static uint64_t vramPhys(uint64_t address)
{
    if (address < gvmFbSize) return address + gvmFbOffset;
    if (gvmFbBase != 0 && address >= gvmFbBase && address < gvmFbBase + gvmFbSize) return address - gvmFbBase + gvmFbOffset;
    return address;
}

static uint64_t vmEntryAdjust(uint64_t entry, uint64_t mask)
{
    uint64_t address = entry & mask;
    uint64_t phys = vramPhys(address);
    if (phys == address) return entry;
    return (entry & ~mask) | (phys & mask);
}

static mach_vm_address_t orgGetPdeValue = 0;

static uint64_t wrapGetPdeValue(void *vmm, uint32_t level, uint64_t address)
{
    uint64_t ret = FunctionCast(wrapGetPdeValue, orgGetPdeValue)(vmm, level, address);
    return vmEntryAdjust(ret, kPdeAddrMask);
}

static mach_vm_address_t orgGetPteValue = 0;

static uint64_t wrapGetPteValue(void *vmm, uint32_t level, uint64_t address, uint32_t flags, uint32_t fragment)
{
    uint64_t ret = FunctionCast(wrapGetPteValue, orgGetPteValue)(vmm, level, address, flags, fragment);
    return (ret & kPteSystem) != 0 ? ret : vmEntryAdjust(ret, kPteAddrMask);
}

static mach_vm_address_t orgDecodePte = 0;

static bool wrapDecodePte(void *vmm, uint64_t entry, uint64_t *address, bool *system)
{
    bool valid = FunctionCast(wrapDecodePte, orgDecodePte)(vmm, entry, address, system);
    if (valid && address != nullptr && system != nullptr && !*system &&
        *address >= gvmFbOffset && *address < gvmFbOffset + gvmFbSize) {
        *address -= gvmFbOffset;
    }
    return valid;
}

static mach_vm_address_t orgUpdatePtesDma = 0;

static uint32_t wrapUpdatePtesDma(void *ctx, uint64_t pe, uint64_t count, uint64_t addr, uint64_t flags, uint64_t incr)
{
    const uint64_t base = flags & kPteAddrMask;
    if (gvmFbOffset != 0 && base == gvmFbOffset) flags &= ~kPteAddrMask;
    if ((flags & kPteSystem) == 0) addr = vramPhys(addr);
    return FunctionCast(wrapUpdatePtesDma, orgUpdatePtesDma)(ctx, pe, count, addr, flags, incr);
}

static mach_vm_address_t orgFillMapProcess = 0;

static uint32_t *wrapFillMapProcess(void *channel, uint32_t *packet, uint64_t context, uint64_t tba, uint32_t a, uint32_t b, uint32_t c)
{
    uint32_t *end = FunctionCast(wrapFillMapProcess, orgFillMapProcess)(channel, packet, context, tba, a, b, c);
    if (packet != nullptr) {
        uint64_t given = (static_cast<uint64_t>(packet[3]) << 32) | packet[2];
        uint64_t base = vramPhys(given & ~0xFFFULL) | (given & 0xFFF);
        packet[2] = static_cast<uint32_t>(base);
        packet[3] = static_cast<uint32_t>(base >> 32);
    }
    return end;
}

static mach_vm_address_t orgPrepareVmInvalidate = 0;

static void wrapPrepareVmInvalidate(void *vmm, uint32_t *request, const uint8_t *info, bool alt)
{
    FunctionCast(wrapPrepareVmInvalidate, orgPrepareVmInvalidate)(vmm, request, info, alt);
    if (request != nullptr && info != nullptr && info[0x24] != 0) {
        uint64_t given = (static_cast<uint64_t>(request[3]) << 32) | request[1];
        uint64_t base = vramPhys(given & ~0xFFFULL) | (given & 0xFFF);
        request[1] = static_cast<uint32_t>(base);
        request[3] = static_cast<uint32_t>(base >> 32);
    }
}

static void onKextLoaded(void *, KernelPatcher &patcher, size_t index, mach_vm_address_t address, size_t size)
{
    if (index == kextHWServices.loadIndex) {
        SYSLOG("ps5cyan", "HWServices loaded for 1002:13fc");
        KernelPatcher::RouteRequest r {"__ZN42AMDRadeonX6000_AMDRadeonHWServicesAbstract24createPowerPlayInterfaceEP18PowerPlayCallbacks", blockPowerPlay};
        if (!patcher.routeMultiple(index, &r, 1, address, size)) SYSLOG("ps5cyan", "HWServices::createPowerPlayInterface was not routed (%d)", patcher.getError());
    } else if (index == kextHWLibs.loadIndex) {
        SYSLOG("ps5cyan", "HWLibs loaded for 1002:13fc");
        KernelPatcher::RouteRequest r {"__ZN30AMDRadeonX6000_AMDRadeonHWLibs24createPowerPlayInterfaceEP18PowerPlayCallbacks", blockPowerPlay};
        if (!patcher.routeMultiple(index, &r, 1, address, size)) SYSLOG("ps5cyan", "HWLibs::createPowerPlayInterface was not routed (%d)", patcher.getError());
    } else if (index == kextAccel.loadIndex) {
        SYSLOG("ps5cyan", "AMDRadeonX6000 accelerator loaded for 1002:13fc");
        publishHdaGfx();
        KernelPatcher::RouteRequest r[] = {
            {"__ZN30AMDRadeonX6000_AMDAccelChannel22resetHardwareAndReplayEv", blockHangReset},
            {"__ZN26AMDRadeonX6000_AMDHardware13resetHardwareEjPj", blockHangReset},
            {"__ZN26AMDRadeonX6000_AMDHardware17dumpASICHangStateEb", blockHangReset},
            {"__ZN29AMDRadeonX6000_AMDAccelDevice15getHardwareInfoEP24_sAMD_GET_HW_INFO_VALUES", wrapAccelHwInfo, orgAccelHwInfo},
            {"__ZN26AMDRadeonX6000_AMDGFX10VMM11getPDEValueE15eAMD_VMPT_LEVELy", wrapGetPdeValue, orgGetPdeValue},
            {"__ZN26AMDRadeonX6000_AMDGFX10VMM11getPTEValueE15eAMD_VMPT_LEVELyN24AMDRadeonX6000_IAMDHWVMM10VmMapFlagsEj", wrapGetPteValue, orgGetPteValue},
            {"__ZN26AMDRadeonX6000_AMDGFX10VMM9decodePTEEyPyPb", wrapDecodePte, orgDecodePte},
            {"__ZN26AMDRadeonX6000_AMDGFX10VMM26prepareVMInvalidateRequestEP25AMD_VM_INVALIDATE_REQUESTPK22AMD_VM_INVALIDATE_INFOb", wrapPrepareVmInvalidate, orgPrepareVmInvalidate},
            {"__ZN29AMDRadeonX6000_AMDHWVMContext36updateContiguousPTEsWithDMAUsingAddrEyyyyy", wrapUpdatePtesDma, orgUpdatePtesDma},
            {"__ZN35AMDRadeonX6000_AMDGFX10HIQHWChannel20fillMapProcessPacketEP19PM4_MES_MAP_PROCESSyyjjj", wrapFillMapProcess, orgFillMapProcess}
        };
        for (auto &req : r) {
            if (!patcher.routeMultiple(index, &req, 1, address, size)) {
                SYSLOG("ps5cyan", "Failed to route accelerator hook %s (%d)", req.symbol, patcher.getError());
                patcher.clearError();
            } else {
                SYSLOG("ps5cyan", "Successfully routed accelerator hook %s", req.symbol);
            }
        }
    } else if (index == kextFB.loadIndex) {
        SYSLOG("ps5cyan", "AMDRadeonX6000Framebuffer loaded for 1002:13fc");
        publishHdaGfx();
        KernelPatcher::RouteRequest r[] = {
            {"__ZN27AMDRadeonX6000_AmdDalHelper34prepareDalDisplaySurfaceParametersEPK16AmdFbDisplayPathP20AmdFalconUpdatePlane", wrapPrepareSurface, orgPrepareSurface},
            {"__ZN27AMDRadeonX6000_AmdDalHelper17updateSurfaceInfoEPK20AmdFalconUpdatePlanePK16AmdFbDisplayPath", wrapUpdateSurfaceInfo, orgUpdateSurfaceInfo},
            {"__ZN27AMDRadeonX6000_AmdDalHelper14setCursorImageEPK21AmdFbCursorDescriptor", wrapSetCursorImage, orgSetCursorImage}
        };
        for (auto &req : r) {
            if (!patcher.routeMultiple(index, &req, 1, address, size)) {
                SYSLOG("ps5cyan", "Failed to route %s (%d)", req.symbol, patcher.getError());
                patcher.clearError();
            }
        }
        const mach_vm_address_t fn = findFunctionByString(address, size, kApplyPipeSplitFlags, sizeof(kApplyPipeSplitFlags));
        KernelPatcher::RouteRequest splitReq {nullptr, wrapApplyPipeSplitFlags, orgApplyPipeSplitFlags};
        splitReq.from = fn;
        if (fn == 0 || !patcher.routeMultiple(index, &splitReq, 1)) {
            SYSLOG("ps5cyan", "dcn20_validate_apply_pipe_split_flags not routed (%d)", patcher.getError());
            patcher.clearError();
        } else {
            SYSLOG("ps5cyan", "Routed dcn20_validate_apply_pipe_split_flags at 0x%llx", static_cast<unsigned long long>(fn));
        }
    }
}

static const char *bootargOff = "-ps5cyanoff";
static const char *bootargDebug = "-ps5cyandbg";
static const char *bootargBeta = "-ps5cyanbeta";

static void pluginStart()
{
    uint64_t vramMb = 0;
    if (PE_parse_boot_argn("-ps5vram", &vramMb, sizeof(vramMb)) && vramMb > 0) {
        gvmFbSize = vramMb << 20;
        gvmFbOffset = 0x470000000ULL - gvmFbSize;
    }
    PE_parse_boot_argn("-ps5vrambase", &gvmFbOffset, sizeof(gvmFbOffset));
    PE_parse_boot_argn("-ps5vramsize", &gvmFbSize, sizeof(gvmFbSize));
    PE_parse_boot_argn("-ps5vrammc", &gvmFbBase, sizeof(gvmFbBase));

    lilu.onKextLoadForce(&kextHWServices, 1, onKextLoaded);
    lilu.onKextLoadForce(&kextHWLibs, 1, onKextLoaded);
    lilu.onKextLoadForce(&kextAccel, 1, onKextLoaded);
    lilu.onKextLoadForce(&kextFB, 1, onKextLoaded);
}

PluginConfiguration ADDPR(config) {
    xStringify(PRODUCT_NAME),
    parseModuleVersion(xStringify(MODULE_VERSION)),
    LiluAPI::AllowNormal,
    &bootargOff, 1,
    &bootargDebug, 1,
    &bootargBeta, 1,
    KernelVersion::Monterey,
    KernelVersion::Monterey,
    pluginStart,
};
