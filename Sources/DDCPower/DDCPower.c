#include "DDCPower.h"

#include <ApplicationServices/ApplicationServices.h>
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/graphics/IOGraphicsLib.h>
#include <IOKit/i2c/IOI2CInterface.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

#ifndef kIOMainPortDefault
#define kIOMainPortDefault kIOMasterPortDefault
#endif

#define BCDDCMaxDisplays 32
#define BCDDCVCPDPMS 0xD6

extern io_service_t CGDisplayIOServicePort(CGDirectDisplayID display) __attribute__((weak_import));

static void BCDDCSetError(char *buffer, size_t length, const char *format, ...)
{
    if (!buffer || length == 0) {
        return;
    }

    va_list arguments;
    va_start(arguments, format);
    vsnprintf(buffer, length, format, arguments);
    va_end(arguments);
}

static bool BCDDCNumberForKey(CFDictionaryRef dictionary, CFStringRef key, uint32_t *value)
{
    if (!dictionary || !value) {
        return false;
    }

    CFNumberRef number = CFDictionaryGetValue(dictionary, key);
    if (!number || CFGetTypeID(number) != CFNumberGetTypeID()) {
        return false;
    }

    int64_t rawValue = 0;
    if (!CFNumberGetValue(number, kCFNumberSInt64Type, &rawValue)) {
        return false;
    }

    *value = (uint32_t)rawValue;
    return true;
}

static bool BCDDCFramebufferMatchesDisplay(io_service_t framebuffer, CGDirectDisplayID displayID)
{
    IOItemCount busCount = 0;
    if (IOFBGetI2CInterfaceCount(framebuffer, &busCount) != KERN_SUCCESS || busCount < 1) {
        return false;
    }

    CFDictionaryRef info = IODisplayCreateInfoDictionary(framebuffer, kIODisplayOnlyPreferredName);
    if (!info) {
        return false;
    }

    uint32_t vendorID = 0;
    uint32_t productID = 0;
    uint32_t serialNumber = 0;
    bool hasVendor = BCDDCNumberForKey(info, CFSTR(kDisplayVendorID), &vendorID);
    bool hasProduct = BCDDCNumberForKey(info, CFSTR(kDisplayProductID), &productID);
    bool hasSerial = BCDDCNumberForKey(info, CFSTR(kDisplaySerialNumber), &serialNumber);
    CFRelease(info);

    if (!hasVendor || !hasProduct) {
        return false;
    }

    uint32_t displayVendor = CGDisplayVendorNumber(displayID);
    uint32_t displayModel = CGDisplayModelNumber(displayID);
    uint32_t displaySerial = CGDisplaySerialNumber(displayID);

    if (displayVendor != vendorID || displayModel != productID) {
        return false;
    }

    if (hasSerial && displaySerial != 0 && serialNumber != 0 && displaySerial != serialNumber) {
        return false;
    }

    return true;
}

static io_service_t BCDDCCopyFramebufferForDisplay(CGDirectDisplayID displayID)
{
    io_service_t deprecatedService = IO_OBJECT_NULL;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    if (CGDisplayIOServicePort != NULL) {
        deprecatedService = CGDisplayIOServicePort(displayID);
    }
#pragma clang diagnostic pop

    IOItemCount deprecatedServiceBusCount = 0;
    if (
        deprecatedService &&
        IOFBGetI2CInterfaceCount(deprecatedService, &deprecatedServiceBusCount) == KERN_SUCCESS &&
        deprecatedServiceBusCount > 0
    ) {
        return deprecatedService;
    }

    io_iterator_t iterator = IO_OBJECT_NULL;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    kern_return_t result = IOServiceGetMatchingServices(
        kIOMainPortDefault,
        IOServiceMatching(IOFRAMEBUFFER_CONFORMSTO),
        &iterator
    );
#pragma clang diagnostic pop
    if (result != KERN_SUCCESS) {
        return IO_OBJECT_NULL;
    }

    io_service_t framebuffer = IO_OBJECT_NULL;
    io_service_t service = IO_OBJECT_NULL;
    while ((service = IOIteratorNext(iterator)) != IO_OBJECT_NULL) {
        if (BCDDCFramebufferMatchesDisplay(service, displayID)) {
            framebuffer = service;
            break;
        }
        IOObjectRelease(service);
    }

    IOObjectRelease(iterator);
    return framebuffer;
}

