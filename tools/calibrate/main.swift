// SPDX-License-Identifier: GPL-2.0-or-later
//
// lide70-calibrate: measures the shading calibration from the white scanner lid and saves it where the Image
// Capture module looks for it (see ica/Calibration/ShadingCalibration.swift).
//
//   lide70-calibrate                 calibrate all resolutions (75, 150, 300, 600, 1200 dpi)
//   lide70-calibrate --dpi 300,600   only these (other resolutions keep their saved calibration)
//   lide70-calibrate --verify        afterwards, scan another strip of the lid and report how flat it comes out
//   lide70-calibrate --verify-only   just the check, with the saved calibration
//
// Close the lid with nothing on the glass. Don't scan from Image Capture or Preview meanwhile.

import Foundation
import LiDE70C
import ShadingCalibration

let allResolutions = [75, 150, 300, 600, 1200]

// MARK: - Arguments

var resolutions = allResolutions
var verify = false
var calibrate = true
var arguments = CommandLine.arguments.dropFirst()
while let argument = arguments.popFirst() {
    switch argument {
    case "--dpi":
        guard let list = arguments.popFirst() else { fail("--dpi needs a list, e.g. --dpi 300,600") }
        resolutions = list.split(separator: ",").compactMap { Int($0) }
        if resolutions.isEmpty || !resolutions.allSatisfy(allResolutions.contains) {
            fail("resolutions must be among \(allResolutions)")
        }
    case "--verify": verify = true
    case "--verify-only": verify = true; calibrate = false
    case "-h", "--help":
        print("usage: lide70-calibrate [--dpi 75,150,300,600,1200] [--verify | --verify-only]"); exit(0)
    default: fail("unknown argument \(argument)")
    }
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write("lide70-calibrate: \(message)\n".data(using: .utf8)!)
    exit(1)
}

// MARK: - Scanning a strip

/// A strip of the lid in linear color, to the right edge of the bed: `rows` of `columns` RGB pixels starting at
/// sensor column `firstColumn`.
struct Strip {
    var columns: Int
    var rows: [[UInt8]]
    var firstColumn: Int
}

func scanStrip(device: String, dpi: Int, fromMM top: Double, heightMM: Double, leftMM: Double = 0) -> Strip {
    var request = lide70_scan_request()
    request.dpi = Int32(dpi)
    request.mode = Int32(LIDE70_MODE_COLOR)
    request.tl_x_mm = leftMM
    request.br_x_mm = lide70_bed_width_mm
    request.tl_y_mm = top
    request.br_y_mm = top + heightMM
    request.linear = 1

    var format = lide70_scan_format()
    let status = lide70_scan_start(device, &request, &format)
    guard status == Int32(LIDE70_GOOD) else {
        lide70_scan_end()
        fail("scan at \(dpi) dpi failed to start: \(String(cString: lide70_status_name(status)))")
    }
    var rows: [[UInt8]] = []
    var line = [UInt8](repeating: 0, count: Int(format.bytes_per_line))
    var have = 0
    var status2 = Int32(LIDE70_GOOD)
    while status2 == Int32(LIDE70_GOOD) {
        var got: Int32 = 0
        status2 = line.withUnsafeMutableBufferPointer {
            lide70_scan_read($0.baseAddress! + have, Int32($0.count - have), &got)
        }
        have += Int(got)
        if have == line.count { rows.append(line); have = 0 }
    }
    lide70_scan_end()
    guard status2 == Int32(LIDE70_EOF), format.channels == 3 else {
        fail("scan at \(dpi) dpi failed: \(String(cString: lide70_status_name(status2)))")
    }
    return Strip(columns: Int(format.pixels_per_line), rows: rows, firstColumn: Int(format.first_column))
}

// MARK: - Statistics

/// Columns near the edges of the bed are left out of summaries; they read dark and would dominate.
let edgeMargin = 0.02

func interior(_ columns: Int) -> Range<Int> {
    let margin = Int(Double(columns) * edgeMargin)
    return margin..<(columns - margin)
}

func summary(_ values: [Float], _ range: Range<Int>) -> (mean: Float, sd: Float, min: Float, max: Float) {
    let v = values[range]
    let mean = v.reduce(0, +) / Float(v.count)
    let sd = (v.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Float(v.count)).squareRoot()
    return (mean, sd, v.min()!, v.max()!)
}

