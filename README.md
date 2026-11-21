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
  - `canon_lide70_set_afe_gain()` sets the analog front end's gain code
    (upstream: fixed 40).
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
- `ica/Calibration/` — calibration library (Swift): `StripCalibration.swift`
  (shipped factors, reference from the strip), `WhiteStrip.swift` (reading the
  strip, linear scans), `ShadingCalibration.swift` (white references and the
  per-column correction).
- `ica/Resources/StripCalibration.plist` — the glass/strip factors, measured
  once with `make strip-factors`; shipped in the module bundle.
- `tools/calibrate/` — `lide70-calibrate`, the developer tool that measures and
  verifies those factors.

## Build

    brew install libusb pkg-config
    make            # tools
    make module     # ICA module (libusb linked statically, ad-hoc signed)
    sudo make install    # copies to /Library/Image Capture/Devices (no build as root)

Users don't calibrate: every scan calibrates itself (below).

## Shading calibration

The backend does no calibration of its own: it loads one gamma table for all
three colors and nothing per column. A white page therefore came out pink
(the sensor reads green ~11% lower than red and blue) with vertical bands
(columns differ by ~5%, up to ~12%).

**Every scan calibrates itself from the scanner's internal white strip.**
Before a scan, the module reads the strip (a short linear scan just before the
glass: 1.2 s for 75–300 dpi, 1.8 s at 600, 9 s at 1200; 75 and 150 dpi use a
300 dpi reading, averaged down). A reading is reused for 10 minutes at the same
strip resolution and gain, so an overview and the scan after it share one; the
scanner's response state (below) has held through every run of consecutive
scans seen, but does change, so readings expire. The strip
is not quite the same white as the glass, so its reading is scaled by fixed
glass/strip factors per color and resolution, from
`ica/Resources/StripCalibration.plist`. The result is the white reference:
per sensor column and color, how bright white on the glass reads. The module
then scans linear color, scales each column so its white becomes 255, and
applies the backend's 2.2 gamma in software; gray and black & white are made
from the corrected color. Saturated strip readings are filled in from their
neighbours; if the strip reading fails or looks wrong (level outside
0.6–1.4 of the measured scanner's, more than 15% saturated), the scan goes
ahead uncorrected, and the module logs why.

**The factors are measured once, by the developer, and ship with the module.**
`make strip-factors` reads the strip and a band of the white lid at each
resolution (lid closed, nothing on the glass) and rewrites the plist; commit
it. Only per-color factors are shipped, not a per-column map: a map measured on
one scanner would carry that scanner's strip (its dust, its unevenness) to
every other one. On the test scanner: R 0.887, G 0.905, B 0.908 (75–300 dpi),
0.907 / 0.925 / 0.928 (600 dpi), 0.876 / 0.895 / 0.897 (1200 dpi, read from a
narrower band of the strip; see below). Other LiDE 70s are assumed to have
similar factors; that is untested (only one scanner was available).

If the scanner stops answering over USB (it has happened twice; unplugging it
fixes it), the backend would end the scan as if complete with no data; the
bridge reports that as an I/O error, so Image Capture shows a failed scan rather
than a blank page.

`make verify-strip` checks the result against whatever white is on the glass
(`ARGS="--top MM"` picks the band). On the test scanner, on the lid, from
~3.5–4% column variation to 0.7–0.8% (R), 0.9–1.0% (G), 1.3–1.5% (B), with
neutral color (R/G 0.995–0.997, B/G 1.002–1.003). A per-column calibration
against the lid reached ~0.7–1.1%: the strip's pattern differs a little from
the glass's (0.7–1.1%, most in blue). Why the strip rather than a stored
calibration: the scanner switches, for reasons not yet known, between response
states ~4% apart in column pattern, and a stored calibration made in one state
left faint bands in the other; the strip follows the state.

**Analog gain.** The analog front end is a Holtek HT82V36 (one channel: one
gain for all three colors), which the backend programs through the CP2155
controller's AFE port (registers 0x85 address, 0x87 data bit 8, 0x88 data bits
7–0) with PGA code 40, ~2.11x (gain = 5.85 / (1 + 4.85 (63 − code) / 63)). At
that gain plain white paper saturated in about a third of red and half of blue
columns. Calibrated scans use code 32 (~1.73x, ~8% headroom); 600 dpi, which
the backend sets up with a different color balance (red weak, blue strong),
uses 26 for the same headroom on the strip. The codes are in the factors file.
Uncalibrated scans keep the backend's gain.

### Internal white strip

The scanner has a white strip just before the glass, presumably the reference
Canon's own driver calibrated against. Findings (no documentation found;
measured with test programs, linear values):

- **Where:** reachable only at 300 dpi and above, by starting a scan above the
  usual top: the backend adds a 7 mm `top_edge` there, so a top of −7 mm
  reaches the head's park position (at 75 and 150 dpi the scan starts on the
  glass). In those coordinates: −7 to −6.5 mm dark housing; **−5.5 to −2 mm
  white**; the glass from about −0.5 mm. It stays white with the lid open or a
  black cover on the glass, so it is part of the scanner. Read from −5.0 to
  −2.5 mm; at 1200 dpi, where the head moves slowly, from −4.5 to −3.3 mm
  (9.0 s instead of 11.8 s; same pattern to within a repeat's noise, but its
  middle reads ~1% brighter than the wide band, so the factors are measured with
  the same band). Most of the remaining time is fixed: a 0.8 mm band takes as
  long.
- **Stable:** its per-column pattern repeats to 0.3–0.5% between passes, and
  does not depend on what is on the glass (black cover vs white paper:
  0.44–0.47%, the same as repeats). A black cover lowers its overall level by
  ~1% (less stray light from a white page).
- **Accurate:** on white paper at gain 32, correcting with the strip alone left
  0.8–1.2% column variation at 75–300 and 1200 dpi, as good as or better than a
  per-column lid calibration (1.1–1.3%), against a paper noise floor of
  0.6–0.8%. The strip is ~5–10% brighter than white on the glass, and slightly
  less so in blue, hence the per-color factors.
- **Saturation, solved by the lower gain:** at the backend's code 40, 70–72% of
  red and 61–66% of blue strip columns read 255; at 36: 2% / 1%; at 34 and 32:
  none (600 dpi blue needs 26). Levels follow the HT82V36 gain curve to ~1%.
- **State changes:** in the scanner's second response state the strip's
  pattern differs ~4% and its level ~2% from the first, exactly as the glass's
  does (scaling a calibration by the strip's change brought a state-changed scan
  from 4.1% to 0.8%), which is why it is read before every scan.

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
