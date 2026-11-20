/* Minimal libusb-1.0 implementation of the sanei_usb entry points canon_lide70 uses.
   Device names are "libusb:BUS:ADDR". Not a general sanei_usb replacement. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "../include/sane/config.h"
#include "../include/sane/sane.h"
#include <libusb.h>

#define MAX_DEVS 8

/* Set LIDE70_SHIM_DEBUG=1 for tracing that does not depend on the SANE debug machinery. */
#define TR(...) do { if (getenv ("LIDE70_SHIM_DEBUG")) { fprintf (stderr, "shim: " __VA_ARGS__); fputc (10, stderr); } } while (0)

typedef struct
{
  libusb_device_handle *h;
  int iface, used;
  unsigned char ep_in, ep_out;
  SANE_Word vid, pid;
} usb_dev;

static libusb_context *ctx;
static unsigned int timeout_ms = 30000;
static usb_dev devs[MAX_DEVS];

void
sanei_usb_init (void)
{
  if (!ctx)
    libusb_init (&ctx);
}

void
sanei_usb_set_timeout (SANE_Int ms)
{
  timeout_ms = ms;
}

SANE_Status
sanei_usb_attach_matching_devices (const char *line,
				   SANE_Status (*attach) (const char *))
{
  unsigned vid = 0, pid = 0;
  libusb_device **list;
  ssize_t n, i;

  TR ("attach_matching_devices(\"%s\")", line);
  if (sscanf (line, "usb %i %i", &vid, &pid) != 2)
    return SANE_STATUS_GOOD;	/* only "usb VID PID" lines are meaningful */
  n = libusb_get_device_list (ctx, &list);
  for (i = 0; i < n; i++)
    {
      struct libusb_device_descriptor d;
      char name[32];
      if (libusb_get_device_descriptor (list[i], &d)
	  || d.idVendor != vid || d.idProduct != pid)
	continue;
      snprintf (name, sizeof name, "libusb:%03d:%03d",
		libusb_get_bus_number (list[i]),
		libusb_get_device_address (list[i]));
      attach (name);
    }
  libusb_free_device_list (list, 1);
  return SANE_STATUS_GOOD;
}

SANE_Status
sanei_usb_open (SANE_String_Const name, SANE_Int * dn)
{
  int bus, addr, k, i, j, e, r;
  libusb_device **list, *found = NULL;
  ssize_t n;
  struct libusb_device_descriptor d;
  struct libusb_config_descriptor *cfg;
  usb_dev *p;

  if (sscanf (name, "libusb:%d:%d", &bus, &addr) != 2)
    return SANE_STATUS_INVAL;
  for (k = 0; k < MAX_DEVS && devs[k].used; k++);
  if (k == MAX_DEVS)
    return SANE_STATUS_NO_MEM;

  n = libusb_get_device_list (ctx, &list);
  for (i = 0; i < n; i++)
    if (libusb_get_bus_number (list[i]) == bus
	&& libusb_get_device_address (list[i]) == addr)
      {
	found = libusb_ref_device (list[i]);
	break;
      }
  libusb_free_device_list (list, 1);
  if (!found)
    return SANE_STATUS_INVAL;

  p = &devs[k];
  memset (p, 0, sizeof *p);
  libusb_get_device_descriptor (found, &d);
  p->vid = d.idVendor;
  p->pid = d.idProduct;
  r = libusb_open (found, &p->h);
  TR ("open %s: %d (%s)", name, r, libusb_error_name (r));
  if (r)
    {
      libusb_unref_device (found);
      return SANE_STATUS_ACCESS_DENIED;
    }
  /* find first interface with a bulk IN and a bulk OUT endpoint */
  r = libusb_get_active_config_descriptor (found, &cfg);
  TR ("get_active_config_descriptor: %d (%s)", r, libusb_error_name (r));
  if (r == LIBUSB_ERROR_NOT_FOUND)
    {
      /* Device is unconfigured (seen on macOS): select its first configuration. */
      struct libusb_config_descriptor *c0;
      r = libusb_get_config_descriptor (found, 0, &c0);
      TR ("get_config_descriptor(0): %d (%s)", r, libusb_error_name (r));
      if (!r)
	{
	  int val = c0->bConfigurationValue;
	  libusb_free_config_descriptor (c0);
	  r = libusb_set_configuration (p->h, val);
	  TR ("set_configuration(%d): %d (%s)", val, r, libusb_error_name (r));
	  if (!r)
	    r = libusb_get_active_config_descriptor (found, &cfg);
	  TR ("get_active_config_descriptor (retry): %d (%s)", r, libusb_error_name (r));
	}
    }
  if (r)
    {
      libusb_close (p->h);
      libusb_unref_device (found);
      return SANE_STATUS_IO_ERROR;
    }
  for (i = 0; i < cfg->bNumInterfaces && !p->used; i++)
    {
      const struct libusb_interface_descriptor *a = &cfg->interface[i].altsetting[0];
      unsigned char in = 0, out = 0;
      for (j = 0; j < a->bNumEndpoints; j++)
	{
	  e = a->endpoint[j].bEndpointAddress;
	  if ((a->endpoint[j].bmAttributes & LIBUSB_TRANSFER_TYPE_MASK)
	      != LIBUSB_TRANSFER_TYPE_BULK)
	    continue;
	  if (e & LIBUSB_ENDPOINT_IN) { if (!in) in = e; }
	  else if (!out) out = e;
	}
      if (in && out)
	{
	  p->iface = a->bInterfaceNumber;
	  p->ep_in = in;
	  p->ep_out = out;
	  p->used = 1;
	}
    }
  libusb_free_config_descriptor (cfg);
  libusb_unref_device (found);
  if (!p->used)
    {
      libusb_close (p->h);
      return SANE_STATUS_UNSUPPORTED;
    }
  libusb_set_auto_detach_kernel_driver (p->h, 1);	/* no-op where unsupported */
  r = libusb_claim_interface (p->h, p->iface);
  TR ("claim_interface(%d): %d (%s), ep_in 0x%02x ep_out 0x%02x", p->iface, r,
      libusb_error_name (r), p->ep_in, p->ep_out);
  if (r)
    {
      libusb_close (p->h);
      p->used = 0;
      return SANE_STATUS_DEVICE_BUSY;
    }
  *dn = k;
  return SANE_STATUS_GOOD;
}

