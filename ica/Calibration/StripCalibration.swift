// SPDX-License-Identifier: GPL-2.0-or-later
//
// Strip calibration: every scan is calibrated from the scanner's own internal white strip, read just before it.
//
// The strip is not the same white as the glass, where documents lie: on the test scanner a white surface on the
// glass read ~0.89-0.93 of the strip, a little differently per color. So the strip's reading is scaled by fixed
// glass/strip factors per color and resolution. They were measured once, on one scanner, by `lide70-calibrate
// derive` with its white lid on the glass, and ship with the module (ica/Resources/StripCalibration.plist), so
// users never calibrate. The per-column pattern always comes from the user's own strip: a per-column glass/strip
// map from one scanner would carry that scanner's strip (its dust, its unevenness) to every other one.
//
// Measured on white paper (test scanner, gain codes below): strip-only correction leaves ~0.8-1.3% column variation,
// from ~4-5% raw, about as good as a full calibration against the lid (the strip leaves a small ~0.7% pattern that
// the glass doesn't have).
//
// Analog gain (the HT82V36 front end's PGA code) is part of the calibration: the backend's code 40 (~2.11x)
// saturates white in about a third of red and half of blue columns. Code 32 (~1.73x) leaves ~8% headroom; 600 dpi,
// which the backend sets up with a different color balance, needs 26 for the same headroom on the strip.

import Foundation

public struct StripCalibration: Codable, Sendable {

    /// Settings and factors for one scan resolution.
    public struct Resolution: Codable, Sendable {
        /// Analog gain code used for the strip reading and the scan.
        public var gainCode: Int
        /// White on the glass divided by the strip, per color (mean over the columns).
        public var red: Float
        public var green: Float
        public var blue: Float
        /// The strip's mean linear level per color when the factors were measured, as a plausibility check for
        /// later readings (other scanners will differ somewhat).
        public var stripLevel: [Float]

        public var factors: [Float] { [red, green, blue] }

        public init(gainCode: Int, factors: [Float], stripLevel: [Float]) {
            self.gainCode = gainCode
            (red, green, blue) = (factors[0], factors[1], factors[2])
            self.stripLevel = stripLevel
        }
    }

    public var measured: Date
    public var note: String
    /// Keyed by resolution in dpi, as a string (property-list dictionary keys must be strings).
    public var resolutions: [String: Resolution]

    public init(measured: Date = Date(), note: String = "", resolutions: [String: Resolution] = [:]) {
        (self.measured, self.note, self.resolutions) = (measured, note, resolutions)
    }

    public func settings(dpi: Int) -> Resolution? { resolutions[String(dpi)] }

    /// Gain code for new measurements at `dpi`.
    public static func standardGainCode(dpi: Int) -> Int { dpi == 600 ? 26 : 32 }

    // MARK: - Storage

    public static let fileName = "StripCalibration.plist"

    /// The copy in the module's bundle (Contents/Resources).
    public static func bundled(in bundle: Bundle = .main) -> StripCalibration? {
        bundle.url(forResource: "StripCalibration", withExtension: "plist").flatMap { load(from: $0) }
    }

    public static func load(from url: URL) -> StripCalibration? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? PropertyListDecoder().decode(StripCalibration.self, from: data)
    }

    public func save(to url: URL) throws {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .xml     // XML, so the shipped file reads well in the repository
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    // MARK: - Reference from a strip reading

    /// A strip reading is rejected if its level is outside this range of the stored level (a failed read, or a
    /// scanner very different from the one measured).
    public static let levelLimits: ClosedRange<Float> = 0.6...1.4
    /// ...or if more than this fraction of its readings is saturated. Fewer are filled in from their neighbors.
    public static let maximumSaturatedFraction: Float = 0.15

    public struct Check: Sendable {
        public let level: [Float]            // strip level / stored level, per color
        public let filledColumns: Int        // saturated readings filled in from neighbors
    }

    /// The white reference for a scan at `scanDPI` with `columns` sensor columns, from a strip reading made at
    /// `WhiteStrip.resolution(for: scanDPI)` with this resolution's gain code.
    public func reference(fromStrip strip: WhiteReference, scanDPI: Int, columns: Int) throws
        -> (reference: WhiteReference, check: Check) {
        guard let settings = settings(dpi: scanDPI) else {
            throw LinearScan.Failure("no strip calibration for \(scanDPI) dpi")
        }
        let n = strip.columns
        guard n > 10 else { throw LinearScan.Failure("empty strip reading") }

        var channels = strip.channels
        var levels: [Float] = []
        var filled = 0
        let interior = (n / 50)..<(n - n / 50)
        for c in 0..<3 {
            let saturated = channels[c].indices.filter { channels[c][$0] >= 255 }
            guard Float(saturated.count) <= Self.maximumSaturatedFraction * Float(n) else {
                throw LinearScan.Failure("\(saturated.count) of \(n) strip readings saturated")
            }
            filled += saturated.count
            channels[c] = filledFromNeighbors(channels[c])
            let level = interior.map { channels[c][$0] }.reduce(0, +) / Float(interior.count)
            levels.append(level / max(settings.stripLevel[c], 1))
        }
        for (c, level) in levels.enumerated() where !Self.levelLimits.contains(level) {
            throw LinearScan.Failure(String(format: "strip %@ level %.2f of the calibrated level",
                                            ["red", "green", "blue"][c], level))
        }

        // Glass white = strip x factor; averaged down when the strip was read at a higher resolution than the scan.
        let step = max(WhiteStrip.resolution(for: scanDPI) / scanDPI, 1)
        let reference = (0..<3).map { c in
            (0..<columns).map { x -> Float in
                let start = min(x * step, n - 1), end = min(start + step, n)
                return channels[c][start..<end].reduce(0, +) / Float(end - start) * settings.factors[c]
            }
        }
        return (WhiteReference(channels: reference), Check(level: levels, filledColumns: filled))
    }

    /// Saturated readings (255) only say "at least this bright": replace them by interpolating between the
    /// nearest unsaturated columns on either side.
    private func filledFromNeighbors(_ values: [Float]) -> [Float] {
        var out = values
        var x = 0
        while x < values.count {
            guard values[x] >= 255 else { x += 1; continue }
            var end = x
            while end < values.count && values[end] >= 255 { end += 1 }
            let left = x > 0 ? values[x - 1] : nil
            let right = end < values.count ? values[end] : nil
            for i in x..<end {
                switch (left, right) {
                case let (l?, r?): out[i] = l + (r - l) * Float(i - x + 1) / Float(end - x + 1)
                case let (l?, nil): out[i] = l
                case let (nil, r?): out[i] = r
                default: out[i] = 255
                }
            }
            x = end
        }
        return out
    }
}
