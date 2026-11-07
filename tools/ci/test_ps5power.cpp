// Drives kexts/PS5Power/PS5Power.cpp (compiled against kstub/) through a simulated Salina glue function: the real-config window,
// BAR2's doorbell block and BAR4's ICC mailbox. The simulated controller answers each query like the EMC does (reply flag, interrupt
// status), and the test compares every message byte for byte with what the ps5-linux code (drivers/ps5/spcie.c) would send.
#include "kstub/kstub.h"
#include <vector>
#include <string>
char g_log[65536];

static const uint64_t BAR2 = 0x85200000ULL, BAR4 = 0x85400000ULL;
static uint8_t ecam[0x1000], bell[0x1000], icc[0x1000];
static uint32_t cfg[64];                 // the real glue function's config space (dwords)
static std::vector<std::vector<uint8_t>> sent;
static int acks, notifsToSend, mode;     // mode 0: answer, 1: never answer
static bool badBars, replyPending, badMailbox;
static int selects, flipAfter = -1;     // flipAfter: change BAR4 after that many window selects (another kext in the window)
static int maskWrites;

IOMemoryMap *fakeMap(uint64_t phys, uint64_t len)
{
    auto *m = new IOMemoryMap; m->len = len;
    if (phys == 0xF0000000ULL) m->va = ecam;
    else if (phys == BAR2 + 0x108000) m->va = bell;
    else if (phys == BAR4) m->va = icc;
    else { printf("unexpected map of %llx\n", (unsigned long long)phys); m->va = nullptr; }
    return m->va ? m : nullptr;
}

void OSWriteLittleInt32(volatile void *b, uintptr_t o, uint32_t v)
{
    volatile uint8_t *p = (volatile uint8_t *)b;
    if (p == ecam && (o == 0xd80 || o == 0xd00)) {           // window select: expose 0x80 bytes of the selected function's config
        uint32_t reg = v & 0xf80, base = (o == 0xd80) ? 0xf80 : 0xf00;
        if (++selects == flipAfter) cfg[0x20 / 4] ^= 0x00100000;
        for (uint32_t i = 0; i < 0x80; i += 4) *(uint32_t *)(ecam + base + i) = (reg + i) / 4 < 64 ? cfg[(reg + i) / 4] : 0xffffffff;
        return;
    }
    if (p == bell && o == 0x14) { *(uint32_t *)(bell + 0x14) &= ~v; return; }   // interrupt status: write 1 to clear
    if (p == bell && o == 0x04 && v == 2) { acks++; return; }
    if (p == bell && o == 0x24) maskWrites++;
    *(volatile uint32_t *)(p + o) = v;
}

void IODelay(unsigned)                    // the controller: on a SEND doorbell take the query, then post notifications and the reply
{
    uint32_t &door = *(uint32_t *)(bell + 0x04), &st = *(uint32_t *)(bell + 0x14);
    if (door == 1) {
        door = 0;
        uint16_t len = *(uint16_t *)(icc + 8);
        if (*(uint16_t *)(icc + 0x7f0) != 1) printf("SOW was not set before the doorbell\n");
        sent.emplace_back(icc, icc + len);
        if (mode == 1) return;
        replyPending = true;              // delivered once the notifications are out
    }
    if (replyPending && !(st & 1)) {
        uint16_t type = notifsToSend > 0 ? 0x8000 : 0x4000;
        if (notifsToSend > 0) notifsToSend--; else replyPending = false;
        memset(icc + 0x800, 0, 0x20);
        icc[0x800] = 0x42; icc[0x801] = sent.back()[1];
        *(uint16_t *)(icc + 0x802) = type | (*(uint16_t *)(sent.back().data() + 2));
        *(uint16_t *)(icc + 0x808) = 0x20;
        *(uint16_t *)(icc + 0xff0) = 1;   // EMW: the controller wrote a message
        st |= 1;
    }
}

bool superAcked;
void IOService::systemWillShutdown(IOOptionBits) { superAcked = true; }

#include "../../kexts/PS5Power/PS5Power.cpp"

