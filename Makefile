# Canon CanoScan LiDE 70 on macOS: SANE canon_lide70 backend + libusb-1.0 shim.
# Needs: brew install libusb pkg-config
#   make                       # scantest, smoke, usbprobe for the host arch
#   make ARCH="-arch x86_64"   # or another arch
# Sources include "../include/sane/..." relative to their own directory, so the
# top-level include/ is found without any -I for SANE headers.
CC      ?= cc
ARCH    ?=
LIBUSB_CFLAGS ?= $(shell pkg-config --cflags libusb-1.0)
LIBUSB_LIBS   ?= $(shell pkg-config --libs libusb-1.0)
CFLAGS  = $(ARCH) -std=gnu99 -Wall -Wextra -Wno-unused-parameter -Iinclude $(LIBUSB_CFLAGS)
O       = build

TOOLS   = scantest smoke usbprobe
CORE    = $(O)/canon.o $(O)/shim.o $(O)/stubs.o

all: $(TOOLS)

scantest: $(CORE) $(O)/scantest.o
	$(CC) $(ARCH) -o $@ $^ $(LIBUSB_LIBS) -lm
smoke: $(CORE) $(O)/smoke.o
	$(CC) $(ARCH) -o $@ $^ $(LIBUSB_LIBS) -lm
usbprobe: tools/usbprobe.c
	$(CC) $(ARCH) -std=gnu99 -Wall -Wextra $(LIBUSB_CFLAGS) -o $@ $< $(LIBUSB_LIBS)

# canon_lide70.c #includes canon_lide70-common.c
$(O)/canon.o: backend/canon_lide70.c backend/canon_lide70-common.c | $(O)
	$(CC) $(CFLAGS) -Ibackend -c $< -o $@
$(O)/shim.o: shim/sanei_usb_libusb.c | $(O)
	$(CC) $(CFLAGS) -c $< -o $@
$(O)/stubs.o: shim/link_stubs.c | $(O)
	$(CC) $(CFLAGS) -c $< -o $@
$(O)/%.o: tools/%.c | $(O)
	$(CC) $(CFLAGS) -c $< -o $@

$(O):
	mkdir -p $@

clean:
	rm -rf $(O) $(TOOLS)

.PHONY: all clean
