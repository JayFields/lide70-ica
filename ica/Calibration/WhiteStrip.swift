// SPDX-License-Identifier: GPL-2.0-or-later
//
// Reading the scanner's internal white strip, and linear scans in general.
//
// The strip lies just before the glass, 7 mm before where the backend starts a scan at 300 dpi and up (its
// `top_edge`): about -5.5 to -2 mm in those coordinates; it is read from -5.0 to -2.5 mm (a narrower band at
// 1200 dpi, see `band`). At 75 and 150 dpi scans start on the glass, so the strip is read at 300 dpi and averaged
// down (see StripCalibration).
//
// Measured on the test scanner: the strip's per-column pattern repeats to 0.3-0.5% between passes, does not depend
// on what is on the glass, and follows changes in the sensor's response (the scanner has been seen switching
// between response states, ~4% apart). So reading it before every scan keeps the correction current.

import Foundation
import LiDE70C

// MARK: - Linear scans

/// A linear-color scan of a band of the bed: `rows` of `columns` RGB pixels starting at sensor column `firstColumn`.
public struct LinearScan: Sendable {
    public var columns: Int
    public var rows: [[UInt8]]
    public var firstColumn: Int

    public struct Failure: Error, CustomStringConvertible {
        public let description: String
        public init(_ description: String) { self.description = description }
    }

    /// Scans from `topMM` to `bottomMM` (negative tops reach above the glass at 300 dpi and up), from `leftMM` to
    /// the right edge of the bed, with the scanner's gamma off and the given analog gain code.
    public static func scan(device: String, dpi: Int, gainCode: Int, topMM: Double, bottomMM: Double,
                            leftMM: Double = 0) throws -> LinearScan {
        var request = lide70_scan_request()
        request.dpi = Int32(dpi)
        request.mode = Int32(LIDE70_MODE_COLOR)
        request.tl_x_mm = leftMM
        request.br_x_mm = lide70_bed_width_mm
        request.tl_y_mm = topMM
        request.br_y_mm = bottomMM
        request.linear = 1
        request.afe_gain = Int32(gainCode)

        var format = lide70_scan_format()
        let started = lide70_scan_start(device, &request, &format)
        guard started == Int32(LIDE70_GOOD) else {
            lide70_scan_end()
            throw Failure("scan at \(dpi) dpi failed to start: \(statusName(started))")
        }
        defer { lide70_scan_end() }

        var rows: [[UInt8]] = []
        var line = [UInt8](repeating: 0, count: Int(format.bytes_per_line))
        var have = 0
        var status = Int32(LIDE70_GOOD)
        while status == Int32(LIDE70_GOOD) {
            var got: Int32 = 0
            status = line.withUnsafeMutableBufferPointer {
                lide70_scan_read($0.baseAddress! + have, Int32($0.count - have), &got)
            }
            have += Int(got)
            if have == line.count { rows.append(line); have = 0 }
        }
        guard status == Int32(LIDE70_EOF), format.channels == 3, !rows.isEmpty else {
            throw Failure("scan at \(dpi) dpi failed: \(statusName(status))")
        }
        return LinearScan(columns: Int(format.pixels_per_line), rows: rows, firstColumn: Int(format.first_column))
    }

    /// Per-column median over the rows (a white reference, when the band is white).
    public func columnMedians() -> WhiteReference {
        var builder = ReferenceBuilder(columns: columns)
        for row in rows { builder.add(row: row) }
        return builder.build()
    }

    private static func statusName(_ status: Int32) -> String { String(cString: lide70_status_name(status)) }
}

// MARK: - The white strip

public enum WhiteStrip {
    /// Resolution at which the strip is read for a scan at `dpi` (75 and 150 dpi can't reach it).
    public static func resolution(for dpi: Int) -> Int { max(dpi, 300) }

    /// Band read at a strip resolution, in the backend's coordinates at 300 dpi and up (inside the strip's
    /// -5.5 to -2 mm). At 1200 dpi the head moves slowly, so a narrower band: 1.2 mm reads in 9.0 s instead of
    /// 11.8 s, with the same pattern (0.4% from the wide band, about a repeat's noise). Its middle reads ~0.9%
    /// brighter than the wide band's average, so the factors must be derived with the same band.
    public static func band(atResolution stripDPI: Int) -> (topMM: Double, bottomMM: Double) {
        stripDPI >= 1200 ? (-4.5, -3.3) : (-5.0, -2.5)
    }

    /// Reads the strip: per-column linear white levels, full width, at `resolution(for: dpi)`.
    public static func read(device: String, dpi: Int, gainCode: Int) throws -> WhiteReference {
        let stripDPI = resolution(for: dpi)
        let band = band(atResolution: stripDPI)
        return try LinearScan.scan(device: device, dpi: stripDPI, gainCode: gainCode,
                                   topMM: band.topMM, bottomMM: band.bottomMM).columnMedians()
    }
}
