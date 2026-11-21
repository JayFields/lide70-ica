// SPDX-License-Identifier: GPL-2.0-or-later
//
// lide70-calibrate: developer tool for the strip calibration (see ica/Calibration/StripCalibration.swift).
// Users of the module never run it: the factors it measures ship with the module.
//
//   lide70-calibrate derive [--dpi 75,150,300,600,1200] [--file PATH]
//       Measures the glass/strip factors: reads the internal white strip and a band of the white lid on the glass
//       at each resolution, and writes them to PATH (default ica/Resources/StripCalibration.plist). Close the lid
//       with nothing on the glass. With --dpi, other resolutions in PATH are kept.
//
//   lide70-calibrate verify [--dpi ...] [--file PATH] [--top MM]
//       Checks strip-only correction against whatever white is on the glass (the lid, or a sheet of paper): reads
//       the strip, builds the reference the module would, and scans a band of the glass from 37 mm in (from MM,
//       default 60, for 10 mm). Reports the column variation before and after, and the color balance.
//
// Don't scan from Image Capture or Preview meanwhile.

import Foundation
import LiDE70C
import ShadingCalibration

let allResolutions = [75, 150, 300, 600, 1200]

// MARK: - Arguments

enum Command { case derive, verify }

func fail(_ message: String) -> Never {
    FileHandle.standardError.write("lide70-calibrate: \(message)\n".data(using: .utf8)!)
    exit(1)
}

let usage = "usage: lide70-calibrate derive|verify [--dpi 75,150,300,600,1200] [--file PATH] [--top MM]"
var arguments = CommandLine.arguments.dropFirst()
let command: Command
switch arguments.popFirst() {
case "derive": command = .derive
case "verify": command = .verify
case "-h", "--help": print(usage); exit(0)
default: fail(usage)
}
var resolutions = allResolutions
var file = URL(fileURLWithPath: "ica/Resources/\(StripCalibration.fileName)")
var verifyTop = 60.0
while let argument = arguments.popFirst() {
    switch argument {
    case "--dpi":
        guard let list = arguments.popFirst() else { fail("--dpi needs a list, e.g. --dpi 300,600") }
        resolutions = list.split(separator: ",").compactMap { Int($0) }
        if resolutions.isEmpty || !resolutions.allSatisfy(allResolutions.contains) {
            fail("resolutions must be among \(allResolutions)")
        }
    case "--file":
        guard let path = arguments.popFirst() else { fail("--file needs a path") }
        file = URL(fileURLWithPath: path)
    case "--top":
        guard let value = arguments.popFirst().flatMap(Double.init) else { fail("--top needs millimetres") }
        verifyTop = value
    default: fail("unknown argument \(argument)\n\(usage)")
    }
}

/// Runs a scan, exiting with its error message if it fails.
func scanned<T>(_ body: () throws -> T) -> T {
    do { return try body() } catch { fail("\(error)") }
}

// MARK: - Statistics

/// Columns near the edges of the bed are left out of summaries; they read dark and would dominate.
func interior(_ columns: Int) -> Range<Int> {
    let margin = columns / 50
    return margin..<(columns - margin)
}

func summary(_ values: [Float]) -> (mean: Float, cv: Float) {
    let mean = values.reduce(0, +) / Float(values.count)
    let sd = (values.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Float(values.count)).squareRoot()
    return (mean, 100 * sd / mean)
}

/// Per-column mean of each channel over the scan's rows.
func columnMeans(_ scan: LinearScan) -> [[Float]] {
    var sums = [[Float]](repeating: [Float](repeating: 0, count: scan.columns), count: 3)
    for row in scan.rows {
        for x in 0..<scan.columns { for c in 0..<3 { sums[c][x] += Float(row[x * 3 + c]) } }
    }
    return sums.map { $0.map { $0 / Float(scan.rows.count) } }
}

/// Strip values averaged down to a lower resolution's columns.
func downsampled(_ values: [Float], step: Int, columns: Int) -> [Float] {
    (0..<columns).map { x in
        let start = min(x * step, values.count - 1), end = min(start + step, values.count)
        return values[start..<end].reduce(0, +) / Float(end - start)
    }
}

let names = ["R", "G", "B"]

// MARK: - Run

var deviceName = [CChar](repeating: 0, count: 32)
guard lide70_usb_find_first(&deviceName, deviceName.count) == 0 else { fail("no CanoScan LiDE 70/600 found") }
let device = deviceName.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
print("Scanner \(device).")

