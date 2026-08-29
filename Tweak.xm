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


#define QLIMIT_DEBUG 1
#if QLIMIT_DEBUG
    #define QLog(fmt, ...) \
        do { \
            FILE *f = fopen("/var/mobile/Library/Logs/qlimit.log", "a"); \
            if (f) { \
                fprintf(f, "[QLimit] " fmt "\n", ##__VA_ARGS__); \
                fclose(f); \
            } \
        } while (0)
#else
    #define QLog(fmt, ...) do {} while (0)
#endif

// ---- State -------------------------------------------------------------

static int _qlimitMaxChargingLevel = kQLimitDefaultLevel;
static int _qlimitSailDepth = kQLimitDefaultSailDepth;

static IONotificationPortRef gNotifyPort = NULL;
static io_object_t gPowerNotification = IO_OBJECT_NULL;

// ---- Helpers ------------------------------------------------------------

static CFTypeRef qlimit_copyProperty(io_service_t service, CFStringRef key) {
    if (!service) return NULL;
    return IORegistryEntryCreateCFProperty(service, key, kCFAllocatorDefault, 0);
}

static BOOL qlimit_isAdapterConnected(io_service_t service) {
    CFDictionaryRef adapterDetails = (CFDictionaryRef)qlimit_copyProperty(service, CFSTR("AdapterDetails"));
    if (adapterDetails) {
        NSDictionary *details = (__bridge NSDictionary *)adapterDetails;
        NSString *desc = details[@"Description"];
        BOOL isConnected = (desc && ![desc isEqualToString:@"batt"]);
        CFRelease(adapterDetails);
        return isConnected;
    }
    
    // Fallback if AdapterDetails is nil (e.g., standard 5W chargers / older devices)
    CFBooleanRef chargeCapable = (CFBooleanRef)qlimit_copyProperty(service, CFSTR("ExternalChargeCapable"));
    if (chargeCapable) {
        BOOL isConnected = CFBooleanGetValue(chargeCapable);
        CFRelease(chargeCapable);
        return isConnected;
    }

    return NO;
}

// ---- Preferences ---------------------------------------------------------

static int qlimit_intPrefValue(CFStringRef key, int defaultValue) {
    id value = (__bridge_transfer id)CFPreferencesCopyValue(key, kQLimitAppID, kQLimitPrefsUser, kCFPreferencesCurrentHost);
    return value ? [value intValue] : defaultValue;
}

static void qlimit_loadPreferences(void) {
    CFPreferencesSynchronize(kQLimitAppID, kQLimitPrefsUser, kCFPreferencesCurrentHost);
    _qlimitMaxChargingLevel = qlimit_intPrefValue(kQLimitMaxLevelKey, kQLimitDefaultLevel);
    _qlimitSailDepth = qlimit_intPrefValue(kQLimitSailDepthKey, kQLimitDefaultSailDepth);

    QLog("Loaded Preferences: MaxLevel=%d, SailDepth=%d", _qlimitMaxChargingLevel, _qlimitSailDepth);
}

// ---- Service Resolver ------------------------------

static io_service_t qlimit_getPowerService(void) {
    static io_service_t serv = IO_OBJECT_NULL;
    if (serv == IO_OBJECT_NULL) {
        serv = IOServiceGetMatchingService(kIOMasterPortDefault, IOServiceMatching("AppleSmartBattery"));
        if (serv == IO_OBJECT_NULL) {
            serv = IOServiceGetMatchingService(kIOMasterPortDefault, IOServiceMatching("IOPMPowerSource"));
        }
    }
    return serv;
}

// ---- Control Primitives --------------------------------------------------

static void qlimit_setChargeInhibited(BOOL inhibited) {
    io_service_t service = qlimit_getPowerService();
    if (!service) {
        QLog("Error: Unable to locate IOKit Power Service!");
        return;
    }

    NSDictionary *props = @{
        @"IsCharging": inhibited ? @NO : @YES,
        @"PredictiveChargingInhibit": inhibited ? @YES : @NO,
        @"ExternalConnected": (inhibited && isPlugged) ? @NO : @YES
    };

    kern_return_t status = IORegistryEntrySetCFProperties(service, (__bridge CFDictionaryRef)props);
    if (status == kIOReturnSuccess) {
        QLog("Successfully set charge inhibited = %s (ExternalConnected = %s)", inhibited ? "YES" : "NO", (!inhibited) ? "YES" : "NO");
    } else {
        QLog("Error writing IOKit properties: 0x%x", status);
    }
}

// ---- Decision logic ---------------------------------------------------------

static void qlimit_evaluateChargingState(void) {
    io_service_t service = qlimit_getPowerService();
    if (!service) {
        QLog("Error evaluating charging state: No service available.");
        return;
    }

    BOOL isPluggedIn = qlimit_isAdapterConnected(service);
    CFNumberRef capNum = (CFNumberRef)qlimit_copyProperty(service, CFSTR("CurrentCapacity"));

    if (capNum) {
        int capacity = 0;
        CFNumberGetValue(capNum, kCFNumberIntType, &capacity);
        CFRelease(capNum);

        QLog("Evaluating: PluggedIn=%s, Capacity=%d%%, MaxThreshold=%d%%, ResumeThreshold=%d%%", isPluggedIn ? "YES" : "NO", capacity, _qlimitMaxChargingLevel, (_qlimitMaxChargingLevel - _qlimitSailDepth));

        if (!isPluggedIn) {
            QLog("Device is unplugged. Resetting charge inhibit.");
            qlimit_setChargeInhibited(NO);
        } else if (capacity >= _qlimitMaxChargingLevel) {
            QLog("Max battery limit reached (%d >= %d). Halting charge.", capacity, _qlimitMaxChargingLevel);
            qlimit_setChargeInhibited(YES);
        } else if (capacity <= (_qlimitMaxChargingLevel - _qlimitSailDepth)) {
            QLog("Sailing threshold reached (%d <= %d). Resuming charge.", capacity, (_qlimitMaxChargingLevel - _qlimitSailDepth));
            qlimit_setChargeInhibited(NO);
        }
    } else {
        QLog("Failed to read CurrentCapacity from IOKit service.");
    }
}

// ---- Callbacks ---------------------------------------------------------

static void qlimit_powerSourceChangedCallback(void *refcon, io_service_t service, uint32_t messageType, void *messageArgument) {
    QLog("IOKit Power Event Fired: messageType = 0x%x", messageType);
    qlimit_evaluateChargingState();
}

static void qlimit_preferencesChangedCallback(CFNotificationCenterRef center,
                                               void *observer,
                                               CFStringRef name,
                                               const void *object,
                                               CFDictionaryRef userInfo) {
    QLog("Darwin notification received: Preferences changed.");
    qlimit_loadPreferences();
    qlimit_evaluateChargingState();
}

// ---- Setup Low-Level Hook (Exact ChargeLimiter Architecture) ------------

static void qlimit_setupIOKitNotification(void) {
    gNotifyPort = IONotificationPortCreate(kIOMasterPortDefault);
    if (!gNotifyPort) {
        QLog("Failed to create IONotificationPort!");
        return;
    }

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
        QLog("Successfully registered IOKit power interest notification listener.");
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


    dispatch_async(dispatch_get_main_queue(), ^{
        qlimit_setupIOKitNotification();
        qlimit_evaluateChargingState();
    });
}
