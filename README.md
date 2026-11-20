# lide70-ica

Getting a Canon CanoScan LiDE 70 (USB 04a9:2225; LiDE 600 is 04a9:2224) scanning
on Apple Silicon macOS, with the goal of an Image Capture (ICA) device module.

## Layout

- `backend/` — **vendored** from SANE backends
  (https://gitlab.com/sane-project/backends, commit
  `7bf6abe2bd1b1cb916aa87b6a377a7ee70313eb3`): `canon_lide70.c`,
  `canon_lide70-common.c`. SANE's license notes are in `backend/LICENSE.sane`.
  Local changes, marked `lide70-ica` in the source (see
  `git diff d97b700 -- backend/`):
  - `sane_cancel` stops a scan running in `sane_start` (upstream it is a
    no-op); `canon_lide70_clear_cancel()` drops a late cancel.
  - `canon_lide70_set_rows_hook()` passes each batch of finished rows to a
    callback while `sane_start` is still scanning, so they can be streamed.
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

- `shim/lide70_scan.c` — C bridge over the backend (begin/read/end a scan).
- `ica/` — ICA scanner device module in Swift, matching USB 04a9:2225 and
  04a9:2224; builds `build/LiDE70Scanner.app`. Its structure follows Apple's
  VirtualScanner sample (the original Objective-C sample and its adaptation
  are in the git history). Swift calls the C code as `import LiDE70C` (see `Package.swift`).
  - `main.swift` registers the C callbacks and runs `ICD_ScannerMain`
  - `EntryPoints.swift` the callbacks, forwarding to `LiDE70Device`
  - `LiDE70Device.swift` device properties, sessions, Get/SetParameters
  - `ScannerSettings.swift` the TWAIN-style capability dictionary
  - `Scan.swift` runs a scan through the bridge and delivers rows
  - `DocumentWriter.swift` ICA raw file and conversion to JPEG/TIFF/…

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
  The ICA host does not claim the scanner: the module's own libusb claim works.
- Image Capture with the Swift module: overview (75 dpi) and 300 dpi scans in
  all three modes saved correctly, at exactly the requested size.
  - Color: RGB JPEG. Black and White: 8-bit gray JPEG.
  - Text: Image Capture asks for 8-bit gray as an ICA raw file and makes the
    1-bit (CCITT G4) TIFF itself, so the module's own black & white threshold
    path (`TWPT_BW`) is not used by Image Capture.
  - Streaming and cancel: `start` must not return before the image is
    delivered (with an early return Image Capture showed no overview), and
    ICADevices delivers Image Capture's 'cans' cancel message only after
    `start` returns. So the bridge scans on its own thread and streams rows
    while the head moves; `start` sends them in bands, and the client's
    "cancelled" reply to a band stops the scanner. Verified in Image
    Capture: overview; a nearly full page at 600 dpi (4976x6472, 33 s)
    saved correctly; Cancel stops the scanner ~1.7 s after the click.
  - Untested: a complete 1200 dpi scan, Preview.
- Built for macOS 27 (`MACOS_MIN` in the Makefile), because Homebrew's static
  libusb is.

## License

GPL v2 or later (the backend is GPL v2+). See `COPYING`.
