// SPDX-License-Identifier: MIT
// PS5Cyan, step 1: a Lilu plugin that keeps Apple's AMD stack away from the console's power controller.
//
// Monterey's AMDRadeonX6000 drives a Navi 10 through PowerPlay, which talks to an SMU/MP1 mailbox. On the PS5 that block belongs to Sony's
// firmware (clocks, fan), so nothing in macOS may ever send it a message. This plugin routes the two PowerPlay constructors to a stub that
// returns at once, which every later step (a personality for 1002:13fc, the memory and page-table fixes) depends on. Nothing here matches the
// GPU: the AMD kexts only load when something else claims the device, and until then no hook is installed.
//
// Boot arguments: -ps5cyanoff disables the plugin, -ps5cyandbg turns on its debug log.
#include <Headers/kern_api.hpp>
#include <Headers/kern_patcher.hpp>
#include <Headers/kern_util.hpp>
#include <Headers/plugin_start.hpp>

static const char *pathHWServices = "/System/Library/Extensions/AMDRadeonX6000HWServices.kext/Contents/MacOS/AMDRadeonX6000HWServices";
static const char *pathHWLibs = "/System/Library/Extensions/AMDRadeonX6000HWServices.kext/Contents/PlugIns/AMDRadeonX6000HWLibs.kext/Contents/MacOS/AMDRadeonX6000HWLibs";

static KernelPatcher::KextInfo kextHWServices {"com.apple.kext.AMDRadeonX6000HWServices", &pathHWServices, 1, {true}, {}, KernelPatcher::KextInfo::Unloaded};
static KernelPatcher::KextInfo kextHWLibs {"com.apple.kext.AMDRadeonX6000HWLibs", &pathHWLibs, 1, {true}, {}, KernelPatcher::KextInfo::Unloaded};

static uint32_t blockedPowerPlay = 0;

// Returns 0 without running Apple's function: no PowerPlay object is created, so no SMU message is ever built.
static long blockPowerPlay(void *, void *)
{
    blockedPowerPlay++;
    SYSLOG("ps5cyan", "PowerPlay interface blocked (%u)", blockedPowerPlay);
    return 0;
}

static void onKextLoaded(void *, KernelPatcher &patcher, size_t index, mach_vm_address_t address, size_t size)
{
    if (index == kextHWServices.loadIndex) {
        KernelPatcher::RouteRequest r {"__ZN42AMDRadeonX6000_AMDRadeonHWServicesAbstract24createPowerPlayInterfaceEP18PowerPlayCallbacks", blockPowerPlay};
        if (!patcher.routeMultiple(index, &r, 1, address, size)) SYSLOG("ps5cyan", "HWServices::createPowerPlayInterface was not routed (%d)", patcher.getError());
    } else if (index == kextHWLibs.loadIndex) {
        KernelPatcher::RouteRequest r {"__ZN30AMDRadeonX6000_AMDRadeonHWLibs24createPowerPlayInterfaceEP18PowerPlayCallbacks", blockPowerPlay};
        if (!patcher.routeMultiple(index, &r, 1, address, size)) SYSLOG("ps5cyan", "HWLibs::createPowerPlayInterface was not routed (%d)", patcher.getError());
    }
}

static const char *bootargOff = "-ps5cyanoff";
static const char *bootargDebug = "-ps5cyandbg";
static const char *bootargBeta = "-ps5cyanbeta";

static void pluginStart()
{
    lilu.onKextLoadForce(&kextHWServices, 1, onKextLoaded);
    lilu.onKextLoadForce(&kextHWLibs, 1, onKextLoaded);
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
