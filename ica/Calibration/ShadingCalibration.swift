// SPDX-License-Identifier: GPL-2.0-or-later
//
// Shading calibration for the LiDE 70's contact image sensor.
//
// Each column of the sensor bar sees the page with its own sensitivity and its own share of the LED light, and
// the three colors differ too (on the test scanner green read ~11% lower than red and blue). The SANE backend
// does not correct for this, so a white page came out pink with vertical bands.
//
// Calibration scans the white scanner lid with the scanner's gamma switched off (linear sensor values) and keeps,
// for every sensor column and color, how bright white reads: the white reference. A scan is then corrected by
// scaling each column so its white reference becomes 255, and the 2.2 gamma the scanner would have applied is
// applied in software afterwards. References depend on the resolution (below 600 dpi the chip decimates), so
// there is one per resolution.

import Foundation

/// White references for each resolution, measured from the lid by `lide70-calibrate`.
public struct ShadingCalibration: Codable, Sendable {

    /// How white reads, per sensor column, at one resolution. Column 0 is the left edge of the bed.
    public struct Reference: Codable, Sendable {
        public var red: [Float]
        public var green: [Float]
        public var blue: [Float]
        public var columns: Int { red.count }

        public init(red: [Float], green: [Float], blue: [Float]) {
            (self.red, self.green, self.blue) = (red, green, blue)
        }
    }

    public var created: Date
    /// Keyed by resolution in dpi, as a string (property-list dictionary keys must be strings).
    public var references: [String: Reference]

    public init(created: Date = Date(), references: [String: Reference] = [:]) {
        self.created = created
        self.references = references
    }

    public func reference(dpi: Int) -> Reference? { references[String(dpi)] }

    // MARK: - Storage

    /// ~/Library/Application Support/LiDE70Scanner/Calibration.plist (the module runs as the logged-in user).
    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/LiDE70Scanner/Calibration.plist")
    }

    public static func load(from url: URL = defaultURL) -> ShadingCalibration? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? PropertyListDecoder().decode(ShadingCalibration.self, from: data)
    }

    public func save(to url: URL = defaultURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}

// MARK: - Measuring a reference

/// Collects linear RGB rows of the white lid and turns them into a Reference: for each column and color the
/// median over the rows, so dust and specks on the lid do not count.
public struct ReferenceBuilder {
    public let columns: Int
    private var rows: [[UInt8]] = []

    public init(columns: Int) { self.columns = columns }

    /// Adds one row of interleaved RGB (3 bytes per column).
    public mutating func add(row: some Collection<UInt8>) {
        precondition(row.count == columns * 3)
        rows.append(Array(row))
    }

    public var rowCount: Int { rows.count }

    public func build() -> ShadingCalibration.Reference {
        var channels = [[Float]](repeating: [Float](repeating: 0, count: columns), count: 3)
        var samples = [UInt8](repeating: 0, count: rows.count)
        for x in 0..<columns {
            for c in 0..<3 {
                for (i, row) in rows.enumerated() { samples[i] = row[x * 3 + c] }
                samples.sort()
                channels[c][x] = Float(samples[samples.count / 2])
            }
        }
        return .init(red: channels[0], green: channels[1], blue: channels[2])
    }
}

// MARK: - Correcting rows

/// Corrects linear RGB rows from the scanner: each column is scaled so its white reference becomes 255, then
/// gamma-encoded. Built per scan, for that scan's width and position on the bed.
public struct RowCorrector: Sendable {
    /// Gain per output byte (3 per pixel), in 8.8 fixed point.
    private let gains: [UInt32]
    /// Linear 0...255 to gamma-encoded 0...255.
    private let gammaTable: [UInt8]

    /// Lowest white reference trusted as such. Columns darker than this (only seen at the very edge of the bed)
    /// get the gain this value gives instead, so their noise is not amplified without limit.
    public static let minimumWhite: Float = 48

    /// - Parameters:
    ///   - firstColumn: the sensor column of the scan's column 0 (lide70_scan_format.first_column).
    ///   - width: pixels per row in the scan.
    ///   - gamma: the curve applied after correction; 2.2 is what the backend's own tables use.
    public init(reference: ShadingCalibration.Reference, firstColumn: Int, width: Int, gamma: Double = 2.2) {
        var gains = [UInt32](repeating: 256, count: width * 3)
        let channels = [reference.red, reference.green, reference.blue]
        for x in 0..<width {
            let column = min(max(firstColumn + x, 0), reference.columns - 1)
            for c in 0..<3 {
                let white = max(channels[c][column], Self.minimumWhite)
                gains[x * 3 + c] = UInt32((255 / white * 256).rounded())
            }
        }
        self.gains = gains
        self.gammaTable = (0...255).map { UInt8((255 * pow(Double($0) / 255, 1 / gamma)).rounded()) }
    }

    /// Corrects one row of interleaved RGB in place.
    public func apply(_ row: UnsafeMutableBufferPointer<UInt8>) {
        let n = min(row.count, gains.count)
        gains.withUnsafeBufferPointer { gains in
            gammaTable.withUnsafeBufferPointer { gamma in
                for i in 0..<n {
                    // Parentheses matter: in Swift `>>` binds tighter than `*`.
                    let linear = min((UInt32(row[i]) * gains[i]) >> 8, 255)
                    row[i] = gamma[Int(linear)]
                }
            }
        }
    }
}
