/* Extras exported by shim/sanei_usb_libusb.c beyond the sanei_usb API. */
#pragma once
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Map a macOS IOKit USB locationID to the shim's "libusb:BUS:ADDR" device
   name. Returns 0 on success, -1 if no attached device has that location. */
int lide70_usb_name_for_location (uint32_t locationID, char *name, size_t len);

#ifdef __cplusplus
}
#endif
