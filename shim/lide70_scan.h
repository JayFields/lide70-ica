/* Small C bridge over the canon_lide70 SANE backend, so callers (the ICA
   module) need no SANE headers. One scan at a time per process: the backend
   keeps static state.

   A scan runs on a thread owned by the bridge, and its rows are streamed to
   the caller while the scanner is still moving:

     lide70_scan_start()   configure, report the image format, start scanning
     lide70_scan_read()    rows as they arrive (blocks until there are some)
     lide70_scan_cancel()  ask the scan to stop (any thread)
     lide70_scan_end()     stop if still running, wait, clean up (always call) */
#pragma once
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

enum { LIDE70_MODE_COLOR = 0, LIDE70_MODE_GRAY = 1 };

/* Status codes are SANE_Status values. */
enum { LIDE70_GOOD = 0, LIDE70_CANCELLED = 2, LIDE70_DEVICE_BUSY = 3, LIDE70_INVAL = 4, LIDE70_EOF = 5,
       LIDE70_IO_ERROR = 9 };

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

/* Opens `device` ("libusb:BUS:ADDR"), applies the request, fills in the image
   format, and starts the scan on a background thread. Returns at once with
   LIDE70_GOOD, or an error if the device could not be opened or configured
   (then nothing is running). */
int  lide70_scan_start (const char *device, const lide70_scan_request *rq,
                        lide70_scan_format *fmt);

/* Reads up to `max` bytes of image data (whole rows arrive in order, but a
   read may end mid-row). Blocks until data is available. Returns LIDE70_GOOD
   with *got > 0; LIDE70_EOF when the whole image has been read;
   LIDE70_CANCELLED after lide70_scan_cancel(); or another error status. */
int  lide70_scan_read (unsigned char *buf, int max, int *got);

/* Asks the running scan to stop. The backend checks between USB buffers,
   sends the head home and deletes its temp file; lide70_scan_read() then
   returns LIDE70_CANCELLED. Safe from any thread, and when nothing runs. */
void lide70_scan_cancel (void);

/* Ends the scan: cancels it if it is still running, waits for the scan
   thread, cleans up, and releases the USB interface. Safe to call more than
   once, and after a failed lide70_scan_start(). */
void lide70_scan_end (void);

const char *lide70_status_name (int status);

#ifdef __cplusplus
}
#endif