void
sanei_usb_close (SANE_Int dn)
{
  usb_dev *p = &devs[dn];
  if (dn < 0 || dn >= MAX_DEVS || !p->used)
    return;
  libusb_release_interface (p->h, p->iface);
  libusb_close (p->h);
  p->used = 0;
}

SANE_Status
sanei_usb_get_vendor_product (SANE_Int dn, SANE_Word * vendor,
			      SANE_Word * product)
{
  if (dn < 0 || dn >= MAX_DEVS || !devs[dn].used)
    return SANE_STATUS_INVAL;
  *vendor = devs[dn].vid;
  *product = devs[dn].pid;
  return SANE_STATUS_GOOD;
}

SANE_Status
sanei_usb_read_bulk (SANE_Int dn, SANE_Byte * buf, size_t * size)
{
  int got = 0, r;
  if (dn < 0 || dn >= MAX_DEVS || !devs[dn].used)
    return SANE_STATUS_INVAL;
  r = libusb_bulk_transfer (devs[dn].h, devs[dn].ep_in, buf, (int) *size,
			    &got, timeout_ms);
  if (r == LIBUSB_ERROR_PIPE)
    libusb_clear_halt (devs[dn].h, devs[dn].ep_in);
  *size = got;
  if (r == 0 || (r == LIBUSB_ERROR_TIMEOUT && got > 0))
    return SANE_STATUS_GOOD;
  return got == 0 && r == LIBUSB_ERROR_TIMEOUT ? SANE_STATUS_EOF : SANE_STATUS_IO_ERROR;
}

SANE_Status
sanei_usb_write_bulk (SANE_Int dn, const SANE_Byte * buf, size_t * size)
{
  int got = 0, r;
  if (dn < 0 || dn >= MAX_DEVS || !devs[dn].used)
    return SANE_STATUS_INVAL;
  r = libusb_bulk_transfer (devs[dn].h, devs[dn].ep_out, (unsigned char *) buf,
			    (int) *size, &got, timeout_ms);
  if (r == LIBUSB_ERROR_PIPE)
    libusb_clear_halt (devs[dn].h, devs[dn].ep_out);
  *size = got;
  return r == 0 ? SANE_STATUS_GOOD : SANE_STATUS_IO_ERROR;
}
