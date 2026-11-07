// Minimal stand-ins for the IOKit/libkern pieces PS5Power.cpp uses, so it compiles with g++ on Linux and can be driven against a
// simulated ICC mailbox (test_ps5power.cpp). Only what that file touches; behaviour is faked, signatures follow the macOS SDK.
#pragma once
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <cstdarg>
typedef uint32_t IOOptionBits;
typedef uint64_t IOByteCount;
typedef int IOReturn;
typedef void *task_t;
static task_t kernel_task = nullptr;
enum { kIODirectionNone = 0, kIOMapAnywhere = 1, kIOMapInhibitCache = 2 };
#define kIOMessageSystemWillPowerOff 0xe0000250u
#define kIOMessageSystemWillRestart  0xe0000310u
#define kIOMessageSystemWillSleep    0xe0000280u
#define kIOPMPowerStateVersion1 1
#define kIOPMPowerOn 2
struct IOPMPowerState { unsigned long version, capabilityFlags, outputPowerCharacter, inputPowerRequirement, staticPower, unbudgetedPower,
                        powerToAttain, timeToAttain, settleUpTime, timeToLower, settleDownTime, powerDomainBudget; };
extern char g_log[65536];
inline void IOLog(const char *fmt, ...) { va_list a; va_start(a, fmt); size_t n = strlen(g_log); vsnprintf(g_log + n, sizeof(g_log) - n, fmt, a); va_end(a); }
void IODelay(unsigned us);            // the simulated device ticks here (test file)
inline void IOSleep(unsigned) {}
inline uint32_t OSReadLittleInt32(volatile void *b, uintptr_t o) { return *(volatile uint32_t *)((volatile uint8_t *)b + o); }
inline uint16_t OSReadLittleInt16(volatile void *b, uintptr_t o) { return *(volatile uint16_t *)((volatile uint8_t *)b + o); }
void OSWriteLittleInt32(volatile void *b, uintptr_t o, uint32_t v);   // test file: records doorbell writes
inline void OSWriteLittleInt16(volatile void *b, uintptr_t o, uint16_t v) { *(volatile uint16_t *)((volatile uint8_t *)b + o) = v; }

struct OSObject { virtual ~OSObject() {} void release() {} void retain() {} };
struct OSBoolean : OSObject { bool v; explicit OSBoolean(bool b) : v(b) {} bool getValue() const { return v; } };
template <class T> T *osCast(OSObject *o) { return dynamic_cast<T *>(o); }
#define OSDynamicCast(T, o) osCast<T>(o)
#define OSDeclareDefaultStructors(c) public:
#define OSDefineMetaClassAndStructors(c, s)

struct IOMemoryMap : OSObject { uint8_t *va; uint64_t len; uint64_t getVirtualAddress() { return (uint64_t)(uintptr_t)va; } };
IOMemoryMap *fakeMap(uint64_t phys, uint64_t len);   // test file
struct IOMemoryDescriptor : OSObject {
    uint64_t phys, len;
    static IOMemoryDescriptor *withPhysicalAddress(uint64_t p, uint64_t l, int) { auto *m = new IOMemoryDescriptor; m->phys = p; m->len = l; return m; }
    IOMemoryMap *createMappingInTask(task_t, uint64_t, int) { return fakeMap(phys, len); }
};
struct IOService : OSObject {
    OSObject *props[8] = {}; const char *names[8] = {};
    virtual bool start(IOService *) { return true; }
    virtual void stop(IOService *) {}
    virtual void systemWillShutdown(IOOptionBits);
    OSObject *getProperty(const char *k) { for (int i = 0; i < 8; i++) if (names[i] && !strcmp(names[i], k)) return props[i]; return nullptr; }
    bool setProperty(const char *k, bool v) { for (int i = 0; i < 8; i++) if (!names[i] || !strcmp(names[i], k)) { names[i] = k; props[i] = new OSBoolean(v); return true; } return false; }
    void PMinit() {} void PMstop() {} void registerService() {}
    IOReturn registerPowerDriver(IOService *, IOPMPowerState *, unsigned long) { return 0; }
    void joinPMtree(IOService *) {}
};
struct IOPCIDevice : IOService { uint16_t rid = 0; uint16_t extendedConfigRead16(uint32_t) { return rid; } };
