# CLAUDE.md

Image Capture device module (Swift) for the Canon CanoScan LiDE 70 / LiDE 600, wrapping the SANE
`canon_lide70` backend (C). Personal learning project: the user prefers reading Swift. See README.md for
layout, build and status; don't duplicate it here.

## Build, install, test

- `make` (C tools), `make module` (bundle via `swift build`), `make calibrate` (lid closed, glass clear).
- `sudo make install` copies the module to `/Library/Image Capture/Devices/`. The user runs anything that
  needs sudo; ask them, then have them quit and reopen Image Capture.
- The module only runs when icdd launches it (Image Capture or Preview selecting the scanner). Started by hand
  it quits with "Open Device Failed". So every module change needs install + a test by the user.
- Read results from the log: `/usr/bin/log show --last 15m --style compact --predicate 'subsystem == "local.lide70ica"'`.
  Use the full path: zsh's builtin `log` shadows `/usr/bin/log`. Each scan logs request, backend format,
  "applying shading calibration", rows delivered.
- Check that the installed binary is the current build before reading logs:
  `cmp "/Library/Image Capture/Devices/LiDE70Scanner.app/Contents/MacOS/LiDE70Scanner" build/LiDE70Scanner.app/Contents/MacOS/LiDE70Scanner`.
- The bridge and backend can be tested on the scanner without installing: small C programs linked against
  `build/*.o` and libusb (keep them in the scratchpad, not the repo), or `lide70-calibrate --verify`.
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
  `git diff d97b700 -- backend/` shows them all.
- `canon_lide70.c` #includes `canon_lide70-common.c`; `sanei_backend.h` defines signal macros, so don't
  include `<signal.h>` there.

## Swift and C gotchas

- In Swift `>>` binds tighter than `*`: write `(a * b) >> 8`.
- `@preconcurrency import ICADevices` (Swift 6 mode rejects writing `gICDScannerCallbackFunctions` otherwise).
- Swift doesn't import C macros that are expressions; add a `static const` to the header.
- Read numbers from ICA dictionaries through `NSNumber` (`as? Int` fails on non-integral values).
- Open `Package.swift` in Xcode, not single files: alone, `Scanner`/`log` resolve to Foundation/Darwin symbols.

## Working conventions

- Commit only when the user asks; commit messages explain the why and what was verified.
- Shading calibration data lives outside the repo: `~/Library/Application Support/LiDE70Scanner/Calibration.plist`.
- Built for macOS 27 (`MACOS_MIN` in the Makefile and `platforms` in Package.swift must match) because
  Homebrew's static libusb is.
- License: GPL v2+ (backend). The module's structure follows Apple's VirtualScanner sample (in git history).