// what drivers/ps5/spcie.c sends: struct icc_msg with magic 0x42, unk_04 3, length 0x20, checksum over the 32 bytes (checksum 0)
static std::vector<uint8_t> linuxMsg(uint8_t service, uint16_t type, std::vector<uint8_t> data, uint16_t id)
{
    std::vector<uint8_t> m(0x20, 0);
    m[0] = 0x42; m[1] = service; *(uint16_t *)&m[2] = type; *(uint16_t *)&m[4] = 3; *(uint16_t *)&m[6] = id; *(uint16_t *)&m[8] = 0x20;
    for (size_t i = 0; i < data.size(); i++) m[12 + i] = data[i];
    uint16_t sum = 0; for (auto b : m) sum += b; *(uint16_t *)&m[10] = sum;
    return m;
}

static int pass, fail;
static void check(bool ok, const char *what) { printf("%s %s\n", ok ? "PASS" : "FAIL", what); (ok ? pass : fail)++; }

static PS5Power *boot(uint16_t rid, bool dry, bool enabled = true)
{
    memset(ecam, 0, sizeof ecam); memset(bell, 0, sizeof bell); memset(icc, 0, sizeof icc); memset(cfg, 0xff, sizeof cfg);
    g_log[0] = 0; sent.clear(); acks = 0; superAcked = false; replyPending = false; selects = 0; maskWrites = 0;
    if (!badBars) {
        cfg[0x18 / 4] = (uint32_t)BAR2 | 0x4; cfg[0x1c / 4] = (uint32_t)(BAR2 >> 32);      // 64-bit, non-prefetchable
        cfg[0x20 / 4] = (uint32_t)BAR4 | 0xc; cfg[0x24 / 4] = (uint32_t)(BAR4 >> 32);      // 64-bit, prefetchable
    }
    *(uint32_t *)(bell + 0x24) = 3; *(uint32_t *)(bell + 0x14) = 2;                        // Linux left the mask on and a stale ACK
    if (badMailbox) *(uint16_t *)(icc + 0x7f4) = 0xbeef;
    auto *pci = new IOPCIDevice; pci->rid = rid;
    auto *d = new PS5Power;
    d->setProperty("DryRun", dry); d->setProperty("Enabled", enabled);
    return d->start(pci) ? d : nullptr;
}

