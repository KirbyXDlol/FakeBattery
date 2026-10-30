// FakeBatteryDriver.cpp
//
// Publishes a fake battery (an IOPMPowerSource) so macOS believes a battery exists.
// The state (percentage, charging, ...) is set from user space by the FakeBattery app
// through IORegistryEntrySetCFProperties() on the "FakeBatteryManager" service.
//
// Accepted properties (all optional):
//   FBPercent        number   0..100
//   FBCharging       boolean  power adapter connected / charging
//   FBTimeRemaining  number   minutes, or 65535 for "no estimate"
//   FBFloor          number   lowest percentage ever shown to macOS (safety, default 3)
//
// NOTE: this driver never raises the kernel's "warn level" / "critical level" flags.

#include <mach/mach_types.h>
#include <IOKit/IOLib.h>
#include <IOKit/IOLocks.h>
#include <IOKit/IOService.h>
#include <IOKit/pwr_mgt/IOPMPowerSource.h>
#include <libkern/c++/OSBoolean.h>
#include <libkern/c++/OSDictionary.h>
#include <libkern/c++/OSNumber.h>
#include <libkern/c++/OSSymbol.h>

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

static void addNumber(OSDictionary *dict, const char *key, unsigned long long value)
{
    OSNumber *num = OSNumber::withNumber(value, 32);
    if (num) {
        dict->setObject(key, num);
        num->release();
    }
}

// ---------------------------------------------------------------------------
// The fake battery itself
// ---------------------------------------------------------------------------

class FakeBatterySource : public IOPMPowerSource
{
    OSDeclareDefaultStructors(FakeBatterySource)

public:
    static FakeBatterySource *create(IOService *parent);
    void applyState(uint32_t percent, bool charging, uint32_t timeRemaining);

private:
    void putNumber(const char *key, unsigned long long value);
    void putBool(const char *key, bool value);
};

OSDefineMetaClassAndStructors(FakeBatterySource, IOPMPowerSource)

FakeBatterySource *FakeBatterySource::create(IOService *parent)
{
    FakeBatterySource *src = OSTypeAlloc(FakeBatterySource);
    if (!src) return nullptr;

    if (!src->init() || !src->attach(parent)) {
        src->release();
        return nullptr;
    }
    if (!src->start(parent)) {
        src->detach(parent);
        src->release();
        return nullptr;
    }
    src->registerService();
    return src;
}

void FakeBatterySource::putNumber(const char *key, unsigned long long value)
{
    const OSSymbol *sym = OSSymbol::withCString(key);
    OSNumber *num = OSNumber::withNumber(value, 64);
    if (sym && num) setPSProperty(sym, num);
    if (num) num->release();
    if (sym) sym->release();
}

void FakeBatterySource::putBool(const char *key, bool value)
{
    const OSSymbol *sym = OSSymbol::withCString(key);
    if (sym) {
        setPSProperty(sym, value ? kOSBooleanTrue : kOSBooleanFalse);
        sym->release();
    }
}

void FakeBatterySource::applyState(uint32_t percent, bool charging, uint32_t timeRemaining)
{
    const bool full = charging && percent >= 100;
    const int amperage = charging ? (full ? 0 : 1500) : -1000;
    const uint32_t voltage = 12000;

    setBatteryInstalled(true);
    setExternalConnected(charging);
    setExternalChargeCapable(charging);
    setIsCharging(charging && !full);

    // Never ask the system for emergency behaviour on low charge.
    setAtWarnLevel(false);
    setAtCriticalLevel(false);

    setMaxCapacity(100);
    setCurrentCapacity(percent);
    setTimeRemaining((int)timeRemaining);
    setAmperage(amperage);
    setVoltage(voltage);
    setCycleCount(1);
    setLocation(0);
    putNumber("DesignCapacity", 100);
    putBool("FullyCharged", full);

    // Legacy "IOBatteryInfo" dictionary, still read by some parts of the system.
    OSDictionary *legacy = OSDictionary::withCapacity(8);
    if (legacy) {
        const uint32_t flags = (charging ? 1u : 0u) | ((charging && !full) ? 2u : 0u) | 4u;
        addNumber(legacy, "Flags", flags);
        addNumber(legacy, "Capacity", 100);
        addNumber(legacy, "Current", percent);
        addNumber(legacy, "Voltage", voltage);
        addNumber(legacy, "Amperage", (uint32_t)amperage);
        addNumber(legacy, "Cycle Count", 1);
        setLegacyIOBatteryInfo(legacy);
        legacy->release();
    }

    updateStatus();
}

