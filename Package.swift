// swift-tools-version: 6.0
//
// Swift package for the ICA device module. `make module` builds it with `swift build` and wraps the
// executable in LiDE70Scanner.app; opening this file in Xcode (or the folder in VS Code with the Swift
// extension) gives the editor the whole module, including the C code it calls.

import Foundation
import PackageDescription

// Homebrew's libusb, linked statically so the module does not depend on Homebrew at runtime.
let brew = ["/opt/homebrew", "/usr/local"].first {
    FileManager.default.fileExists(atPath: "\($0)/lib/libusb-1.0.a")
} ?? "/opt/homebrew"

let package = Package(
    name: "LiDE70Scanner",
    platforms: [.macOS("27.0")],    // keep in step with MACOS_MIN in the Makefile
    targets: [
        // The canon_lide70 SANE backend, the libusb sanei_usb shim, and the C bridge the module calls.
        // Swift sees only the headers in shim/ (lide70_scan.h, lide70_usb.h) as `import LiDE70C`.
        .target(
            name: "LiDE70C",
            path: ".",
            sources: [
                "backend/canon_lide70.c",       // #includes canon_lide70-common.c
                "shim/sanei_usb_libusb.c",
                "shim/link_stubs.c",
                "shim/lide70_scan.c",
            ],
            publicHeadersPath: "shim",
            cSettings: [
                .headerSearchPath("include"),
                .headerSearchPath("backend"),
                // The vendored backend is kept close to upstream; it trips SwiftPM's default -Wshorten-64-to-32.
                .unsafeFlags(["-I\(brew)/include/libusb-1.0", "-Wno-unused-parameter", "-Wno-shorten-64-to-32"]),
            ]
        ),
        // Shading calibration: white references per resolution, and the per-column correction. Pure Swift.
        .target(
            name: "ShadingCalibration",
            path: "ica/Calibration"
        ),
        // The Image Capture device module.
        .executableTarget(
            name: "LiDE70Scanner",
            dependencies: ["LiDE70C", "ShadingCalibration"],
            path: "ica/Sources",
            linkerSettings: [
                .unsafeFlags(["\(brew)/lib/libusb-1.0.a"]),
                .linkedFramework("ICADevices"),
                .linkedFramework("IOKit"),
                .linkedFramework("Security"),
            ]
        ),
        // Command-line tool that measures the calibration from the scanner lid.
        .executableTarget(
            name: "lide70-calibrate",
            dependencies: ["LiDE70C", "ShadingCalibration"],
            path: "tools/calibrate",
            linkerSettings: [
                .unsafeFlags(["\(brew)/lib/libusb-1.0.a"]),
                .linkedFramework("IOKit"),
                .linkedFramework("Security"),
            ]
        ),
    ]
)
