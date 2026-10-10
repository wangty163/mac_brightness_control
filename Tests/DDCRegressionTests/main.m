@import Foundation;
@import IOKit;
@import ApplicationServices;

// Exercise the production enumeration with disappearing display metadata.
// Every hardware entry point used by these cases is replaced with a fixture.
#define CGGetOnlineDisplayList FixtureDisplays
#define CGDisplayIsBuiltin FixtureBuiltin
#define CGDisplayVendorNumber FixtureVendor
#define CGDisplayModelNumber FixtureModel
#define CGDisplaySerialNumber FixtureSerial
#define CoreDisplay_DisplayCreateInfoDictionary FixtureInfo
#define IORegistryEntryCopyFromPath FixtureAdapter
#define IOAVServiceWriteI2C FixtureWrite

CGError FixtureDisplays(uint32_t, CGDirectDisplayID *, uint32_t *);
boolean_t FixtureBuiltin(CGDirectDisplayID);
uint32_t FixtureVendor(CGDirectDisplayID);
uint32_t FixtureModel(CGDirectDisplayID);
uint32_t FixtureSerial(CGDirectDisplayID);
io_registry_entry_t FixtureAdapter(mach_port_t, CFStringRef);
#include "../../Vendor/m1ddc/sources/ioregistry.m"
#include "../../Vendor/m1ddc/sources/i2c.m"

static int metadataCase = 0;
static int writeCount = 0;
static uint32_t writeLength = 0;
CGError FixtureDisplays(uint32_t max, CGDirectDisplayID *ids, uint32_t *count) {
    assert(max >= 3);
    ids[0] = 1; ids[1] = 2; ids[2] = 3; *count = 3;
    return kCGErrorSuccess;
}
boolean_t FixtureBuiltin(CGDirectDisplayID id) { return id == 1; }
uint32_t FixtureVendor(CGDirectDisplayID id) { (void)id; return 1138; }
uint32_t FixtureModel(CGDirectDisplayID id) { (void)id; return 10017; }
uint32_t FixtureSerial(CGDirectDisplayID id) { return id; }
CFDictionaryRef FixtureInfo(CGDirectDisplayID id) {
    if (id == 2 && metadataCase == 0) return NULL;
    if (id == 2 && metadataCase == 1) return (CFDictionaryRef)[@{} retain];
    if (id == 2 && metadataCase == 2) return (CFDictionaryRef)[@{@"kCGDisplayUUID": @123, @"IODisplayLocation": @456} retain];
    return (CFDictionaryRef)[@{@"kCGDisplayUUID": @"fixture", @"IODisplayLocation": @"missing"} retain];
}
io_registry_entry_t FixtureAdapter(mach_port_t port, CFStringRef path) {
    (void)port; (void)path; return IO_OBJECT_NULL;
}
IOReturn FixtureWrite(IOAVServiceRef service, uint32_t chip, uint32_t address, void *bytes, uint32_t length) {
    (void)service; (void)chip; (void)address; (void)bytes;
    writeCount++; writeLength = length; return kIOReturnSuccess;
}
int main(void) {
    for (metadataCase = 0; metadataCase < 3; metadataCase++) {
        DisplayInfos displays[MAX_DISPLAYS];
        memset(displays, 0xAA, sizeof(displays));
        assert(getOnlineDisplayInfos(displays) == 2);
        assert(displays[0].id == 2 && displays[1].id == 3);
        assert(displays[0].adapter == IO_OBJECT_NULL);
        assert(getDisplayDDCTransport(&displays[0]).service == NULL);
        char first[] = "1", second[] = "2", zero[] = "0", negative[] = "-1";
        assert(selectDisplay(displays, 2, first)->id == 2);
        assert(selectDisplay(displays, 2, second)->id == 3);
        assert(selectDisplay(displays, 2, zero) == NULL);
        assert(selectDisplay(displays, 2, negative) == NULL);
    }
    DDCPacket power = createDDCPacket(STANDBY);
    prepareDDCWrite(&power, 5);
    assert(performDDCWrite(NULL, &power) == kIOReturnSuccess);
    assert(writeCount == 1 && writeLength == 6);
    DDCPacket brightness = createDDCPacket(LUMINANCE);
    prepareDDCWrite(&brightness, 168);
    assert(brightness.data[5] == 0);
    performDDCWrite(NULL, &brightness);
    assert(writeLength == 6); // Include checksum even if its value is zero.
    char reply[12] = {0};
    assert(convertI2CtoDDC(reply).curValue == -1);
    UInt8 valid[12] = {0x6e, 0x88, 0x02, 0, 0x10, 0, 0x01, 0x2c, 0x01, 0x04, 0, 0};
    valid[10] = 0x50;
    for (int i = 0; i < 10; i++) valid[10] ^= valid[i];
    DDCValue value = convertI2CtoDDC((char *)valid);
    assert(value.curValue == 260 && value.maxValue == 300);
    valid[10] ^= 1;
    assert(convertI2CtoDDC((char *)valid).curValue == -1);
    puts("DDC regressions passed: missing metadata, stable indices, one power write, packet length, validated replies.");
}
