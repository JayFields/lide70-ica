// SPDX-License-Identifier: GPL-2.0-or-later
//
// File transfer ("progressNotificationNoData"): the scan is written as an ICA raw file (header + rows). If the
// client asked for another format (JPEG, TIFF, PNG, ...), the raw file is a temporary backing store that is
// converted with ImageIO once the scan is complete.

@preconcurrency import ICADevices
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

final class DocumentWriter {
    /// The document the client will receive (reported in the page-done notification).
    let documentURL: URL
    private let rawURL: URL
    private let handle: FileHandle
    private let wantsRaw: Bool

    /// Image layout, recorded by writeHeader and needed again to convert the raw file.
    private var width = 0, height = 0, bitsPerComponent = 0, bitsPerPixel = 0, bytesPerRow = 0

    private static let headerSize = MemoryLayout<ICARawFileHeader>.size

    /// Picks a file name that doesn't exist yet ("Scan.jpeg", "Scan 1.jpeg", ...) and opens the raw file.
    init?(request: ScanRequest, icaObject: ICAObject) {
        let ext = request.documentExtension ?? "tiff"
        let folder: URL
        let baseName: String
        if let documentFolder = request.documentFolder {
            folder = URL(fileURLWithPath: (documentFolder as NSString).expandingTildeInPath)
            baseName = request.documentName ?? "Scan"
        } else {
            // Remote clients (scanner sharing) expect the module to publish the scan as an ICA object;
            // that is not implemented, so the file is only written to the temporary directory.
            log("LiDE70: no document folder (remote client?); saving to the temporary directory")
            folder = FileManager.default.temporaryDirectory
            baseName = String(format: "%08x_scan", icaObject)
        }

        var candidate = folder.appendingPathComponent("\(baseName).\(ext)")
        var n = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(baseName) \(n).\(ext)")
            n += 1
        }
        documentURL = candidate
        wantsRaw = (request.documentUTI == (kICUTTypeRaw as String?))
        rawURL = wantsRaw ? candidate
            : FileManager.default.temporaryDirectory.appendingPathComponent("icaRawImage-\(UUID().uuidString).ica")

        guard FileManager.default.createFile(atPath: rawURL.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: rawURL)
        else {
            log("LiDE70: cannot create \(rawURL.path)")
            return nil
        }
        self.handle = handle
    }

    func writeHeader(width: Int, height: Int, bitsPerComponent: Int, bitsPerPixel: Int, components: Int,
                     bytesPerRow: Int, colorSpace: CGColorSpace, dpi: Double, request: ScanRequest) {
        (self.width, self.height, self.bitsPerComponent, self.bitsPerPixel, self.bytesPerRow) =
            (width, height, bitsPerComponent, bitsPerPixel, bytesPerRow)

        var h = ICARawFileHeader()
        h.imageDataOffset = UInt32(Self.headerSize)
        h.version = 1
        h.imageWidth = UInt32(width)
        h.imageHeight = UInt32(height)
        h.bytesPerRow = UInt32(bytesPerRow)
        h.numberOfComponents = UInt32(components)
        h.bitsPerComponent = UInt32(bitsPerComponent)
        h.bitsPerPixel = UInt32(bitsPerPixel)
        h.cgColorSpaceModel = UInt32(colorSpace.model.rawValue)
        h.bitmapInfo = CGImageAlphaInfo.none.rawValue
        h.orientation = (request.metadata?["Orientation"] as? NSNumber)?.uint32Value ?? 1
        h.dpi = UInt32(dpi)
        copyCString(request.colorSyncMode ?? "", into: &h.colorSyncModeStr)
        write(withUnsafeBytes(of: &h) { Data($0) })
    }

    func write(_ data: Data) {
        try? handle.write(contentsOf: data)
    }

    /// Closes the raw file and, if needed, converts it to the requested format. With `save` false (cancelled or
    /// failed scan), nothing is converted. Returns false if the conversion failed.
    func finish(save: Bool, uti: String?, colorSpace: CGColorSpace, metadata: NSDictionary?) -> Bool {
        try? handle.close()
        if wantsRaw { return true }
        defer { try? FileManager.default.removeItem(at: rawURL) }
        guard save else { return true }

        // Map the raw file instead of reading it: a 1200 dpi page is several hundred MB.
        guard let mapped = try? NSData(contentsOf: rawURL, options: .alwaysMapped),
              mapped.length >= Self.headerSize + bytesPerRow * height
        else {
            log("LiDE70: raw image file is missing or short")
            return false
        }
        return withExtendedLifetime(mapped) {
            let pixels = NSData(bytesNoCopy: UnsafeMutableRawPointer(mutating: mapped.bytes + Self.headerSize),
                                length: bytesPerRow * height, freeWhenDone: false)
            guard let provider = CGDataProvider(data: pixels),
                  let image = CGImage(width: width, height: height, bitsPerComponent: bitsPerComponent,
                                      bitsPerPixel: bitsPerPixel, bytesPerRow: bytesPerRow, space: colorSpace,
                                      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                                      provider: provider, decode: nil, shouldInterpolate: false,
                                      intent: .defaultIntent),
                  let destination = CGImageDestinationCreateWithURL(
                      documentURL as CFURL, (uti ?? UTType.tiff.identifier) as CFString, 1, nil)
            else {
                log("LiDE70: cannot create image or destination for \(documentURL.path)")
                return false
            }
            CGImageDestinationAddImage(destination, image, metadata)
            return CGImageDestinationFinalize(destination)
        }
    }
}
