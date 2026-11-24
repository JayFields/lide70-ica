/* SPDX-License-Identifier: Apache-2.0 */
#include <stdio.h>
#include <stdlib.h>
#include <stdarg.h>
#include <string.h>
#include "../include/sane/config.h"
#include "../include/sane/sane.h"
#include "../include/sane/sanei.h"
/* Set SANE_DEBUG_CANON_LIDE70=N (1..6) to see backend messages on stderr. */
void sanei_init_debug (const char *n, int *v)
{
  const char *e = getenv ("SANE_DEBUG_CANON_LIDE70");
  (void) n;
  *v = e ? atoi (e) : 0;
}
void sanei_debug_canon_lide70_call (int l, const char *m, ...) { (void)l; (void)m; }
/* Stand-in for the real canon_lide70.conf: the two supported devices. */
FILE *sanei_config_open (const char *f)
{
  FILE *fp = tmpfile ();
  (void) f;
  if (!fp) return NULL;
  fputs ("usb 0x04a9 0x2225\nusb 0x04a9 0x2224\n", fp);
  rewind (fp);
  return fp;
}
char *sanei_config_read (char *s, int n, FILE *fp)
{
  char *r = fgets (s, n, fp);
  if (r) { size_t l = strlen (s); while (l && (s[l-1] == '\n' || s[l-1] == '\r')) s[--l] = 0; }
  return r;
}
SANE_Status sanei_constrain_value (const SANE_Option_Descriptor *o, void *v, SANE_Word *i) { (void)o;(void)v;(void)i; return SANE_STATUS_GOOD; }
const char *sane_strstatus (SANE_Status s) {
  static const char *n[] = { "GOOD", "UNSUPPORTED", "CANCELLED", "DEVICE_BUSY", "INVAL",
    "EOF", "JAMMED", "NO_DOCS", "COVER_OPEN", "IO_ERROR", "NO_MEM", "ACCESS_DENIED" };
  return (unsigned)s < sizeof n / sizeof n[0] ? n[s] : "UNKNOWN"; }
void sanei_debug_msg (int l, int max, const char *be, const char *fmt, va_list ap)
{ (void)be; if (l <= max) vfprintf (stderr, fmt, ap); }
