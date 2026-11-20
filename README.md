# lide70-ica

Getting a Canon CanoScan LiDE 70 (USB 04a9:2225; LiDE 600 is 04a9:2224) scanning
on Apple Silicon macOS, with the goal of an Image Capture (ICA) device module.

## Layout

- `backend/` — **vendored, unmodified** from SANE backends
  (https://gitlab.com/sane-project/backends, commit
  `7bf6abe2bd1b1cb916aa87b6a377a7ee70313eb3`): `canon_lide70.c`,
  `canon_lide70-common.c`. SANE's license notes are in `backend/LICENSE.sane`.
- `include/sane/` — vendored SANE headers needed by the backend, plus a
  hand-written minimal `config.h` (no `./configure` is run).
- `shim/sanei_usb_libusb.c` — libusb-1.0 implementation of the `sanei_usb`
  calls the backend uses. Calls `libusb_set_configuration(h, 1)`, which macOS
  requires (the device starts unconfigured). `LIDE70_SHIM_DEBUG=1` traces.
- `shim/link_stubs.c` — minimal stand-ins for `sanei_config_*`,
  `sanei_constrain_value`, `sane_strstatus` and debug init.
  `SANE_DEBUG_CANON_LIDE70=N` enables backend debug output.
- `tools/scantest.c` — full scan to PNM:
  `./scantest [out] [dpi] [color|gray|lineart] [w_mm] [h_mm]`
- `tools/smoke.c` — init / list devices / exit.
- `tools/usbprobe.c` — standalone libusb probe.

- `ica/` — ICA scanner device module, adapted from Apple's VirtualScanner
  sample (imported unmodified in its own commit; Apple sample code license).
  Builds `build/LiDE70Scanner.app`, matching USB 04a9:2225 and 04a9:2224.

## Build

    brew install libusb pkg-config
    make            # tools
    make module     # ICA module (libusb linked statically, ad-hoc signed)
    sudo make install    # copies to /Library/Image Capture/Devices (no build as root)

The module only runs when launched by `icdd` (Image Capture selecting the
scanner); started by hand it quits with "Open Device Failed". Its log:

    /usr/bin/log stream --predicate 'subsystem == "local.lide70ica" OR process == "LiDE70Scanner"'

## Status (verified on an M-series Mac)

- Scans work: 75/150/300/600 dpi, color/gray/lineart; byte counts match the
  backend's predicted parameters. No firmware upload needed. 1200 dpi untested.
- USB claim is exclusive per process on macOS: a second claimant gets
  `LIBUSB_ERROR_ACCESS` (→ `DEVICE_BUSY`) and sends nothing to the device.
  `icdd` and the Image Capture app do not claim the scanner while no ICA
  module exists for it. Untested: whether the ICA host claims it before a
  module does.

## License

GPL v2 or later (the backend is GPL v2+). See `COPYING`.
