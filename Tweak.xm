#import <Foundation/Foundation.h>
#import <IOKit/IOKitLib.h>
#import <IOKit/ps/IOPowerSources.h>

// ---- Config ----------------------------------------------------------

#define kQLimitAppID                    CFSTR("me.qlimit")
#define kQLimitPrefsUser                CFSTR("mobile")
#define kQLimitMaxLevelKey              CFSTR("MaxChargingLevel")
#define kQLimitSailDepthKey             CFSTR("SailDepth")
#define kQLimitPrefsChangedNotification "me.qlimit/prefschanged"
#define kQLimitDefaultLevel             80
#define kQLimitDefaultSailDepth         5

// ---- State -------------------------------------------------------------

static int _qlimitMaxChargingLevel = kQLimitDefaultLevel;
static int _qlimitSailDepth = kQLimitDefaultSailDepth;

static IONotificationPortRef gNotifyPort = NULL;
static io_object_t gPowerNotification = IO_OBJECT_NULL;

// ---- Preferences ---------------------------------------------------------

static int qlimit_intPrefValue(CFStringRef key, int defaultValue) {
    id value = (__bridge_transfer id)CFPreferencesCopyValue(key, kQLimitAppID, kQLimitPrefsUser, kCFPreferencesCurrentHost);
    return value ? [value intValue] : defaultValue;
}

static void qlimit_loadPreferences(void) {
    CFPreferencesSynchronize(kQLimitAppID, kQLimitPrefsUser, kCFPreferencesCurrentHost);
    _qlimitMaxChargingLevel = qlimit_intPrefValue(kQLimitMaxLevelKey, kQLimitDefaultLevel);
    _qlimitSailDepth = qlimit_intPrefValue(kQLimitSailDepthKey, kQLimitDefaultSailDepth);
}

// ---- Service Resolver ------------------------------

static io_service_t qlimit_getPowerService(void) {
    // Try AppleSmartBattery first (iPhone 8 and newer hardware driver)
    io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"));
    if (!service) {
        // Fallback to IOPMPowerSource for older devices
        service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMPowerSource"));
    }
    return service;
}

// ---- Control Primitives --------------------------------------------------

static void qlimit_setChargeInhibited(BOOL inhibited) {
    io_service_t service = qlimit_getPowerService();
    if (!service) return;

    NSDictionary *props = @{
        @"IsCharging": @YES,
        @"PredictiveChargingInhibit": @(inhibited)
    };

    IORegistryEntrySetCFProperties(service, (__bridge CFDictionaryRef)props);
    IOObjectRelease(service);
}

// ---- Decision logic ---------------------------------------------------------

static void qlimit_evaluateChargingState(void) {
    io_service_t service = qlimit_getPowerService();
    if (!service) return;

    CFBooleanRef externalConnected = (CFBooleanRef)IORegistryEntryCreateCFProperty(
        service, CFSTR("ExternalConnected"), kCFAllocatorDefault, 0);
    CFNumberRef capNum = (CFNumberRef)IORegistryEntryCreateCFProperty(
        service, CFSTR("CurrentCapacity"), kCFAllocatorDefault, 0);

    IOObjectRelease(service);

    if (externalConnected && capNum) {
        BOOL isPluggedIn = CFBooleanGetValue(externalConnected);

        int capacity = 0;
        CFNumberGetValue(capNum, kCFNumberIntType, &capacity);

        if (!isPluggedIn) {
            qlimit_setChargeInhibited(NO);
        } else if (capacity >= _qlimitMaxChargingLevel) {
            qlimit_setChargeInhibited(YES);
        } else if (capacity <= (_qlimitMaxChargingLevel - _qlimitSailDepth)) {
            qlimit_setChargeInhibited(NO);
        }
    }

    if (externalConnected) CFRelease(externalConnected);
    if (capNum) CFRelease(capNum);
}

// ---- Callbacks ---------------------------------------------------------

static void qlimit_powerSourceChangedCallback(void *refcon, io_service_t service, uint32_t messageType, void *messageArgument) {
    qlimit_evaluateChargingState();
}

static void qlimit_preferencesChangedCallback(CFNotificationCenterRef center,
                                               void *observer,
                                               CFStringRef name,
                                               const void *object,
                                               CFDictionaryRef userInfo) {
    qlimit_loadPreferences();
    qlimit_evaluateChargingState();
}

// ---- Setup Low-Level Hook ------------

static void qlimit_setupIOKitNotification(void) {
    gNotifyPort = IONotificationPortCreate(kIOMainPortDefault);
    if (!gNotifyPort) return;

    CFRunLoopSourceRef runSrc = IONotificationPortGetRunLoopSource(gNotifyPort);
    CFRunLoopAddSource(CFRunLoopGetCurrent(), runSrc, kCFRunLoopDefaultMode);

    io_service_t serv = qlimit_getPowerService();
    if (serv != IO_OBJECT_NULL) {
        IOServiceAddInterestNotification(
            gNotifyPort, 
            serv, 
            "IOGeneralInterest", 
            (IOServiceInterestCallback)qlimit_powerSourceChangedCallback, 
            NULL, 
            &gPowerNotification
        );
        IOObjectRelease(serv);
    }
}

// ---- Entry point ---------------------------------------------------------

%ctor {
    qlimit_loadPreferences();

    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                     NULL,
                                     qlimit_preferencesChangedCallback,
                                     CFSTR(kQLimitPrefsChangedNotification),
                                     NULL,
                                     CFNotificationSuspensionBehaviorDeliverImmediately);

    qlimit_setupIOKitNotification();

    dispatch_async(dispatch_get_main_queue(), ^{
        qlimit_evaluateChargingState();
    });
}
