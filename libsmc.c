// libsmc.c

#include <IOKit/IOKitLib.h>
#include <mach/mach.h>

#pragma mark - SMC protocol types

typedef CF_ENUM(UInt8, SMCIndex) {
    kSMCUserClientOpen,
    kSMCUserClientClose,
    kSMCHandleYPCEvent,

    kSMCPlaceholder1,
    kSMCNumberOfMethods,

    kSMCReadKey,
    kSMCWriteKey,
    kSMCGetKeyCount,
    kSMCGetKeyFromIndex,
    kSMCGetKeyInfo,

    kSMCFireInterrupt,
    kSMCGetPLimits,
    kSMCGetVers,
    kSMCPlaceholder2,

    kSMCReadStatus,
    kSMCReadResult,

    kSMCVariableCommand
};

typedef uint32_t SMCKey;
typedef uint32_t SMCDataType;
typedef uint8_t SMCDataAttributes;

typedef struct SMCVersion {
    unsigned char major;
    unsigned char minor;
    unsigned char build;
    unsigned short release;
} SMCVersion;

typedef struct SMCPLimitData {
    uint16_t version;
    uint16_t length;
    uint32_t cpuPLimit;
    uint32_t gpuPLimit;
    uint32_t memPLimit;
} SMCPLimitData;

typedef struct SMCKeyInfoData {
    uint32_t dataSize;
    SMCDataType dataType;
    SMCDataAttributes dataAttributes;
} SMCKeyInfoData;

typedef struct SMCParamStruct {
    SMCKey key;
    struct SMCParam {
        SMCVersion vers;
        SMCPLimitData pLimitData;
        SMCKeyInfoData keyInfo;

        uint8_t result;
        uint8_t status;

        uint8_t data8;
        uint32_t data32;
        unsigned char bytes[120];
    } param;
} SMCParamStruct;

#pragma mark - Debug logging

#ifndef DBGLOG
#define DBGLOG(fmt, ...) do {} while (0)
#endif

#pragma mark - Connection state

static io_service_t gConn = 0;

// Public: open the SMC connection. Must be called once before any
// smc_write_safe/smc_read_safe calls
// which calls this explicitly once at startup rather than lazily
IOReturn smc_open(void) {
    IOReturn result;
    mach_port_t masterPort;
    io_service_t service;

    if (IOMasterPort(MACH_PORT_NULL, &masterPort) != kIOReturnSuccess) {
        DBGLOG("IOMasterPort() failed");
        return kIOReturnError;
    }

    service = IOServiceGetMatchingService(masterPort, IOServiceMatching("AppleSMC"));
    if (service == IO_OBJECT_NULL) {
        return kIOReturnError;
    }

    result = IOServiceOpen(service, mach_task_self(), 0, &gConn);
    if (result != kIOReturnSuccess) {
        DBGLOG("IOServiceOpen() failed (%d)", result);
        return kIOReturnError;
    }

    return kIOReturnSuccess;
}

static IOReturn smc_call(int index, SMCParamStruct *inputStruct, SMCParamStruct *outputStruct) {
    size_t inputSize = sizeof(SMCParamStruct);
    size_t outputSize = sizeof(SMCParamStruct);

    return IOConnectCallStructMethod(gConn, index, inputStruct, inputSize, outputStruct, &outputSize);
}

static IOReturn smc_get_keyinfo(uint32_t key, SMCKeyInfoData *keyInfo) {
    SMCParamStruct inputStruct = {0};
    SMCParamStruct outputStruct;
    IOReturn result;

    inputStruct.key = key;
    inputStruct.param.data8 = kSMCGetKeyInfo;

    result = smc_call(kSMCHandleYPCEvent, &inputStruct, &outputStruct);

    // Important check: dataSize != 0 - a nonexistent key can still return kIOReturnSuccess
    if (outputStruct.param.keyInfo.dataSize == 0) {
        result = kIOReturnError;
    }

    if (result == kIOReturnSuccess) {
        *keyInfo = outputStruct.param.keyInfo;
    }

    return result;
}

// Public: write `size` bytes to SMC key `key`.
// smc_open() must have been called once beforehand
IOReturn smc_write_safe(uint32_t key, void *bytes, uint32_t size) {
    SMCParamStruct input = {0};
    SMCParamStruct out;
    IOReturn result;

    if ((result = smc_get_keyinfo(key, &input.param.keyInfo))) {
        return result;
    }
    if (input.param.keyInfo.dataSize > size) {
        DBGLOG("smc_write_safe failed: data too short");
        return -1;
    }

    input.param.data8 = kSMCWriteKey;
    input.key = key;
    memcpy(input.param.bytes, bytes, input.param.keyInfo.dataSize);

    result = smc_call(kSMCHandleYPCEvent, &input, &out);
    if (result != kIOReturnSuccess) {
        DBGLOG("smc_call failed %d", result);
        return result;
    }
    return kIOReturnSuccess;
}

// Public: read up to `*size` bytes from SMC key `key` into `bytes`.
// `*size` is updated to the actual data size on return.
IOReturn smc_read_safe(uint32_t key, void *bytes, int32_t *size) {
    IOReturn result;
    SMCParamStruct inputStruct = {0};
    SMCParamStruct outputStruct;

    inputStruct.key = key;

    result = smc_get_keyinfo(inputStruct.key, &inputStruct.param.keyInfo);
    if (result != kIOReturnSuccess) {
        return result;
    }

    int omit_mismatch_warning = 0;
    if (*size < 0) {
        *size = -(*size);
        omit_mismatch_warning = 1;
    }
    uint32_t loggedKey = htonl(key);
    if (*size < inputStruct.param.keyInfo.dataSize) {
        DBGLOG("smc_read_safe %.4s WARNING: buffer too short: buf len %d; has %d; will truncate",
               (char *)&loggedKey, *size, inputStruct.param.keyInfo.dataSize);
    } else if (*size != inputStruct.param.keyInfo.dataSize) {
        if (!omit_mismatch_warning) {
            DBGLOG("smc_read_safe %.4s WARNING: size mismatch: buf len %d; has %d",
                   (char *)&loggedKey, *size, inputStruct.param.keyInfo.dataSize);
        }
        *size = inputStruct.param.keyInfo.dataSize;
    }

    inputStruct.param.data8 = kSMCReadKey;

    result = smc_call(kSMCHandleYPCEvent, &inputStruct, &outputStruct);
    if (result != kIOReturnSuccess) {
        DBGLOG("smc_call failed %d", result);
        return result;
    }

    memcpy(bytes, outputStruct.param.bytes, *size);
    return kIOReturnSuccess;
}

// Public: convenience wrapper - read exactly `size` bytes.
IOReturn smc_read_n(uint32_t key, void *bytes, int32_t size) {
    return smc_read_safe(key, bytes, &size);
}
