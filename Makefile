# Canon CanoScan LiDE 70 on macOS: SANE canon_lide70 backend + libusb-1.0 shim.
# Needs: brew install libusb pkg-config
#   make                       # scantest, smoke, usbprobe for the host arch
#   make ARCH="-arch x86_64"   # or another arch
# Sources include "../include/sane/..." relative to their own directory, so the
# top-level include/ is found without any -I for SANE headers.
CC      ?= cc
ARCH    ?=
# Oldest macOS the build supports. Homebrew's libusb-1.0.a is built for the OS it was bottled on, so going
# lower needs a libusb built with a matching -mmacosx-version-min.
MACOS_MIN ?= 27.0
LIBUSB_CFLAGS ?= $(shell pkg-config --cflags libusb-1.0)
LIBUSB_LIBS   ?= $(shell pkg-config --libs libusb-1.0)
CFLAGS  = $(ARCH) -mmacosx-version-min=$(MACOS_MIN) -std=gnu99 -Wall -Wextra -Wno-unused-parameter -Iinclude $(LIBUSB_CFLAGS)
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

# ---- ICA scanner device module (ica/, Swift; structure adapted from Apple's VirtualScanner sample) ----
# Built by Swift Package Manager (Package.swift): target LiDE70C holds the C backend, shim and bridge, and the
# Swift executable imports it as `import LiDE70C`. Package.swift's platform version should match MACOS_MIN.
# This rule wraps the executable in an app bundle.
MODULE       = $(O)/LiDE70Scanner.app
MOD_SRCS     = Package.swift $(wildcard ica/Sources/*.swift) $(wildcard ica/Calibration/*.swift) \
               $(wildcard shim/*.[ch]) backend/canon_lide70.c backend/canon_lide70-common.c
MOD_RES      = ica/Resources/DeviceInfo.plist ica/Resources/DeviceMatchingInfo.plist \
               ica/Resources/ScannerProperties.plist

module: $(MODULE)

$(MODULE): $(MOD_SRCS) ica/Info.plist $(MOD_RES)
	swift build -c release --product LiDE70Scanner
	rm -rf $@
	mkdir -p $@/Contents/MacOS $@/Contents/Resources
	cp "$$(swift build -c release --show-bin-path)/LiDE70Scanner" $@/Contents/MacOS/LiDE70Scanner
	cp ica/Info.plist $@/Contents/Info.plist
	plutil -replace LSMinimumSystemVersion -string $(MACOS_MIN) $@/Contents/Info.plist
	printf 'APPL????' > $@/Contents/PkgInfo
	cp $(MOD_RES) $@/Contents/Resources/
	codesign --force --sign - $@

# Shading calibration: scans the white lid at each resolution and saves the references the module uses.
# Close the lid with nothing on the glass. Pass options with ARGS, e.g. make calibrate ARGS="--dpi 300 --verify".
calibrate:
	swift build -c release --product lide70-calibrate
	"$$(swift build -c release --show-bin-path)/lide70-calibrate" $(ARGS)

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

.PHONY: all clean module calibrate install uninstall
