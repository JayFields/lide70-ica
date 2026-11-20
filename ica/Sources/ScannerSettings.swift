// SPDX-License-Identifier: GPL-2.0-or-later
//
// The scanner's capabilities and current settings, kept in the TWAIN-style dictionary format that
// Image Capture clients read and write (loaded from ScannerProperties.plist).
//
// Each setting is a dictionary with a "type":
//   TWON_ONEVALUE    { type, value }                          a single fixed value
//   TWON_ENUMERATION { type, value: [..], current, default }  `current` is an index into `value`
//   TWON_RANGE       { type, min, max, stepSize, current, default }

import Foundation

final class ScannerSettings {
    /// Name shown to clients; also the key into DeviceInfo.plist's "devices".
    let name: String

    /// Settings of the flatbed (functional unit 0). Sent to clients as-is in GetParameters, so it stays an
    /// NSMutableDictionary in the plist's own structure.
    let flatbed: NSMutableDictionary

    init?(contentsOf url: URL) {
        guard let data = try? Data(contentsOf: url),
              let root = try? PropertyListSerialization.propertyList(
                  from: data, options: .mutableContainers, format: nil) as? NSMutableDictionary,
              let props = root["Scanner Properties"] as? NSDictionary,
              let units = props["functionalUnitProperties"] as? [NSDictionary],
              let unit = units.first(where: { ($0["unitNumber"] as? Int) == 0 }),
              let flatbed = unit["unitProperties"] as? NSMutableDictionary
        else { return nil }

        self.name = root["Scanner Name"] as? String ?? "Unknown Scanner"
        self.flatbed = flatbed
    }

    /// The current value of a setting, or nil if the scanner does not have it.
    func value(_ key: String) -> NSNumber? {
        guard let element = flatbed[key] as? NSDictionary else { return nil }
        switch element["type"] as? String {
        case "TWON_ONEVALUE":
            return element["value"] as? NSNumber
        case "TWON_ENUMERATION":
            guard let values = element["value"] as? [NSNumber],
                  let current = element["current"] as? Int, values.indices.contains(current)
            else { return nil }
            return values[current]
        case "TWON_RANGE":
            return element["current"] as? NSNumber
        default:
            return nil
        }
    }

    /// Applies a client's requested value for `key` from a SetParameters dictionary, if present.
    /// Values the scanner doesn't offer are ignored; settings it doesn't describe are stored as sent.
    func apply(_ key: String, from request: NSDictionary) {
        guard let requested = request[key] else { return }
        guard let element = flatbed[key] as? NSMutableDictionary else {
            flatbed[key] = requested
            return
        }
        let value = (requested as? NSDictionary)?["value"] as? NSNumber

        switch element["type"] as? String {
        case "TWON_ONEVALUE":
            flatbed[key] = requested
        case "TWON_ENUMERATION":
            if let value, let index = (element["value"] as? [NSNumber])?.firstIndex(of: value) {
                element["current"] = NSNumber(value: index)
            }
        case "TWON_RANGE":
            if let value, let min = element["min"] as? NSNumber, let max = element["max"] as? NSNumber,
               value.doubleValue >= min.doubleValue, value.doubleValue <= max.doubleValue {
                element["current"] = value
            }
        default:
            break
        }
    }

    // Convenience accessors
    var bitDepth: Int          { value("ICAP_BITDEPTH")?.intValue ?? 8 }
    var pixelType: Int?        { value("ICAP_PIXELTYPE")?.intValue }
    var xResolution: Double    { value("ICAP_XRESOLUTION")?.doubleValue ?? 0 }
    var yResolution: Double    { value("ICAP_YRESOLUTION")?.doubleValue ?? 0 }
    var nativeResolution: Double { value("ICAP_XNATIVERESOLUTION")?.doubleValue ?? 0 }
    var physicalWidth: Double  { value("ICAP_PHYSICALWIDTH")?.doubleValue ?? 0 }
    var physicalHeight: Double { value("ICAP_PHYSICALHEIGHT")?.doubleValue ?? 0 }
    var threshold: Int         { value("ICAP_THRESHOLD")?.intValue ?? 0 }
}