/// Strip readings, by (strip resolution, gain code): 75, 150 and 300 dpi share the 300 dpi reading.
var stripReadings: [String: WhiteReference] = [:]
@MainActor func strip(for dpi: Int, gainCode: Int) -> WhiteReference {
    let key = "\(WhiteStrip.resolution(for: dpi))/\(gainCode)"
    if let reading = stripReadings[key] { return reading }
    let reading = scanned { try WhiteStrip.read(device: device, dpi: dpi, gainCode: gainCode) }
    stripReadings[key] = reading
    return reading
}

switch command {

case .derive:
    print("Measuring glass/strip factors from the lid: close the lid with nothing on the glass.")
    var calibration = StripCalibration.load(from: file) ?? StripCalibration()
    for dpi in resolutions {
        let gainCode = StripCalibration.standardGainCode(dpi: dpi)
        let stripReading = strip(for: dpi, gainCode: gainCode)
        let lid = scanned {
            try LinearScan.scan(device: device, dpi: dpi, gainCode: gainCode, topMM: 20, bottomMM: 30)
        }.columnMedians()
        let step = WhiteStrip.resolution(for: dpi) / dpi
        let stripAtDPI = stripReading.channels.map { downsampled($0, step: step, columns: lid.columns) }

        var factors: [Float] = [], levels: [Float] = []
        print("\n\(dpi) dpi (gain code \(gainCode)):")
        for c in 0..<3 {
            let cols = interior(lid.columns).filter { stripAtDPI[c][$0] < 255 && lid.channels[c][$0] < 255 }
            let ratio = summary(cols.map { lid.channels[c][$0] / stripAtDPI[c][$0] })
            let stripCols = interior(stripReading.columns).map { stripReading.channels[c][$0] }
            let saturated = stripReading.channels[c].filter { $0 >= 255 }.count
            factors.append(ratio.mean)
            levels.append(summary(stripCols).mean)
            print(String(format: "    %@: glass/strip %.3f (column-to-column %.2f%%); strip level %5.1f, "
                         + "%d saturated strip columns", names[c], ratio.mean, ratio.cv, levels[c], saturated))
        }
        calibration.resolutions[String(dpi)] = .init(gainCode: gainCode, factors: factors, stripLevel: levels)
    }
    calibration.measured = Date()
    calibration.note = "Measured with lide70-calibrate derive: the white lid on the glass vs the internal white "
        + "strip, on the developer's CanoScan LiDE 70."
    do { try calibration.save(to: file) } catch { fail("cannot write \(file.path): \(error)") }
    print("\nWrote \(file.path)")

case .verify:
    guard let calibration = StripCalibration.load(from: file) else { fail("cannot read \(file.path)") }
    print("Verifying strip-only correction against the white on the glass (\(verifyTop)-\(verifyTop + 10) mm, "
          + "from 37 mm in).")
    for dpi in resolutions {
        guard let settings = calibration.settings(dpi: dpi) else { print("\n\(dpi) dpi: no factors; skipped"); continue }
        let stripReading = strip(for: dpi, gainCode: settings.gainCode)
        let glass = scanned {
            try LinearScan.scan(device: device, dpi: dpi, gainCode: settings.gainCode,
                                topMM: verifyTop, bottomMM: verifyTop + 10, leftMM: 37)
        }
        // The reference the module builds for a full-width scan, then this band's part of it.
        let sensorColumns = glass.firstColumn + glass.columns
        let built: (reference: WhiteReference, check: StripCalibration.Check)
        do {
            built = try calibration.reference(fromStrip: stripReading, scanDPI: dpi, columns: sensorColumns)
        } catch {
            print("\n\(dpi) dpi: strip reading rejected: \(error)"); continue
        }
        let raw = columnMeans(glass)
        let range = interior(glass.columns)

        print("\n\(dpi) dpi (gain code \(settings.gainCode)): strip level "
              + built.check.level.map { String(format: "%.3f", $0) }.joined(separator: "/")
              + " of the calibrated scanner's, \(built.check.filledColumns) saturated strip readings filled in")
        var levels: [Float] = []
        for c in 0..<3 {
            let before = summary(range.map { raw[c][$0] })
            let ratio = summary(range.map {
                raw[c][$0] / max(built.reference.channels[c][glass.firstColumn + $0], RowCorrector.minimumWhite)
            })
            levels.append(ratio.mean)
            print(String(format: "    %@: raw %4.2f%%  corrected %4.2f%%  level %.3f (1.000 = as white as the lid)",
                         names[c], before.cv, ratio.cv, ratio.mean))
        }
        print(String(format: "    color balance R/G %.3f, B/G %.3f (1.000 = neutral)",
                     levels[0] / levels[1], levels[2] / levels[1]))
    }
}
