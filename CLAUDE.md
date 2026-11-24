# CLAUDE.md

Image Capture device module (Swift) for the Canon CanoScan LiDE 70 / LiDE 600, wrapping the SANE
`canon_lide70` backend (C). Personal learning project: the user prefers reading Swift. See README.md for
layout, build and status; don't duplicate it here.

## Build, install, test

- `make` (C tools), `make module` (bundle via `swift build`; needs `ica/Resources/StripCalibration.plist`).
- `make pkg` builds `build/LiDE70Scanner-<version>.pkg` (pkgbuild + productbuild, files in `installer/`),
  which installs the module into `/Library/Image Capture/Devices/`. The user installs it (opening the .pkg,
  or `sudo installer -pkg … -target /`; they run anything that needs sudo); then have them quit and reopen
  Image Capture. The component is not relocatable on purpose: otherwise Installer updates
  `build/LiDE70Scanner.app` in place instead. Payload `._` entries are the `com.apple.provenance`
  attribute every new file gets here; they can't be stripped and are harmless.
- The module only runs when icdd launches it (Image Capture or Preview selecting the scanner). Started by hand
  it quits with "Open Device Failed". So every module change needs install + a test by the user.
- Read results from the log: `/usr/bin/log show --last 15m --style compact --predicate 'subsystem == "local.lide70ica"'`.
  Use the full path: zsh's builtin `log` shadows `/usr/bin/log`. Each scan logs request, the white-strip
  reading, backend format, "applying strip calibration", rows delivered.
- Check that the installed binary is the current build before reading logs:
  `cmp "/Library/Image Capture/Devices/LiDE70Scanner.app/Contents/MacOS/LiDE70Scanner" build/LiDE70Scanner.app/Contents/MacOS/LiDE70Scanner`.
- The bridge and backend can be tested on the scanner without installing: small C programs linked against
  `build/*.o` and libusb (keep them in the scratchpad, not the repo), or `make verify-strip`.
- Saved scans go to `~/Pictures` (Image Capture); Preview opens them as untitled documents and keeps no file.

## Constraints learned the hard way (don't retry these)

- `start` must block until the image is delivered: image data in progress notifications sent after `start`
  returns is not shown. Returning early, or sending notifications from another thread, both broke the overview.
- ICADevices calls back one callback at a time, so Image Capture's cancel message ('cans') only arrives after
  `start` returns. Cancel works through the "user cancelled" reply to a data band. Empty progress
  notifications get no cancel reply.
- Hence the design: the bridge runs `sane_start` on its own thread and streams rows via the backend's rows
  hook; `start` sends bands as rows arrive.
- Only one process can claim the scanner (macOS exclusive USB ownership). A stuck module blocks every other
  scan; kill it (with the user's OK) and have them replug the scanner.
- The backend scans everything to a temp file `/tmp/scan.XXXXXX`; check for leftovers with
  `ls /tmp/scan.* | wc -l` (`| head` hides extra matches).

## Vendored backend

- `backend/` is from SANE commit 7bf6abe2 (README). Keep changes minimal and mark each with `lide70-ica`;
  `git diff dc0d33e -- backend/` shows them all.
- `canon_lide70.c` #includes `canon_lide70-common.c`; `sanei_backend.h` defines signal macros, so don't
  include `<signal.h>` there.
- Hardware: controller Philips CP2155BE (no public datasheet; registers known only from the backend), analog
  front end Holtek HT82V36 (datasheet public: single channel, PGA register 3, offset register 6). The CP2155
  writes the AFE via registers 0x85 (address), 0x87 (data bit 8), 0x88 (data bits 7-0).

## Shading calibration (see README)

- Goal: the module is meant for other LiDE 70 owners, who must never calibrate. Every scan calibrates itself
  from its scanner's internal white strip; only per-color glass/strip factors (+ gain codes) ship, in
  `ica/Resources/StripCalibration.plist`. Don't ship per-column data measured on the developer's scanner.
- `make strip-factors` remeasures the factors (lid closed, glass clear, ~2 min); `make verify-strip` checks
  against whatever white is on the glass. Both scan the user's hardware: ask first, and say what must be on
  the glass.
- Strip and glass readings are only comparable at the same gain code (32; 600 dpi 26), the same strip band
  (`WhiteStrip.band`, narrower at 1200 dpi) and the same session: the scanner switches between response
  states (~4% column pattern, cause unknown). Changing the band or a gain means re-running
  `make strip-factors` for that resolution.
- The module reuses a strip reading for 10 minutes (`stripReadingLifetime` in Scan.swift); the log says
  "read in" or "reused".
- If every scan takes ~30 s and returns no data (bridge: I/O error), the scanner has stopped answering USB:
  have the user unplug and replug it. A scan whose data stops partway fails (`maxMissingRows` in Scan.swift);
  icdd's "[Removed] ... CanoScan" log lines show whether the scanner dropped off USB (bus-powered: suspect
  power or the cable).
- Faint vertical bands in a calibrated scan: check the module log's "white strip" line, then
  `make verify-strip`.
- Test with real data across conditions (both scanner states, lid and paper), not only the current one.

## Swift and C gotchas

- In Swift `>>` binds tighter than `*`: write `(a * b) >> 8`.
- `@preconcurrency import ICADevices` (Swift 6 mode rejects writing `gICDScannerCallbackFunctions` otherwise).
- Swift doesn't import C macros that are expressions; add a `static const` to the header.
- Read numbers from ICA dictionaries through `NSNumber` (`as? Int` fails on non-integral values).
- Open `Package.swift` in Xcode, not single files: alone, `Scanner`/`log` resolve to Foundation/Darwin symbols.

## Working conventions

- Commit only when the user asks; commit messages explain the why and what was verified.
- Built for macOS 27 (`MACOS_MIN` in the Makefile and `platforms` in Package.swift must match) because
  Homebrew's static libusb is.
- License: the program is GPLv3 (COPYING; the backend is GPL v2+ without the SANE exception); this project's own files are Apache-2.0 (LICENSE-APACHE), marked with an SPDX line only (no copyright line), and new files should be too. See README "License". The module's structure follows Apple's VirtualScanner sample (in git history).
