#import <Foundation/Foundation.h>
#import <IOKit/IOKitLib.h>
#import <IOKit/ps/IOPowerSources.h>
#import <IOKit/pwr_mgt/IOPMLib.h>
#import <rootless.h>

// ---- Config ----------------------------------------------------------

#define kQLimitPrefsPath                ROOT_PATH_NS(@"/var/mobile/Library/Preferences/me.qlimit.plist")
#define kQLimitPrefsChangedNotification "me.qlimit/prefschanged"
#define kQLimitDefaultLevel             80
#define kQLimitDefaultSailDepth         5   // mirrors AlDente's Sailing Mode: lets the battery buffer small
                                             // draws for a while instead of topping up on every point drop,
                                             // meaning fewer partial charge cycles

// ---- State -------------------------------------------------------------

static int _qlimitMaxChargingLevel = kQLimitDefaultLevel;
static int _qlimitSailDepth = kQLimitDefaultSailDepth;
static BOOL _qlimitChargeInhibited = NO;
static IOPMAssertionID _qlimitAssertionID = kIOPMNullAssertionID;

// ---- Preferences ---------------------------------------------------------

// The prefs bundle uses PSListController's own default persistence (no
// custom setPreferenceValue:/readPreferenceValue: override), which goes
// through CFPreferences/cfprefsd under the "me.qlimit" domain set as
// Root.plist's top-level "defaults" key - so we read it back the same way.
// powerd doesn't run as `mobile`, so the user has to be named explicitly -
// kCFPreferencesCurrentUser would resolve to powerd's own domain instead.

static void qlimit_loadPreferences(void) {
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:kQLimitPrefsPath];
    _qlimitMaxChargingLevel = prefs[@"MaxChargingLevel"] ? [prefs[@"MaxChargingLevel"] intValue] : kQLimitDefaultLevel;
    _qlimitSailDepth = prefs[@"SailDepth"] ? [prefs[@"SailDepth"] intValue] : kQLimitDefaultSailDepth;
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

    if (!externalConnected) {
        qlimit_setChargeInhibited(NO);
        return;
    }

    if (currentCapacity >= _qlimitMaxChargingLevel) {
        qlimit_setChargeInhibited(YES);
    } else if (currentCapacity <= _qlimitMaxChargingLevel - _qlimitSailDepth) {
        qlimit_setChargeInhibited(NO);
    }
    // else: within the sail window - leave the current state alone. This is
    // the point of sailing mode, not a bug: the battery is left to drift
    // down through this range on its own instead of topping up immediately.
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
