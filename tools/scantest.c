/* scantest: drive the canon_lide70 backend through a real scan and write PNM.
 *
 *   ./scantest [out.pnm] [dpi] [color|gray|lineart] [width_mm] [height_mm]
 *
 * Defaults: scan.ppm, 75 dpi, color, 50 x 50 mm from the top-left corner.
 * Output: P6 (color), P5 (gray) or P4 (lineart). Height is taken from the
 * bytes actually returned, so a short/long scan still produces a valid file.
 * Env: SANE_DEBUG_CANON_LIDE70=N for backend debug, LIDE70_SHIM_DEBUG=1 for USB trace.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include "../include/sane/config.h"
#include "../include/sane/sane.h"
#include "../include/sane/saneopts.h"

SANE_Status sane_canon_lide70_init(SANE_Int *, SANE_Auth_Callback);
SANE_Status sane_canon_lide70_get_devices(const SANE_Device ***, SANE_Bool);
void sane_canon_lide70_exit(void);
SANE_Status sane_canon_lide70_open(SANE_String_Const, SANE_Handle *);
void sane_canon_lide70_close(SANE_Handle);
const SANE_Option_Descriptor *sane_canon_lide70_get_option_descriptor(SANE_Handle, SANE_Int);
SANE_Status sane_canon_lide70_control_option(SANE_Handle, SANE_Int, SANE_Action, void *, SANE_Int *);
SANE_Status sane_canon_lide70_get_parameters(SANE_Handle, SANE_Parameters *);
SANE_Status sane_canon_lide70_start(SANE_Handle);
SANE_Status sane_canon_lide70_read(SANE_Handle, SANE_Byte *, SANE_Int, SANE_Int *);
SANE_String_Const sane_strstatus(SANE_Status);

/* Find an option by name rather than hardcoding the backend's enum order. */
static int find_opt(SANE_Handle h, const char *name)
{
  SANE_Int n = 0;
  if (sane_canon_lide70_control_option(h, 0, SANE_ACTION_GET_VALUE, &n, NULL) != SANE_STATUS_GOOD)
    return -1;
  for (int i = 1; i < n; i++) {
    const SANE_Option_Descriptor *d = sane_canon_lide70_get_option_descriptor(h, i);
    if (d && d->name && strcmp(d->name, name) == 0)
      return i;
  }
  return -1;
}

static int set_opt(SANE_Handle h, const char *name, void *val)
{
  int o = find_opt(h, name);
  if (o < 0) { fprintf(stderr, "option '%s' not found\n", name); return -1; }
  SANE_Status s = sane_canon_lide70_control_option(h, o, SANE_ACTION_SET_VALUE, val, NULL);
  if (s != SANE_STATUS_GOOD) {
    fprintf(stderr, "set '%s' failed: %s\n", name, sane_strstatus(s));
    return -1;
  }
  return 0;
}

