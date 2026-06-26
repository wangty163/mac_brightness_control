#ifndef DDCPower_h
#define DDCPower_h

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

int BCDDCSetExternalDisplayPower(uint32_t externalDisplayIndex, uint8_t mode, char *errorBuffer, size_t errorBufferLength);

#ifdef __cplusplus
}
#endif

#endif
