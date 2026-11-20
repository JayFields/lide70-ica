/* Standalone libusb probe: lists every USB device, then opens/claims any Canon (04a9) device.
   Independent of the SANE backend. Run with LIBUSB_DEBUG=4 for libusb's own log. */
#include <stdio.h>
#include <libusb.h>

int main (void)
{
  libusb_context *ctx = NULL;
  libusb_device **list;
  ssize_t n, i;
  int r = libusb_init (&ctx);
  printf ("libusb_init: %d (%s)\n", r, libusb_error_name (r));
  if (r) return 1;
  n = libusb_get_device_list (ctx, &list);
  printf ("libusb_get_device_list: %d devices\n", (int) n);
  for (i = 0; i < n; i++)
    {
      struct libusb_device_descriptor d;
      libusb_device_handle *h = NULL;
      if (libusb_get_device_descriptor (list[i], &d)) continue;
      printf ("  %04x:%04x bus %d addr %d\n", d.idVendor, d.idProduct,
	      libusb_get_bus_number (list[i]), libusb_get_device_address (list[i]));
      if (d.idVendor != 0x04a9) continue;
      r = libusb_open (list[i], &h);
      printf ("    libusb_open: %d (%s)\n", r, libusb_error_name (r));
      if (r) continue;
      {
	struct libusb_config_descriptor *cfg;
	r = libusb_get_active_config_descriptor (list[i], &cfg);
	printf ("    get_active_config_descriptor: %d (%s)\n", r, libusb_error_name (r));
	if (r == LIBUSB_ERROR_NOT_FOUND)
	  {
	    struct libusb_config_descriptor *c0;
	    r = libusb_get_config_descriptor (list[i], 0, &c0);
	    printf ("    get_config_descriptor(0): %d (%s)\n", r, libusb_error_name (r));
	    if (!r)
	      {
		int v = c0->bConfigurationValue;
		libusb_free_config_descriptor (c0);
		r = libusb_set_configuration (h, v);
		printf ("    set_configuration(%d): %d (%s)\n", v, r, libusb_error_name (r));
		if (!r) r = libusb_get_active_config_descriptor (list[i], &cfg);
		printf ("    get_active_config_descriptor (retry): %d (%s)\n", r, libusb_error_name (r));
	      }
	  }
	if (!r)
	  {
	    int k, j;
	    for (k = 0; k < cfg->bNumInterfaces; k++)
	      {
		const struct libusb_interface_descriptor *a = &cfg->interface[k].altsetting[0];
		printf ("    interface %d: %d endpoints:", a->bInterfaceNumber, a->bNumEndpoints);
		for (j = 0; j < a->bNumEndpoints; j++)
		  printf (" 0x%02x(attr %d)", a->endpoint[j].bEndpointAddress, a->endpoint[j].bmAttributes);
		printf ("\n");
		r = libusb_claim_interface (h, a->bInterfaceNumber);
		printf ("    claim_interface %d: %d (%s)\n", a->bInterfaceNumber, r, libusb_error_name (r));
		if (!r) libusb_release_interface (h, a->bInterfaceNumber);
	      }
	    libusb_free_config_descriptor (cfg);
	  }
      }
      libusb_close (h);
    }
  libusb_free_device_list (list, 1);
  libusb_exit (ctx);
  return 0;
}
