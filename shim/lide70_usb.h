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

/* Opens `name`, claims its interface, and releases it again: checks that this
   process can use the scanner. Returns a SANE_Status (0 = GOOD,
   3 = DEVICE_BUSY when another process holds the interface). */
int lide70_usb_probe_claim (const char *name);

/* Finds the first attached LiDE 70 (04a9:2225) or LiDE 600 (04a9:2224) and
   writes its "libusb:BUS:ADDR" name. Returns 0 on success, -1 if none. */
int lide70_usb_find_first (char *name, size_t len);

#ifdef __cplusplus
}
#endif