int main(int argc, char **argv)
{
  const char *out = argc > 1 ? argv[1] : "scan.ppm";
  SANE_Int dpi    = argc > 2 ? atoi(argv[2]) : 75;
  const char *mode = argc > 3 ? argv[3] : "color";
  double wmm      = argc > 4 ? atof(argv[4]) : 50.0;
  double hmm      = argc > 5 ? atof(argv[5]) : 50.0;

  const char *smode;
  if (!strcmp(mode, "color"))        smode = SANE_VALUE_SCAN_MODE_COLOR;
  else if (!strcmp(mode, "gray"))    smode = SANE_VALUE_SCAN_MODE_GRAY;
  else if (!strcmp(mode, "lineart")) smode = SANE_VALUE_SCAN_MODE_LINEART;
  else { fprintf(stderr, "mode must be color|gray|lineart\n"); return 2; }

  SANE_Int ver; const SANE_Device **devs; SANE_Handle h; SANE_Status s;
  int rc = 1;

  if ((s = sane_canon_lide70_init(&ver, NULL)) != SANE_STATUS_GOOD) {
    fprintf(stderr, "sane_init: %s\n", sane_strstatus(s)); return 1;
  }
  s = sane_canon_lide70_get_devices(&devs, SANE_TRUE);
  if (s != SANE_STATUS_GOOD || !devs || !devs[0]) {
    fprintf(stderr, "no scanner found (%s)\n", sane_strstatus(s)); goto out_exit;
  }
  printf("device: %s (%s %s)\n", devs[0]->name, devs[0]->vendor, devs[0]->model);

  if ((s = sane_canon_lide70_open(devs[0]->name, &h)) != SANE_STATUS_GOOD) {
    fprintf(stderr, "sane_open: %s\n", sane_strstatus(s)); goto out_exit;
  }

  /* mode before geometry/resolution: the backend reloads options on mode change */
  char modebuf[64]; snprintf(modebuf, sizeof modebuf, "%s", smode);
  SANE_Fixed zero = SANE_FIX(0.0), bx = SANE_FIX(wmm), by = SANE_FIX(hmm);
  if (set_opt(h, SANE_NAME_SCAN_MODE, modebuf) ||
      set_opt(h, SANE_NAME_SCAN_RESOLUTION, &dpi) ||
      set_opt(h, SANE_NAME_SCAN_TL_X, &zero) ||
      set_opt(h, SANE_NAME_SCAN_TL_Y, &zero) ||
      set_opt(h, SANE_NAME_SCAN_BR_X, &bx) ||
      set_opt(h, SANE_NAME_SCAN_BR_Y, &by))
    goto out_close;

  SANE_Parameters p;
  sane_canon_lide70_get_parameters(h, &p);
  printf("expect: %d px x %d lines, %d bytes/line, depth %d, format %d\n",
         p.pixels_per_line, p.lines, p.bytes_per_line, p.depth, p.format);

  time_t t0 = time(NULL);
  printf("scanning... (head will move)\n"); fflush(stdout);
  if ((s = sane_canon_lide70_start(h)) != SANE_STATUS_GOOD) {
    fprintf(stderr, "sane_start: %s\n", sane_strstatus(s)); goto out_close;
  }
  /* parameters may be adjusted by start (e.g. width rounding) */
  sane_canon_lide70_get_parameters(h, &p);

  size_t cap = 1 << 20, len = 0;
  unsigned char *buf = malloc(cap);
  if (!buf) goto out_close;
  for (;;) {
    if (cap - len < 65536) {
      unsigned char *nb = realloc(buf, cap *= 2);
      if (!nb) { free(buf); goto out_close; }
      buf = nb;
    }
    SANE_Int got = 0;
    s = sane_canon_lide70_read(h, buf + len, 65536, &got);
    if (s == SANE_STATUS_EOF) break;
    if (s != SANE_STATUS_GOOD) {
      fprintf(stderr, "sane_read: %s after %zu bytes\n", sane_strstatus(s), len);
      free(buf); goto out_close;
    }
    len += (size_t)got;
  }
  printf("read %zu bytes in %lds\n", len, (long)(time(NULL) - t0));

  if (p.bytes_per_line <= 0) { fprintf(stderr, "bad bytes_per_line\n"); free(buf); goto out_close; }
  size_t lines = len / (size_t)p.bytes_per_line;
  if (len % (size_t)p.bytes_per_line)
    fprintf(stderr, "warning: %zu trailing bytes (not a whole line)\n", len % (size_t)p.bytes_per_line);
  if ((int)lines != p.lines)
    fprintf(stderr, "note: got %zu lines, backend predicted %d\n", lines, p.lines);

  FILE *f = fopen(out, "wb");
  if (!f) { perror(out); free(buf); goto out_close; }
  const char *magic = p.format == SANE_FRAME_RGB ? "P6" : (p.depth == 1 ? "P4" : "P5");
  if (p.depth == 1)
    fprintf(f, "%s\n%d %zu\n", magic, p.pixels_per_line, lines);
  else
    fprintf(f, "%s\n%d %zu\n255\n", magic, p.pixels_per_line, lines);
  fwrite(buf, 1, lines * (size_t)p.bytes_per_line, f);
  fclose(f);
  free(buf);
  printf("wrote %s (%s %dx%zu)\n", out, magic, p.pixels_per_line, lines);
  rc = 0;

out_close:
  sane_canon_lide70_close(h);
out_exit:
  sane_canon_lide70_exit();
  return rc;
}