int main()
{
    // shut down, the glue's real bus 32 window and bus 1 window
    for (uint16_t rid : {(uint16_t)0x2001, (uint16_t)0x0101}) {
        mode = 0; notifsToSend = 0;
        PS5Power *d = boot(rid, false);
        char t[128]; snprintf(t, sizeof t, "starts with the real BARs read through the window (rid %04x)", rid);
        check(d != nullptr && strstr(g_log, "real BAR2 85200000, BAR4 85400000"), t);
        if (!d) continue;
        d->systemWillShutdown(kIOMessageSystemWillPowerOff);
        bool three = sent.size() == 3;
        check(three, "Shut Down sends three ICC messages (two cpu-info-bit clears, then the power message)");
        if (three) {
            uint16_t id0 = *(uint16_t *)&sent[0][6];
            check(sent[0] == linuxMsg(2, 0x10, {0, 0}, id0), "message 1 = icc_configuration_set_cpu_info_bit({0,0}), byte for byte");
            check(sent[1] == linuxMsg(2, 0x10, {1, 0}, id0 + 1), "message 2 = icc_configuration_set_cpu_info_bit({0,1}), byte for byte");
            check(sent[2] == linuxMsg(4, 1, {0, 0, 2, 0, 1, 0, 0, 0, 0}, id0 + 2), "message 3 = icc_power_shutdown, byte for byte");
        }
        check(*(uint32_t *)(bell + 0x24) == 0, "the ICC interrupt mask is cleared before sending (polled)");
        check(acks == 3 && *(uint16_t *)(icc + 0xff4) == 1 && *(uint16_t *)(icc + 0xff0) == 0, "each reply acknowledged (EMW 0, EMR 1, ACK doorbell)");
        check(superAcked, "systemWillShutdown is passed on to IOService");
    }
    { mode = 0; notifsToSend = 0; PS5Power *d = boot(0x2001, false);
      d->systemWillShutdown(kIOMessageSystemWillRestart);
      check(sent.size() == 3 && sent[2] == linuxMsg(4, 1, {0, 1, 2, 0, 1, 0, 0, 0, 0}, *(uint16_t *)&sent[2][6]), "Restart sends icc_power_reboot, byte for byte"); }
    { mode = 0; notifsToSend = 2; PS5Power *d = boot(0x2001, false);
      d->systemWillShutdown(kIOMessageSystemWillPowerOff);
      check(sent.size() == 3 && acks == 5, "notifications arriving before a reply are acknowledged and skipped (2 extra ACKs)"); }
    { mode = 0; notifsToSend = 0; PS5Power *d = boot(0x2001, true);
      d->systemWillShutdown(kIOMessageSystemWillPowerOff);
      check(sent.empty() && strstr(g_log, "DryRun, not sent") && superAcked && maskWrites == 0 && *(uint32_t *)(bell + 0x24) == 3,
            "DryRun: logs the three queries, writes nothing at all (not even the interrupt mask), shutdown goes on"); }
    { mode = 0; PS5Power *d = boot(0x2001, false);
      d->systemWillShutdown(kIOMessageSystemWillSleep);
      check(sent.empty() && superAcked, "any other message (sleep): nothing sent"); }
    { mode = 1; PS5Power *d = boot(0x2001, false);
      d->systemWillShutdown(kIOMessageSystemWillPowerOff);
      check(sent.size() == 2 && strstr(g_log, "no reply within 2000 ms") && strstr(g_log, "sending the power message anyway") && strstr(g_log, "no reply within 5000 ms") && superAcked,
            "controller never answers: the power message is still sent, then it gives up and shutdown goes on"); }
    { badBars = true; PS5Power *d = boot(0x2001, false); badBars = false;
      check(d == nullptr && strstr(g_log, "could not read the glue function's real BARs"), "real BARs unreadable: does not attach (no guessed address)"); }
    { PS5Power *d = boot(0xffff, false);
      check(d == nullptr, "no requester id: does not attach"); }
    { PS5Power *d = boot(0x2001, false, false);
      check(d == nullptr && strstr(g_log, "Enabled = false"), "Enabled = false in the personality: does not attach"); }
    { mode = 0; notifsToSend = 0; PS5Power *d = boot(0x2001, false);
      // the controller posted a notification while Linux was being replaced and nobody acknowledged it: EMW = 1, no interrupt status
      icc[0x800] = 0x42; *(uint16_t *)(icc + 0x802) = 0x8001; *(uint16_t *)(icc + 0xff0) = 1; *(uint32_t *)(bell + 0x14) = 0;
      d->systemWillShutdown(kIOMessageSystemWillPowerOff);
      check(sent.size() == 3 && acks == 4 && strstr(g_log, "unacknowledged message from the controller"), "an unacknowledged controller message is acknowledged before the first query"); }
    { flipAfter = 9; PS5Power *d = boot(0x2001, false); flipAfter = -1;
      check(d == nullptr && strstr(g_log, "not trusted"), "BAR read changes between its first and second read (window shared with PS5SalinaGbE): not trusted, does not attach"); }
    { flipAfter = 11; PS5Power *d = boot(0x2001, false); flipAfter = -1;
      check(d == nullptr && strstr(g_log, "not trusted"), "BAR changes on the last of the three reads: still caught"); }
    { mode = 0; PS5Power *d = boot(0x2001, false);
      check(d != nullptr && selects >= 12, "each BAR half is read three times (12+ window selects)"); }
    // wrong mapping: mailbox flags that are not 0/1
    { memset(icc, 0, sizeof icc); PS5Power *d = nullptr;
      badMailbox = true; d = boot(0x2001, false); badMailbox = false;
      check(d == nullptr && strstr(g_log, "do not look like the ICC mailbox"), "registers that are not the ICC mailbox (flags not 0/1): does not attach"); }
    printf("PS5Power tests: %d passed, %d failed\n", pass, fail);
    return fail != 0;
}
