/* Small C bridge over the canon_lide70 SANE backend, so callers (the ICA
   module) need no SANE headers. One scan at a time per process: the backend
   keeps static state. */
#pragma once
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

enum { LIDE70_MODE_COLOR = 0, LIDE70_MODE_GRAY = 1 };

/* Status codes are SANE_Status values. */
enum { LIDE70_GOOD = 0, LIDE70_DEVICE_BUSY = 3, LIDE70_INVAL = 4, LIDE70_EOF = 5, LIDE70_IO_ERROR = 9 };

typedef struct
{
  int    dpi;                 /* snapped to 75/150/300/600/1200 */
  int    mode;                /* LIDE70_MODE_* */
  double tl_x_mm, tl_y_mm;    /* clamped to the scan bed */
  double br_x_mm, br_y_mm;
} lide70_scan_request;

typedef struct
{
  int dpi;                    /* resolution actually used */
  int pixels_per_line;
  int lines;
  int bytes_per_line;
  int channels;               /* 3 = RGB, 1 = gray; 8 bits per channel */
} lide70_scan_format;

/* Scan bed limits in mm, from the backend's option ranges. */
#define LIDE70_BED_WIDTH_MM   (5104 * 25.4 / 600)
#define LIDE70_BED_HEIGHT_MM  297.0

/* Opens `device` ("libusb:BUS:ADDR"), applies the request, and runs the scan.
   Blocks until the head has finished moving: the backend scans to a temp
   file before any data can be read. On success the image is read with
   lide70_scan_read(); always call lide70_scan_end() afterwards. */
int  lide70_scan_begin (const char *device, const lide70_scan_request *rq,
                        lide70_scan_format *fmt);

/* Reads up to `max` bytes of image data. Returns LIDE70_GOOD with *got > 0,
   LIDE70_EOF when the image is complete, or an error status. */
int  lide70_scan_read (unsigned char *buf, int max, int *got);

/* Drains any unread data (so the backend removes its temp file) and closes
   the device, releasing the USB interface. Safe to call more than once. */
void lide70_scan_end (void);

const char *lide70_status_name (int status);

#ifdef __cplusplus
}
#endif
