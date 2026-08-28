#import <Foundation/Foundation.h>
#import <IOKit/IOKitLib.h>
#import <IOKit/ps/IOPSKeys.h>
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

// ---- The actual control primitive ---------------------------------------

static void qlimit_setChargeInhibited(BOOL inhibited) {
    if (inhibited) {
        if (_qlimitAssertionID == kIOPMNullAssertionID) {
            IOPMAssertionCreateWithName(CFSTR("ChargeInhibit"), kIOPMAssertionLevelOn, CFSTR("ChargeInhibit"), &_qlimitAssertionID);
        }
    } else if (_qlimitAssertionID != kIOPMNullAssertionID) {
          IOPMAssertionRelease(_qlimitAssertionID);
          _qlimitAssertionID = kIOPMNullAssertionID;
    }
    _qlimitChargeInhibited = inhibited;
}

// ---- Decision logic ---------------------------------------------------------

static void qlimit_evaluateChargingState(void) {
    CFTypeRef blob = IOPSCopyPowerSourcesInfo();
    if (!blob) return;

    CFArrayRef list = IOPSCopyPowerSourcesList(blob);
    if (!list) {
        CFRelease(blob);
        return;
    }

    if (CFArrayGetCount(list) > 0) {
        CFDictionaryRef detail = IOPSGetPowerSourceDescription(blob, CFArrayGetValueAtIndex(list, 0));
        if (detail) {
            CFStringRef state = (CFStringRef)CFDictionaryGetValue(detail, CFSTR(kIOPSPowerSourceStateKey));
            CFNumberRef capNum = (CFNumberRef)CFDictionaryGetValue(detail, CFSTR(kIOPSCurrentCapacityKey));
        
            BOOL isPluggedIn = (state && CFStringCompare(state, CFSTR(kIOPSACPowerValue), 0) == kCFCompareEqualTo);
            
            int capacity = 0;
            if (capNum) CFNumberGetValue(capNum, kCFNumberIntType, &capacity);

            if (!isPluggedIn) {
                qlimit_setChargeInhibited(NO);
            } else if (capacity >= _qlimitMaxChargingLevel) {
                qlimit_setChargeInhibited(YES);
            } else if (capacity <= (_qlimitMaxChargingLevel - _qlimitSailDepth)) {
                qlimit_setChargeInhibited(NO);
            }
        }
    }

    CFRelease(list);
    CFRelease(blob);
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
