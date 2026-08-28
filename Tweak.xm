#import <Foundation/Foundation.h>
#import <IOKit/IOKitLib.h>
#import <IOKit/ps/IOPowerSources.h>
#import <IOKit/pwr_mgt/IOPMLib.h>
#import <rootless.h>

// ---- Config ----------------------------------------------------------

#define kQLimitPrefsPath                ROOT_PATH_NS(@"/var/mobile/Library/Preferences/me.qlimit.plist")
#define kQLimitPrefsChangedNotification "me.qlimit/prefschanged"
#define kQLimitDefaultLevel             80

// ---- State -------------------------------------------------------------

static int _qlimitMaxChargingLevel = kQLimitDefaultLevel;
static BOOL _qlimitChargeInhibited = NO;
static IOPMAssertionID _qlimitAssertionID = kIOPMNullAssertionID;

// ---- Preferences ---------------------------------------------------------

// ROOT_PATH_NS resolves to the right prefix at compile time depending on
// THEOS_PACKAGE_SCHEME, so this is the same file the prefs bundle writes to
// on both rootful and rootless.
static void qlimit_loadPreferences(void) {
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:kQLimitPrefsPath];
    _qlimitMaxChargingLevel = prefs[@"MaxChargingLevel"] ? [prefs[@"MaxChargingLevel"] intValue] : kQLimitDefaultLevel;
}

// ---- Battery state ---------------------------------------------------------

static NSDictionary *qlimit_currentBatteryInfo(void) {
    CFDictionaryRef matching = IOServiceMatching("IOPMPowerSource");
    io_service_t service = IOServiceGetMatchingService(kIOMasterPortDefault, matching);
    if (!service) return nil;

    CFMutableDictionaryRef properties = NULL;
    IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0);
    IOObjectRelease(service);

    return (__bridge_transfer NSDictionary *)properties;
}

// ---- The actual control primitive ---------------------------------------

static void qlimit_setChargeInhibited(BOOL inhibited) {
    if (inhibited == _qlimitChargeInhibited) return;

    if (inhibited) {
        IOReturn result = IOPMAssertionCreateWithName(CFSTR("ChargeInhibit"),
                                                        kIOPMAssertionLevelOn,
                                                        CFSTR("QLimit active"),
                                                        &_qlimitAssertionID);
        if (result == kIOReturnSuccess) {
            _qlimitChargeInhibited = YES;
        }
    } else {
        if (_qlimitAssertionID != kIOPMNullAssertionID) {
            IOPMAssertionRelease(_qlimitAssertionID);
            _qlimitAssertionID = kIOPMNullAssertionID;
        }
        _qlimitChargeInhibited = NO;
    }
}

// ---- Decision logic ---------------------------------------------------------

static void qlimit_evaluateChargingState(void) {
    NSDictionary *info = qlimit_currentBatteryInfo();
    if (!info) return;

    BOOL externalConnected = [info[@"ExternalConnected"] boolValue];
    int currentCapacity = [info[@"CurrentCapacity"] intValue];

    if (externalConnected && currentCapacity >= _qlimitMaxChargingLevel) {
        qlimit_setChargeInhibited(YES);
    } else {
        qlimit_setChargeInhibited(NO);
    }
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
    @autoreleasepool {
        qlimit_loadPreferences();

        // The prefs bundle uses the standard Preferences.framework
        // "PostNotification" specifier key, which posts this Darwin
        // notification automatically whenever the value is saved.
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                         NULL,
                                         qlimit_preferencesChangedCallback,
                                         CFSTR(kQLimitPrefsChangedNotification),
                                         NULL,
                                         CFNotificationSuspensionBehaviorDeliverImmediately);

        // Fires on plug/unplug and on every percentage tick.
        CFRunLoopSourceRef runLoopSource =
            IOPSNotificationCreateRunLoopSource((IOPowerSourceCallbackType)qlimit_powerSourceChangedCallback, NULL);
        if (runLoopSource) {
            CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, kCFRunLoopDefaultMode);
            CFRelease(runLoopSource);
        }

        qlimit_evaluateChargingState();
    }
}