static bool BCDDCSendVCPWrite(io_service_t framebuffer, uint8_t controlID, uint16_t value)
{
    IOItemCount busCount = 0;
    if (IOFBGetI2CInterfaceCount(framebuffer, &busCount) != KERN_SUCCESS || busCount < 1) {
        return false;
    }

    uint8_t data[7] = {0};
    data[0] = 0x51;
    data[1] = 0x84;
    data[2] = 0x03;
    data[3] = controlID;
    data[4] = (uint8_t)(value >> 8);
    data[5] = (uint8_t)(value & 0xFF);
    data[6] = 0x6E ^ data[0] ^ data[1] ^ data[2] ^ data[3] ^ data[4] ^ data[5];

    for (IOOptionBits bus = 0; bus < busCount; bus++) {
        io_service_t interface = IO_OBJECT_NULL;
        if (IOFBCopyI2CInterfaceForBus(framebuffer, bus, &interface) != KERN_SUCCESS) {
            continue;
        }

        IOI2CConnectRef connect = NULL;
        bool sent = false;
        if (IOI2CInterfaceOpen(interface, kNilOptions, &connect) == KERN_SUCCESS) {
            IOI2CRequest request;
            memset(&request, 0, sizeof(request));
            request.sendAddress = 0x6E;
            request.sendTransactionType = kIOI2CSimpleTransactionType;
            request.sendBuffer = (vm_address_t)&data[0];
            request.sendBytes = sizeof(data);
            request.replyTransactionType = kIOI2CNoTransactionType;
            request.replyBytes = 0;

            kern_return_t writeResult = IOI2CSendRequest(connect, kNilOptions, &request);
            sent = writeResult == KERN_SUCCESS && request.result == KERN_SUCCESS;
            IOI2CInterfaceClose(connect, kNilOptions);
        }

        IOObjectRelease(interface);
        if (sent) {
            usleep(20000);
            return true;
        }
    }

    return false;
}

static bool BCDDCExternalDisplayAtIndex(uint32_t externalDisplayIndex, CGDirectDisplayID *displayID)
{
    CGDirectDisplayID displays[BCDDCMaxDisplays] = {0};
    uint32_t displayCount = 0;
    if (CGGetOnlineDisplayList(BCDDCMaxDisplays, displays, &displayCount) != kCGErrorSuccess) {
        return false;
    }

    uint32_t externalIndex = 0;
    for (uint32_t i = 0; i < displayCount; i++) {
        if (CGDisplayIsBuiltin(displays[i])) {
            continue;
        }

        externalIndex += 1;
        if (externalIndex == externalDisplayIndex) {
            *displayID = displays[i];
            return true;
        }
    }

    return false;
}

int BCDDCSetExternalDisplayPower(uint32_t externalDisplayIndex, uint8_t mode, char *errorBuffer, size_t errorBufferLength)
{
    if (externalDisplayIndex == 0) {
        BCDDCSetError(errorBuffer, errorBufferLength, "External display index must start at 1.");
        return 1;
    }

    if (mode != 1 && mode != 5) {
        BCDDCSetError(errorBuffer, errorBufferLength, "Unsupported external display power mode: %u.", mode);
        return 1;
    }

    CGDirectDisplayID displayID = 0;
    if (!BCDDCExternalDisplayAtIndex(externalDisplayIndex, &displayID)) {
        BCDDCSetError(errorBuffer, errorBufferLength, "External display #%u was not found.", externalDisplayIndex);
        return 2;
    }

    io_service_t framebuffer = BCDDCCopyFramebufferForDisplay(displayID);
    if (!framebuffer) {
        BCDDCSetError(errorBuffer, errorBufferLength, "No DDC-capable framebuffer found for external display #%u.", externalDisplayIndex);
        return 3;
    }

    bool sent = BCDDCSendVCPWrite(framebuffer, BCDDCVCPDPMS, mode);
    IOObjectRelease(framebuffer);

    if (!sent) {
        BCDDCSetError(errorBuffer, errorBufferLength, "Failed to send DDC power command to external display #%u.", externalDisplayIndex);
        return 4;
    }

    if (errorBuffer && errorBufferLength > 0) {
        errorBuffer[0] = '\0';
    }
    return 0;
}