// ---------------------------------------------------------------------------
// The service the user-space app talks to
// ---------------------------------------------------------------------------

class FakeBatteryManager : public IOService
{
    OSDeclareDefaultStructors(FakeBatteryManager)

public:
    virtual bool init(OSDictionary *dict = nullptr) override;
    virtual void free() override;
    virtual bool start(IOService *provider) override;
    virtual void stop(IOService *provider) override;
    virtual IOReturn setProperties(OSObject *properties) override;

private:
    void publish();   // caller must hold `lock`

    FakeBatterySource *source;
    IOLock *lock;
    uint32_t percent;
    bool charging;
    uint32_t timeRemaining;
    uint32_t floorPercent;
};

OSDefineMetaClassAndStructors(FakeBatteryManager, IOService)

bool FakeBatteryManager::init(OSDictionary *dict)
{
    if (!IOService::init(dict)) return false;
    source = nullptr;
    percent = 80;
    charging = false;
    timeRemaining = 0xFFFF;
    floorPercent = 3;
    lock = IOLockAlloc();
    return lock != nullptr;
}

void FakeBatteryManager::free()
{
    if (lock) {
        IOLockFree(lock);
        lock = nullptr;
    }
    IOService::free();
}

bool FakeBatteryManager::start(IOService *provider)
{
    if (!IOService::start(provider)) return false;

    source = FakeBatterySource::create(this);
    if (!source) {
        IOService::stop(provider);
        return false;
    }

    IOLockLock(lock);
    publish();
    IOLockUnlock(lock);

    registerService();   // lets user space find "FakeBatteryManager"
    return true;
}

void FakeBatteryManager::stop(IOService *provider)
{
    if (source) {
        source->stop(this);
        source->detach(this);
        source->release();
        source = nullptr;
    }
    IOService::stop(provider);
}

void FakeBatteryManager::publish()
{
    if (!source) return;

    uint32_t shown = percent > 100 ? 100 : percent;
    if (shown < floorPercent) shown = floorPercent;
    source->applyState(shown, charging, timeRemaining);

    // Visible with: ioreg -rc FakeBatteryManager
    setProperty("FBPercent", (unsigned long long)percent, 32);
    setProperty("FBCharging", charging);
    setProperty("FBFloor", (unsigned long long)floorPercent, 32);
}

IOReturn FakeBatteryManager::setProperties(OSObject *properties)
{
    OSDictionary *dict = OSDynamicCast(OSDictionary, properties);
    if (!dict) return kIOReturnBadArgument;

    IOLockLock(lock);

    if (OSNumber *n = OSDynamicCast(OSNumber, dict->getObject("FBPercent")))
        percent = n->unsigned32BitValue();
    if (OSBoolean *b = OSDynamicCast(OSBoolean, dict->getObject("FBCharging")))
        charging = b->isTrue();
    if (OSNumber *n = OSDynamicCast(OSNumber, dict->getObject("FBTimeRemaining")))
        timeRemaining = n->unsigned32BitValue();
    if (OSNumber *n = OSDynamicCast(OSNumber, dict->getObject("FBFloor"))) {
        floorPercent = n->unsigned32BitValue();
        if (floorPercent > 50) floorPercent = 50;
    }

    publish();
    IOLockUnlock(lock);
    return kIOReturnSuccess;
}

// ---------------------------------------------------------------------------
// Kext module boilerplate (what Xcode normally generates)
// ---------------------------------------------------------------------------

extern "C" {
extern kern_return_t _start(kmod_info_t *ki, void *data);
extern kern_return_t _stop(kmod_info_t *ki, void *data);

__attribute__((visibility("default")))
KMOD_EXPLICIT_DECL(com.local.FakeBatteryDriver, "1.0.0", _start, _stop)
__attribute__((visibility("default"))) kmod_start_func_t *_realmain = nullptr;
__attribute__((visibility("default"))) kmod_stop_func_t *_antimain = nullptr;
__attribute__((visibility("default"))) int _kext_apple_cc = __APPLE_CC__;
}
