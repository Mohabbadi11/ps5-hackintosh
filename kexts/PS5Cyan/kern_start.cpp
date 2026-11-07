#include <Headers/kern_api.hpp>
#include <Headers/kern_patcher.hpp>
#include <Headers/kern_util.hpp>
#include <Headers/plugin_start.hpp>

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
        KernelPatcher::RouteRequest r[] = {
            {"__ZN30AMDRadeonX6000_AMDAccelChannel22resetHardwareAndReplayEv", blockHangReset},
            {"__ZN26AMDRadeonX6000_AMDHardware13resetHardwareEjPj", blockHangReset},
            {"__ZN26AMDRadeonX6000_AMDHardware17dumpASICHangStateEb", blockHangReset}
        };
        patcher.routeMultiple(index, r, 3, address, size);
    } else if (index == kextFB.loadIndex) {
        SYSLOG("ps5cyan", "AMDRadeonX6000Framebuffer loaded for 1002:13fc");
    }
}

static const char *bootargOff = "-ps5cyanoff";
static const char *bootargDebug = "-ps5cyandbg";
static const char *bootargBeta = "-ps5cyanbeta";

static void pluginStart()
{
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
