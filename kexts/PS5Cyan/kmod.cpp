// The kmod_info record of a Lilu plugin; Xcode normally generates this file. The start and stop functions come from Lilu's plugin_start.cpp.
#include <mach/mach_types.h>

extern "C" {
extern kern_return_t _start(kmod_info_t *ki, void *data);
extern kern_return_t _stop(kmod_info_t *ki, void *data);
extern kern_return_t PS5Cyan_kern_start(kmod_info_t *ki, void *data);
extern kern_return_t PS5Cyan_kern_stop(kmod_info_t *ki, void *data);

__attribute__((visibility("default"))) KMOD_EXPLICIT_DECL(local.ps5.driver.PS5Cyan, "0.1.0", _start, _stop)
__attribute__((visibility("default"))) kmod_start_func_t *_realmain = PS5Cyan_kern_start;
__attribute__((visibility("default"))) kmod_stop_func_t *_antimain = PS5Cyan_kern_stop;
__attribute__((visibility("default"))) int _kext_apple_cc = __APPLE_CC__;
}
