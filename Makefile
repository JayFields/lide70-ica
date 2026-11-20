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

# ---- ICA scanner device module (ica/, adapted from Apple's VirtualScanner sample) ----
# libusb is linked statically so the bundle does not depend on Homebrew at runtime.
MODULE      = $(O)/LiDE70Scanner.app
MOD_SRCS    = $(wildcard ica/Sources/*.m)
MOD_OBJS    = $(patsubst ica/Sources/%.m,$(O)/ica/%.o,$(MOD_SRCS))
MOD_HDRS    = $(wildcard ica/Includes/*.h) ica/VirtualScanner_Prefix.pch shim/lide70_usb.h
MOD_CFLAGS  = $(ARCH) -fno-objc-arc -include ica/VirtualScanner_Prefix.pch -Iica/Includes -Ishim \
              -DSCANNER_DEBUG=1 -Wall -Wno-deprecated-declarations
LIBUSB_A   ?= $(shell pkg-config --variable=libdir libusb-1.0)/libusb-1.0.a
MOD_LIBS    = $(LIBUSB_A) -framework Cocoa -framework ICADevices -framework IOKit \
              -framework DiskArbitration -framework Carbon -framework Security -lobjc
MOD_RES     = ica/Resources/DeviceInfo.plist ica/Resources/DeviceMatchingInfo.plist \
              ica/Resources/ScannerProperties.plist

module: $(MODULE)

$(O)/ica/%.o: ica/Sources/%.m $(MOD_HDRS) | $(O)
	@mkdir -p $(O)/ica
	$(CC) $(MOD_CFLAGS) -c $< -o $@

$(MODULE): $(MOD_OBJS) $(O)/shim.o ica/VirtualScanner-Info.plist $(MOD_RES)
	rm -rf $@
	mkdir -p $@/Contents/MacOS $@/Contents/Resources/English.lproj
	$(CC) $(ARCH) -o $@/Contents/MacOS/LiDE70Scanner $(MOD_OBJS) $(O)/shim.o $(MOD_LIBS)
	cp ica/VirtualScanner-Info.plist $@/Contents/Info.plist
	printf 'APPL????' > $@/Contents/PkgInfo
	cp $(MOD_RES) $@/Contents/Resources/
	cp ica/Resources/English.lproj/InfoPlist.strings $@/Contents/Resources/English.lproj/
	codesign --force --sign - $@

# Install/uninstall only copy (no build dependency), so `sudo make install` never builds as root.
# Run `make module` first. icdd launches the module when Image Capture selects the scanner.
DEVICES_DIR = /Library/Image Capture/Devices

install:
	@test -d $(MODULE) || { echo "run 'make module' first"; exit 1; }
	rm -rf "$(DEVICES_DIR)/LiDE70Scanner.app"
	ditto $(MODULE) "$(DEVICES_DIR)/LiDE70Scanner.app"
	chown -R root:wheel "$(DEVICES_DIR)/LiDE70Scanner.app"

uninstall:
	rm -rf "$(DEVICES_DIR)/LiDE70Scanner.app"

clean:
	rm -rf $(O) $(TOOLS)

.PHONY: all clean module install uninstall
