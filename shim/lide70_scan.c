/* Bridge over the canon_lide70 SANE backend. See lide70_scan.h.

   sane_start() does the whole scan (writing a temp file) before returning, so
   it runs on a thread of its own. The backend's rows hook (a lide70-ica change
   in canon_lide70-common.c) appends each batch of finished rows to an
   in-memory queue, which lide70_scan_read() drains as the rows arrive. */
#include <pthread.h>
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
void sane_canon_lide70_cancel (SANE_Handle);
SANE_String_Const sane_strstatus (SANE_Status);
void canon_lide70_set_rows_hook (void (*hook) (const unsigned char *, size_t));
void canon_lide70_clear_cancel (void);

static int inited;
static SANE_Handle handle;          /* open device, from start until end */

/* The scan thread and the row queue it fills; guarded by `lock`. */
static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t changed = PTHREAD_COND_INITIALIZER;
static pthread_t scan_thread;
static int thread_started;          /* scan_thread needs joining */
static int running;                 /* sane_start() has not returned yet */
static SANE_Status run_status;      /* what it returned */
static unsigned char *queue;        /* rows not yet read: queue[head..tail) */
static size_t head, tail, capacity;

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

/* Called by the backend on the scan thread with each batch of finished rows. */
static void
on_rows (const unsigned char *data, size_t len)
{
  pthread_mutex_lock (&lock);
  if (head > 0)                     /* move unread bytes to the front */
    {
      memmove (queue, queue + head, tail - head);
      tail -= head;
      head = 0;
    }
  if (tail + len > capacity)
    {
      size_t want = capacity ? capacity : 1 << 20;
      while (want < tail + len)
        want *= 2;
      unsigned char *grown = realloc (queue, want);
      if (!grown)                   /* out of memory: the batch is lost and later rows shift up */
        {
          pthread_mutex_unlock (&lock);
          return;
        }
      queue = grown;
      capacity = want;
    }
  memcpy (queue + tail, data, len);
  tail += len;
  pthread_cond_broadcast (&changed);
  pthread_mutex_unlock (&lock);
}

static void *
scan_main (void *arg)
{
  SANE_Status s = sane_canon_lide70_start (handle);
  (void) arg;
  pthread_mutex_lock (&lock);
  run_status = s;
  running = 0;
  pthread_cond_broadcast (&changed);
  pthread_mutex_unlock (&lock);
  return NULL;
}

int
lide70_scan_start (const char *device, const lide70_scan_request *rq, lide70_scan_format *fmt)
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

  /* sane_start computes the same parameters from these options. */
  sane_canon_lide70_get_parameters (handle, &p);
  fmt->dpi = dpi;
  fmt->pixels_per_line = p.pixels_per_line;
  fmt->lines = p.lines;
  fmt->bytes_per_line = p.bytes_per_line;
  fmt->channels = p.format == SANE_FRAME_RGB ? 3 : 1;

  pthread_mutex_lock (&lock);
  head = tail = 0;
  running = 1;
  run_status = SANE_STATUS_GOOD;
  pthread_mutex_unlock (&lock);
  canon_lide70_clear_cancel ();     /* a late cancel of the previous scan */
  canon_lide70_set_rows_hook (on_rows);
  if (pthread_create (&scan_thread, NULL, scan_main, NULL))
    {
      running = 0;
      canon_lide70_set_rows_hook (NULL);
      lide70_scan_end ();
      return SANE_STATUS_NO_MEM;
    }
  thread_started = 1;
  return SANE_STATUS_GOOD;
}

int
lide70_scan_read (unsigned char *buf, int max, int *got)
{
  SANE_Status s;
  size_t n;

  *got = 0;
  if (!handle)
    return SANE_STATUS_INVAL;
  pthread_mutex_lock (&lock);
  while (head == tail && running)
    pthread_cond_wait (&changed, &lock);
  if (head < tail)
    {
      n = tail - head < (size_t) max ? tail - head : (size_t) max;
      memcpy (buf, queue + head, n);
      head += n;
      *got = (int) n;
      s = SANE_STATUS_GOOD;
    }
  else                              /* finished and fully read */
    s = run_status == SANE_STATUS_GOOD ? SANE_STATUS_EOF : run_status;
  pthread_mutex_unlock (&lock);
  return s;
}

void
lide70_scan_cancel (void)
{
  /* The backend's cancel flag is global, so no handle is needed. A cancel
     with nothing running is cleared before the next scan starts. */
  sane_canon_lide70_cancel (NULL);
}

void
lide70_scan_end (void)
{
  unsigned char sink[65536];
  int got;

  if (!handle)
    return;
  if (thread_started)
    {
      lide70_scan_cancel ();        /* still scanning: stop it (no-op if done) */
      pthread_join (scan_thread, NULL);
      thread_started = 0;
      canon_lide70_set_rows_hook (NULL);
      /* The rows were streamed, but the backend also wrote them to a temp
         file, which it only deletes when a read of it reaches EOF. */
      if (run_status == SANE_STATUS_GOOD)
        while (sane_canon_lide70_read (handle, sink, sizeof sink, &got) == SANE_STATUS_GOOD)
          ;
    }
  sane_canon_lide70_close (handle);
  handle = NULL;
  pthread_mutex_lock (&lock);
  free (queue);
  queue = NULL;
  head = tail = capacity = 0;
  pthread_mutex_unlock (&lock);
}

const char *
lide70_status_name (int status)
{
  return sane_strstatus (status);
}