/// Per-column mean of each channel over the strip's rows.
func columnMeans(_ strip: Strip) -> [[Float]] {
    var sums = [[Float]](repeating: [Float](repeating: 0, count: strip.columns), count: 3)
    for row in strip.rows {
        for x in 0..<strip.columns { for c in 0..<3 { sums[c][x] += Float(row[x * 3 + c]) } }
    }
    return sums.map { $0.map { $0 / Float(strip.rows.count) } }
}

let names = ["R", "G", "B"]

// MARK: - Run

var deviceName = [CChar](repeating: 0, count: 32)
guard lide70_usb_find_first(&deviceName, deviceName.count) == 0 else { fail("no CanoScan LiDE 70/600 found") }
let device = deviceName.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }

print("Scanner \(device). Close the lid with nothing on the glass.")
var calibration = ShadingCalibration.load() ?? ShadingCalibration()

if calibrate {
    for dpi in resolutions {
        print("\n\(dpi) dpi: scanning the lid (10 mm strip)...")
        let strip = scanStrip(device: device, dpi: dpi, fromMM: 20, heightMM: 10)
        var builder = ReferenceBuilder(columns: strip.columns)
        for row in strip.rows { builder.add(row: row) }
        let reference = builder.build()
        calibration.references[String(dpi)] = reference

        print("  \(strip.columns) columns x \(builder.rowCount) rows; white reference (linear, edges excluded):")
        let range = interior(strip.columns)
        for (c, values) in [reference.red, reference.green, reference.blue].enumerated() {
            let s = summary(values, range)
            print(String(format: "    %@: mean %5.1f  sd %4.1f  min %5.1f  max %5.1f  -> gain %.2f...%.2f",
                         names[c], s.mean, s.sd, s.min, s.max, 255 / s.max, 255 / max(s.min, RowCorrector.minimumWhite)))
        }
        let saturated = [reference.red, reference.green, reference.blue].joined().filter { $0 >= 255 }.count
        if saturated > 0 {
            print("    note: \(saturated) column readings are at 255 (sensor saturated); "
                  + "anything brighter than the lid there will clip")
        }
    }
    calibration.created = Date()
    do { try calibration.save() } catch { fail("cannot save calibration: \(error)") }
    print("\nSaved to \(ShadingCalibration.defaultURL.path)")
}

if verify {
    for dpi in resolutions {
        guard let reference = calibration.reference(dpi: dpi) else {
            print("\n\(dpi) dpi: no calibration saved; skipped"); continue
        }
        // Another strip, starting 37 mm from the left like an area scan, so the column alignment
        // (first_column) is tested as well.
        print("\n\(dpi) dpi: verifying on another strip of the lid, from 37 mm...")
        let strip = scanStrip(device: device, dpi: dpi, fromMM: 60, heightMM: 10, leftMM: 37)
        let range = interior(strip.columns)
        let raw = columnMeans(strip)

        // Alignment: which shift of the reference fits this strip best (0 means first_column is right).
        let green = reference.green
        let bestShift = (-3...3).min { a, b in
            func spread(_ shift: Int) -> Float {
                let ratio = range.map { x -> Float in
                    raw[1][x] / max(green[min(max(strip.firstColumn + x + shift, 0), green.count - 1)],
                                    RowCorrector.minimumWhite)
                }
                return summary(ratio, 0..<ratio.count).sd
            }
            return spread(a) < spread(b)
        }!
        print("  first column \(strip.firstColumn); best-fitting shift of the reference: \(bestShift) column(s)")

        let corrector = RowCorrector(reference: reference, firstColumn: strip.firstColumn, width: strip.columns)
        var corrected = strip
        for i in corrected.rows.indices { corrected.rows[i].withUnsafeMutableBufferPointer { corrector.apply($0) } }
        let out = columnMeans(corrected)
        let channels = [reference.red, reference.green, reference.blue]

        print("  column-to-column variation (sd, % of mean), edges excluded:")
        for c in 0..<3 {
            // Linear flatness: this strip divided by the reference, per column.
            let ratio = range.map { x -> Float in
                raw[c][x] / max(channels[c][min(strip.firstColumn + x, reference.columns - 1)], RowCorrector.minimumWhite)
            }
            let r = summary(ratio, 0..<ratio.count)
            let before = summary(raw[c], range)
            let after = summary(out[c], range)
            print(String(format: "    %@: raw %4.1f%%  corrected-linear %4.2f%% (level %.3f)  output mean %5.1f sd %4.2f",
                         names[c], 100 * before.sd / before.mean, 100 * r.sd / r.mean, r.mean, after.mean, after.sd))
        }
    }
}
