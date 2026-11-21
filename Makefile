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
               ica/Resources/ScannerProperties.plist ica/Resources/StripCalibration.plist

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

# Strip calibration (developer only; users never calibrate). Every scan calibrates itself from the scanner's
# internal white strip, scaled by glass/strip factors shipped in ica/Resources/StripCalibration.plist.
#   make strip-factors   measure the factors from the white lid (lid closed, nothing on the glass) and
#                        rewrite that file; commit it
#   make verify-strip    check strip-only correction against the white on the glass (lid or paper)
# Options with ARGS, e.g. make verify-strip ARGS="--dpi 300 --top 20".
CALIBRATE = "$$(swift build -c release --show-bin-path)/lide70-calibrate"

strip-factors:
	swift build -c release --product lide70-calibrate
	$(CALIBRATE) derive $(ARGS)

verify-strip:
	swift build -c release --product lide70-calibrate
	$(CALIBRATE) verify $(ARGS)

# ---- Installer package ----
# `make pkg` builds build/LiDE70Scanner-<version>.pkg, which installs the module into
# /Library/Image Capture/Devices (owned by root:wheel). icdd launches it when Image Capture selects the scanner.
# Open the .pkg, or: sudo installer -pkg build/LiDE70Scanner-<version>.pkg -target /
# The version is CFBundleShortVersionString in ica/Info.plist. Unsigned by default; to sign, pass
# PKG_SIGN="Developer ID Installer: Name (TEAMID)" (an Apple Developer Program certificate).
VERSION   := $(shell /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' ica/Info.plist)
PKG       = $(O)/LiDE70Scanner-$(VERSION).pkg
PKG_ID    = local.lide70ica.module
PKG_SIGN ?=
PKG_STAGE = $(O)/pkgroot

pkg: $(PKG)

$(PKG): $(MODULE) installer/Distribution.xml installer/component.plist installer/resources/conclusion.html COPYING
	rm -rf $(PKG_STAGE) $(O)/pkgres
	mkdir -p $(PKG_STAGE) $(O)/pkgres
	ditto --norsrc --noextattr --noqtn $(MODULE) $(PKG_STAGE)/LiDE70Scanner.app
	COPYFILE_DISABLE=1 pkgbuild --root $(PKG_STAGE) --component-plist installer/component.plist --identifier $(PKG_ID) \
	  --version $(VERSION) --install-location "/Library/Image Capture/Devices" --ownership recommended $(O)/LiDE70Scanner-component.pkg
	cp installer/resources/conclusion.html $(O)/pkgres/
	cp COPYING $(O)/pkgres/COPYING
	sed -e 's/@VERSION@/$(VERSION)/g' -e 's/@MACOS_MIN@/$(MACOS_MIN)/g' installer/Distribution.xml \
	  > $(O)/Distribution.xml
	productbuild --distribution $(O)/Distribution.xml --resources $(O)/pkgres --package-path $(O) \
	  $(if $(PKG_SIGN),--sign "$(PKG_SIGN)") $@
	rm -rf $(PKG_STAGE) $(O)/pkgres $(O)/Distribution.xml $(O)/LiDE70Scanner-component.pkg

clean:
	rm -rf $(O) $(TOOLS)

.PHONY: all clean module pkg strip-factors verify-strip
