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
  - `go_home` times out (30 s) instead of waiting forever.
  - `canon_lide70_set_linear_gamma()` loads identity gamma tables, so the
    scanner returns linear sensor values (for shading calibration).
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
- `ica/Calibration/ShadingCalibration.swift` — shading calibration: white
  references per resolution, and the per-column correction (Swift library).
- `tools/calibrate/` — `lide70-calibrate`, which measures the calibration from
  the white lid.

## Build

    brew install libusb pkg-config
    make            # tools
    make module     # ICA module (libusb linked statically, ad-hoc signed)
    sudo make install    # copies to /Library/Image Capture/Devices (no build as root)
    make calibrate  # once per scanner: lid closed, nothing on the glass

## Shading calibration

The backend does no calibration of its own: it loads one gamma table for all
three colors and nothing per column. A white page therefore came out pink
(the sensor reads green ~11% lower than red and blue) with vertical bands
(columns differ by ~5%, up to ~12%).

`make calibrate` scans a strip of the white lid at each resolution with the
gamma switched off and saves, per sensor column and color, how bright white
reads: `~/Library/Application Support/LiDE70Scanner/Calibration.plist`. The
module then scans linear color, scales each column so its white becomes 255,
and applies the backend's 2.2 gamma in software; gray and black & white are
made from the corrected color. Without a calibration for a resolution, the
module scans as before and logs that it is uncorrected.

`make calibrate ARGS="--verify"` (or `--verify-only`) scans another strip,
37 mm from the left, and reports the column variation before and after
correction and the column alignment. On the test scanner: ~5% before,
~0.8–1.1% after, at every resolution; alignment exact.

At 600 dpi the backend's settings make blue saturate on white (and red read
weak), so very light colors lose some detail in blue at that resolution.

The calibration is a snapshot: nothing recalibrates automatically. LED
brightness drifts slowly with age; rerun `make calibrate ARGS="--verify-only"`
now and then, and recalibrate if the corrected variation rises well above ~2%.

### Internal white strip

The scanner has a white strip just before the glass, presumably the reference
Canon's own driver calibrated against. It is a better candidate for the
authoritative calibration target than the lid, which was only a convenient
white surface; what stops it today is exposure. Findings (no documentation
found; measured at 300 dpi with test programs, linear values):

- **Where:** reachable only at 300 dpi and above, by starting a scan above the
  usual top: the backend adds a 7 mm `top_edge` there, so a top of −7 mm
  reaches the head's park position (at 75 and 150 dpi the scan starts on the
  glass). In those coordinates: −7 to −6.5 mm dark housing; **−5.5 to −2 mm
  white**; the glass from about −0.5 mm. It stays white with the lid open or a
  black cover on the glass, so it is part of the scanner.
- **Stable:** its per-column pattern repeats to 0.40–0.47% between passes, and
  does not depend on what is on the glass (black cover vs white paper:
  0.44–0.47%, the same as repeats). A black cover lowers its overall level by
  ~1% (less stray light from a white page).
- **Accurate:** its pattern is within 0.73–0.84% of the lid reference. On a
  sheet of white paper on the glass, both references bring the column
  variation from ~5% to ~1% (green: strip 0.93%, lid 0.61–0.76%, against a
  noise floor of 0.80%; the strip leaves a small repeatable ~0.7% pattern,
  perhaps because it is at a different distance from the sensor than the glass).
- **Blocker, saturation:** the strip is ~7% brighter than the lid. At the
  backend's fixed exposure, 70–72% of red and 61–66% of blue columns read 255
  (green never does), and a saturated column only says "at least this bright".
  Using the strip as the reference needs lower exposure via the CP2155's
  registers, which are undocumented.
- **An outlier pass:** one of six passes read ~3% darker overall and its pattern
  differed ~4% from all others; the cause is unknown (not what was on the
  glass). Per-scan calibration from the strip should check each reading
  against a stored pattern and fall back when it is off.
- Meanwhile its green level could serve for drift detection: record it at
  calibration time, re-read it at the start of a scan, and warn when it moves.

The module only runs when launched by `icdd` (Image Capture selecting the
scanner); started by hand it quits with "Open Device Failed". Its log:

    /usr/bin/log stream --predicate 'subsystem == "local.lide70ica" OR process == "LiDE70Scanner"'

## Status (verified on an M-series Mac)

- Scans work: 75–1200 dpi, color/gray/lineart; byte counts match the
  backend's predicted parameters. No firmware upload needed.
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
  - 1200 dpi: a nearly full page (9952x12944, ~386 MB raw) took 7 min 49 s
    and saved correctly; the image resolves the print's halftone dots.
  - Preview (File > Import from Scanner): overview and 150 dpi area scans
    opened correctly. Like Image Capture, it runs an overview automatically
    when the scanner is selected; that is the client's choice
    (`requestOverviewScan`), not something the module controls.
- Built for macOS 27 (`MACOS_MIN` in the Makefile), because Homebrew's static
  libusb is.

## License

GPL v2 or later (the backend is GPL v2+). See `COPYING`.
