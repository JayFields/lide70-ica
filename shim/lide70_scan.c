/* Bridge over the canon_lide70 SANE backend. See lide70_scan.h. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "../include/sane/config.h"
#include "../include/sane/sane.h"
#include "../include/sane/saneopts.h"
#include "lide70_scan.h"

SANE_Status sane_canon_lide70_init (SANE_Int *, SANE_Auth_Callback);
SANE_Status sane_canon_lide70_open (SANE_String_Const, SANE_Handle *);
void sane_canon_lide70_close (SANE_Handle);
const SANE_Option_Descriptor *sane_canon_lide70_get_option_descriptor (SANE_Handle, SANE_Int);
SANE_Status sane_canon_lide70_control_option (SANE_Handle, SANE_Int, SANE_Action, void *, SANE_Int *);
SANE_Status sane_canon_lide70_get_parameters (SANE_Handle, SANE_Parameters *);
SANE_Status sane_canon_lide70_start (SANE_Handle);
SANE_Status sane_canon_lide70_read (SANE_Handle, SANE_Byte *, SANE_Int, SANE_Int *);
SANE_String_Const sane_strstatus (SANE_Status);

static int inited;
static SANE_Handle handle;
static int at_eof;

static const int dpis[] = { 75, 150, 300, 600, 1200 };

static int
snap_dpi (int want)
{
  int best = dpis[0];
  for (size_t i = 0; i < sizeof dpis / sizeof dpis[0]; i++)
    if (abs (dpis[i] - want) < abs (best - want))
      best = dpis[i];
  return best;
}

static double
clamp (double v, double lo, double hi)
{
  return v < lo ? lo : v > hi ? hi : v;
}

/* Options are found by name, not by the backend's enum order. */
static int
set_opt (const char *name, void *val)
{
  SANE_Int n = 0;
  if (sane_canon_lide70_control_option (handle, 0, SANE_ACTION_GET_VALUE, &n, NULL))
    return SANE_STATUS_INVAL;
  for (int i = 1; i < n; i++)
    {
      const SANE_Option_Descriptor *d = sane_canon_lide70_get_option_descriptor (handle, i);
      if (d && d->name && !strcmp (d->name, name))
        return sane_canon_lide70_control_option (handle, i, SANE_ACTION_SET_VALUE, val, NULL);
    }
  return SANE_STATUS_INVAL;
}

int
lide70_scan_begin (const char *device, const lide70_scan_request *rq, lide70_scan_format *fmt)
{
  SANE_Status s;
  SANE_Int ver;
  SANE_Parameters p;
  char mode[64];
  SANE_Int dpi;
  SANE_Fixed tlx, tly, brx, bry;
  double x0, y0, x1, y1;

  if (handle)
    return SANE_STATUS_DEVICE_BUSY;	/* one scan at a time */
  if (!inited)
    {
      if ((s = sane_canon_lide70_init (&ver, NULL)))
        return s;
      inited = 1;
    }
  if ((s = sane_canon_lide70_open (device, &handle)))
    {
      handle = NULL;
      return s;
    }
  at_eof = 0;

  x0 = clamp (rq->tl_x_mm, 0, LIDE70_BED_WIDTH_MM);
  y0 = clamp (rq->tl_y_mm, 0, LIDE70_BED_HEIGHT_MM);
  x1 = clamp (rq->br_x_mm, x0, LIDE70_BED_WIDTH_MM);
  y1 = clamp (rq->br_y_mm, y0, LIDE70_BED_HEIGHT_MM);
  dpi = snap_dpi (rq->dpi);
  tlx = SANE_FIX (x0); tly = SANE_FIX (y0); brx = SANE_FIX (x1); bry = SANE_FIX (y1);
  snprintf (mode, sizeof mode, "%s",
            rq->mode == LIDE70_MODE_GRAY ? SANE_VALUE_SCAN_MODE_GRAY : SANE_VALUE_SCAN_MODE_COLOR);

  /* mode first: the backend reloads options when it changes */
  if ((s = set_opt (SANE_NAME_SCAN_MODE, mode))
      || (s = set_opt (SANE_NAME_SCAN_RESOLUTION, &dpi))
      || (s = set_opt (SANE_NAME_SCAN_TL_X, &tlx))
      || (s = set_opt (SANE_NAME_SCAN_TL_Y, &tly))
      || (s = set_opt (SANE_NAME_SCAN_BR_X, &brx))
      || (s = set_opt (SANE_NAME_SCAN_BR_Y, &bry)))
    {
      lide70_scan_end ();
      return s;
    }

  if ((s = sane_canon_lide70_start (handle)))
    {
      lide70_scan_end ();
      return s;
    }
  sane_canon_lide70_get_parameters (handle, &p);
  fmt->dpi = dpi;
  fmt->pixels_per_line = p.pixels_per_line;
  fmt->lines = p.lines;
  fmt->bytes_per_line = p.bytes_per_line;
  fmt->channels = p.format == SANE_FRAME_RGB ? 3 : 1;
  return SANE_STATUS_GOOD;
}

int
lide70_scan_read (unsigned char *buf, int max, int *got)
{
  SANE_Status s;
  *got = 0;
  if (!handle)
    return SANE_STATUS_INVAL;
  if (at_eof)
    return SANE_STATUS_EOF;
  s = sane_canon_lide70_read (handle, buf, max, got);
  if (s == SANE_STATUS_EOF)
    at_eof = 1;
  return s;
}

void
lide70_scan_end (void)
{
  unsigned char sink[65536];
  int got;

  if (!handle)
    return;
  /* The backend only removes its temp file when a read reaches EOF. */
  while (!at_eof && lide70_scan_read (sink, sizeof sink, &got) == SANE_STATUS_GOOD)
    ;
  sane_canon_lide70_close (handle);
  handle = NULL;
}

const char *
lide70_status_name (int status)
{
  return sane_strstatus (status);
}
