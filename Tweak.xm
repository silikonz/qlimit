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
static BOOL _qlimitChargeInhibited = NO;

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

// ---- The actual control primitive ---------------------------------------

static void qlimit_setChargeInhibited(BOOL inhibited) {
    if (inhibited == _qlimitChargeInhibited) return;

    io_service_t service = IOServiceGetMatchingService(kIOMasterPortDefault, IOServiceMatching("IOPMPowerSource"));
    if (!service) return;

    NSDictionary *props = @{
        @"IsCharging": @YES,
        @"PredictiveChargingInhibit": @(inhibited)
    };
    kern_return_t kr = IORegistryEntrySetCFProperties(service, (__bridge CFDictionaryRef)props);
    if (kr == KERN_SUCCESS) {
        _qlimitChargeInhibited = inhibited;
    }
    IOObjectRelease(service);
}


// ---- Decision logic ---------------------------------------------------------

static void qlimit_evaluateChargingState(void) {
    CFDictionaryRef matching = IOServiceMatching("IOPMPowerSource");
    if (!matching) return;
    io_service_t service = IOServiceGetMatchingService(kIOMasterPortDefault, matching);
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

static void qlimit_powerSourceChangedCallback(void *context) {
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

// ---- Entry point ---------------------------------------------------------

%ctor {
    qlimit_loadPreferences();

    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                     NULL,
                                     qlimit_preferencesChangedCallback,
                                     CFSTR(kQLimitPrefsChangedNotification),
                                     NULL,
                                     CFNotificationSuspensionBehaviorDeliverImmediately);

    CFRunLoopSourceRef runLoopSource =
        IOPSNotificationCreateRunLoopSource((IOPowerSourceCallbackType)qlimit_powerSourceChangedCallback, NULL);
    if (runLoopSource) {
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, kCFRunLoopDefaultMode);
        CFRelease(runLoopSource);
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        qlimit_evaluateChargingState();
    });
}
