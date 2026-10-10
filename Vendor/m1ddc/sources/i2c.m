@import Foundation;

#include "i2c.h"
#include "utils.h"

// Function to get ready for DDC operations for a specific display attribute
DDCPacket createDDCPacket(UInt8 attrCode) {
    DDCPacket packet = {};
    packet.data[2] = attrCode;
    packet.inputAddr = packet.data[2] == INPUT_ALT ? ALTERNATE_INPUT_ADDRESS : DEFAULT_INPUT_ADDRESS;
    return packet;
}

// Prepare DDC packet for read
void prepareDDCRead(UInt8* data) {
    data[0] = 0x82;
    data[1] = 0x01;
    data[3] = 0x6e ^ data[0] ^ data[1] ^ data[2] ^ data[3];
}

// Prepare DDC packet for write
void prepareDDCWrite(DDCPacket *packet, UInt16 newValue) {
    UInt8* data = packet->data;
    data[0] = 0x84;
    data[1] = 0x03;
    data[3] = (newValue) >> 8;
    data[4] = newValue & 255;
    data[5] = 0x6E ^ packet->inputAddr ^ data[0] ^ data[1] ^ data[2] ^ data[3] ^ data[4];
}


IOReturn performDDCReadAtChipAddress(IOAVServiceRef avService, UInt32 chipAddress, DDCPacket *packet) {
    memset(packet->data, 0, sizeof(UInt8) * DDC_BUFFER_SIZE);
    usleep(chipAddress == DDC_CHIP_ADDRESS_MCDP29XX ? DDC_MCDP_READ_WAIT : DDC_WAIT);
    return IOAVServiceReadI2C(avService, chipAddress, packet->inputAddr, packet->data, 12);
}

IOReturn performDDCWriteAtChipAddress(IOAVServiceRef avService, UInt32 chipAddress, DDCPacket *packet) {
    IOReturn ret;

    int iterations = packet->data[1] == 0x03 && packet->data[2] == STANDBY ? 1 : DDC_ITERATIONS;
    for (int i = 0; i < iterations; ++i) {
        usleep(DDC_WAIT);
        if ((ret = IOAVServiceWriteI2C(avService, chipAddress, packet->inputAddr, packet->data, (packet->data[0] & 0x7f) + 2))) {
            return ret;
        }
    }
    return ret;
}

IOReturn performDDCRead(IOAVServiceRef avService, DDCPacket *packet) {
    return performDDCReadAtChipAddress(avService, DDC_CHIP_ADDRESS_DEFAULT, packet);
}

IOReturn performDDCWrite(IOAVServiceRef avService, DDCPacket *packet) {
    return performDDCWriteAtChipAddress(avService, DDC_CHIP_ADDRESS_DEFAULT, packet);
}


DDCValue convertI2CtoDDC(char *i2cBytes) {
    const UInt8 *bytes = (const UInt8 *)i2cBytes;
    DDCValue invalid = {-1, -1};
    // Reject empty, unsupported, truncated-format, or corrupt replies, not brightness 0.
    if (bytes[0] != 0x6e || bytes[1] != 0x88 || bytes[2] != 0x02 || bytes[3] != 0) return invalid;
    UInt8 checksum = 0x50;
    for (int i = 0; i < 11; i++) checksum ^= bytes[i];
    if (checksum != 0) return invalid;
    return (DDCValue){ .curValue = (bytes[8] << 8) | bytes[9], .maxValue = (bytes[6] << 8) | bytes[7] };
}
