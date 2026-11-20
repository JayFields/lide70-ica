// SPDX-License-Identifier: GPL-2.0-or-later
//
// Running a scan: the canon_lide70 SANE backend does the scanning (through the C bridge in shim/lide70_scan.c),
// and this file delivers the rows to the client.
//
// The backend scans the whole area to a temp file before any data can be read, so there is no progress while
// the head moves. Rows are then sent with one of three transfer modes chosen by the client:
//   - overview data: image data in each progress notification (the preview scan)
//   - band data:     ICDAddBandInfoToNotificationDictionary
//   - file:          an ICA raw file, converted to the requested document format (see DocumentWriter)
// Rows are cropped/padded to exactly the width x height the client asked for. Black & white is scanned as
// 8-bit gray and thresholded here with ICAP_THRESHOLD (bit = 1 means white). Offsets arrive in native-resolution
// units; width and height in pixels at the scan resolution.

@preconcurrency import ICADevices
import LiDE70C
import CoreGraphics
import Foundation
import ImageCaptureCore
import TWAIN

/// Layout of the image sent to the client.
private struct OutputFormat {
    let width: Int
    let components: Int         // 3 = RGB, 1 = gray or black & white
    let bitsPerComponent: Int   // 8, or 1 for black & white
    var bitsPerPixel: Int { bitsPerComponent * components }
    var bytesPerRow: Int { (width * bitsPerPixel + 7) / 8 }
}

extension LiDE70Device {

    func startScan() -> ICAError {
        let r = request
        let settings = self.settings

        var xDPI = settings.xResolution
        var yDPI = settings.yResolution
        var native = settings.nativeResolution
        if xDPI <= 0 { xDPI = 75 }
        if yDPI <= 0 { yDPI = xDPI }
        if native <= 0 { native = 1200 }

        let pixelType = settings.pixelType ?? Int(TWPT_RGB)     // clients normally send one
        let bitonal = pixelType == Int(TWPT_BW) || (settings.bitDepth == 1 && pixelType != Int(TWPT_RGB))
        let color = pixelType == Int(TWPT_RGB) && !bitonal
        var threshold = settings.threshold
        if threshold <= 0 || threshold > 255 { threshold = 128 }

        // No area given (seen with some overview requests): scan the whole bed.
        var width = r.widthPixels, height = r.heightPixels
        var offsetX = r.offsetX, offsetY = r.offsetY
        if width <= 0 || height <= 0 {
            offsetX = 0; offsetY = 0
            width = Int(settings.physicalWidth / native * xDPI)
            height = Int(settings.physicalHeight / native * yDPI)
        }

        let transfer = r.overviewData ? "overview" : r.bandData ? "band data" : r.toFile ? "file" : "none"
        log(String(format: "LiDE70: scan %dx%d px at %.0fx%.0f dpi, offset %.0f,%.0f native; pixelType %d%@ "
                   + "bitDepth %d threshold %d; mode %@; transfer %@; UTI %@",
                   width, height, xDPI, yDPI, offsetX, offsetY, pixelType,
                   settings.pixelType == nil ? " (default)" : "", settings.bitDepth, threshold,
                   color ? "color" : bitonal ? "b/w" : "gray", transfer, r.documentUTI ?? "-"))

        // Area in mm. The backend truncates (br - tl) to whole pixels, so an exact N-pixel span can come back as
        // N-1; asking for half a pixel more makes the truncation land on N.
        var rq = lide70_scan_request()
        rq.dpi = Int32(xDPI)
        rq.mode = Int32(color ? LIDE70_MODE_COLOR : LIDE70_MODE_GRAY)
        rq.tl_x_mm = offsetX / native * 25.4
        rq.tl_y_mm = offsetY / native * 25.4
        rq.br_x_mm = rq.tl_x_mm + (Double(width) + 0.5) / xDPI * 25.4
        rq.br_y_mm = rq.tl_y_mm + (Double(height) + 0.5) / yDPI * 25.4

        // Run the scan. Blocks while the head moves; the USB interface is held until lide70_scan_end().
        var fmt = lide70_scan_format()
        let status = lide70_scan_begin(usbDeviceName, &rq, &fmt)
        guard status == Int32(LIDE70_GOOD) else {
            log("LiDE70: scan failed to start: \(String(cString: lide70_status_name(status)))")
            let busyOrIO = status == Int32(LIDE70_DEVICE_BUSY) || status == Int32(LIDE70_IO_ERROR)
            return ICAError(busyOrIO ? kICACommunicationErr : kICADeviceInternalErr)
        }
        log("LiDE70: backend returned \(fmt.pixels_per_line)x\(fmt.lines) px at \(fmt.dpi) dpi, "
            + "\(fmt.bytes_per_line) bytes/line, \(fmt.channels) channel(s)")
        if fmt.pixels_per_line != width || fmt.lines != height {
            log("LiDE70: backend size differs from request; cropping/padding to \(width)x\(height)")
        }

        let out = OutputFormat(width: width, components: color ? 3 : 1, bitsPerComponent: bitonal ? 1 : 8)
        let colorSpace = makeColorSpace(color: color, colorSyncMode: r.colorSyncMode)

        var document: DocumentWriter?
        if r.toFile {
            document = DocumentWriter(request: r, icaObject: icaObject)
            guard let document else {
                lide70_scan_end()
                return ICAError(kICADeviceInternalErr)
            }
            document.writeHeader(width: width, height: height, bitsPerComponent: out.bitsPerComponent,
                                 bitsPerPixel: out.bitsPerPixel, components: out.components,
                                 bytesPerRow: out.bytesPerRow, colorSpace: colorSpace, dpi: xDPI, request: r)
        }

        // Read rows from the backend, convert them into a band, and deliver each full band.
        let delivery = deliverRows(from: fmt, as: out, height: height, threshold: threshold, request: r,
                                   document: document)

        // Release the scanner (drains unread data so the backend deletes its temp file).
        lide70_scan_end()
        log("LiDE70: delivered \(delivery.rows) rows\(delivery.cancelled ? " (cancelled)" : "")"
            + "\(delivery.error != .ok ? " (error)" : "")")

        var err = delivery.error
        if let document {
            let ok = document.finish(save: !delivery.cancelled && err == .ok, uti: r.documentUTI,
                                     colorSpace: colorSpace, metadata: r.metadata)
            if !ok && err == .ok { err = ICAError(kICADeviceInternalErr) }
        }

        sendNotification(kICANotificationTypeScannerPageDone, object: icaObject) { note in
            if let document { note[key(kICANotificationScannerDocumentNameKey)] = document.documentURL.path }
        }
        sendNotification(kICANotificationTypeScannerScanDone, object: icaObject)
        if delivery.cancelled {
            sendNotification(kICANotificationTypeTransactionCanceled, object: icaObject)
        }
        return err
    }

    // MARK: - Row delivery

    private func deliverRows(from fmt: lide70_scan_format, as out: OutputFormat, height: Int, threshold: Int,
                             request r: ScanRequest, document: DocumentWriter?)
        -> (rows: Int, cancelled: Bool, error: ICAError) {

        let rowsPerBand = max(1, r.maxBandBytes / out.bytesPerRow)
        var band = [UInt8](repeating: 0, count: out.bytesPerRow * rowsPerBand)
        var line = [UInt8](repeating: 0, count: Int(fmt.bytes_per_line))
        let srcChannels = Int(fmt.channels)
        let copyPixels = min(out.width, Int(fmt.pixels_per_line))
        let userCancelled = UInt32(bitPattern: Int32(userCanceledErr))
        var sourceDone = false
        var fillPoint = 0           // first row of the current band
        var rowInBand = 0

        if srcChannels != out.components {
            log("LiDE70: unexpected backend channel count \(srcChannels) (want \(out.components))")
        }

        for row in 0..<height {
            // 1. Read one backend row; past the end of its data, rows are white.
            var have = 0
            while !sourceDone && have < line.count {
                var got: Int32 = 0
                let status = line.withUnsafeMutableBufferPointer {
                    lide70_scan_read($0.baseAddress! + have, Int32($0.count - have), &got)
                }
                if status == Int32(LIDE70_GOOD) {
                    have += Int(got)
                } else {
                    sourceDone = true
                    if status != Int32(LIDE70_EOF) {
                        log("LiDE70: read error at row \(row): \(String(cString: lide70_status_name(status)))")
                        return (fillPoint, false, ICAError(kICACommunicationErr))
                    }
                    if row < fmt.lines { log("LiDE70: backend data ended at row \(row) of \(fmt.lines); padding") }
                }
            }
            for i in have..<line.count { line[i] = 0xff }

            // 2. Convert it into the band.
            let start = rowInBand * out.bytesPerRow
            if out.bitsPerComponent == 1 {
                for i in start..<start + out.bytesPerRow { band[i] = 0 }
                for x in 0..<out.width {
                    let v = x < copyPixels ? Int(line[x * srcChannels]) : 0xff
                    if v > threshold { band[start + (x >> 3)] |= UInt8(0x80 >> (x & 7)) }
                }
            } else {
                for x in 0..<out.width {
                    for c in 0..<out.components {
                        // backend pixel (first channel if the layouts differ), white beyond its width
                        let src = srcChannels == out.components ? x * srcChannels + c : x * srcChannels
                        band[start + x * out.components + c] = x < copyPixels ? line[src] : 0xff
                    }
                }
            }
            rowInBand += 1
            if rowInBand < rowsPerBand && row + 1 < height { continue }

            // 3. Deliver the band.
            let rows = rowInBand
            let reply = sendNotification(kICANotificationTypeScanProgressStatus, object: icaObject,
                                         waitForReply: true) { note in
                band.withUnsafeMutableBytes { bytes in
                    let dict = note as CFMutableDictionary
                    let w = UInt32(out.width), h = UInt32(height), bpr = UInt32(out.bytesPerRow)
                    let size = UInt32(out.bytesPerRow * rows)
                    if r.overviewData {
                        ICDAddImageInfoToNotificationDictionary(dict, w, h, bpr, UInt32(fillPoint), UInt32(rows),
                                                                size, bytes.baseAddress)
                    } else if r.bandData {
                        let pixelType = out.components == 3 ? ICScannerPixelDataType.RGB : .gray
                        ICDAddBandInfoToNotificationDictionary(dict, w, h, UInt32(out.bitsPerPixel),
                                                               UInt32(out.bitsPerComponent), UInt32(out.components),
                                                               0, UInt32(pixelType.rawValue), bpr,
                                                               UInt32(fillPoint), UInt32(rows), size, bytes.baseAddress)
                    } else if r.toFile {
                        ICDAddImageInfoToNotificationDictionary(dict, w, h, bpr, UInt32(fillPoint), UInt32(rows),
                                                                0, nil)
                    }
                }
            }
            document?.write(Data(band[0..<out.bytesPerRow * rows]))
            fillPoint += rows
            rowInBand = 0
            if reply == userCancelled { return (fillPoint, true, .ok) }
        }
        return (fillPoint, false, .ok)
    }

    // MARK: - Color space

    /// The color space for the scanned image, using the client's ColorSync mode where possible.
    private func makeColorSpace(color: Bool, colorSyncMode: String?) -> CGColorSpace {
        var profilePath = Array("\(NSTemporaryDirectory())lide70-\(getpid())".utf8CString)
        let space = profilePath.withUnsafeMutableBufferPointer { path in
            ICDCreateColorSpace(color ? 24 : 8, color ? 3 : 1, icaObject, colorSyncMode as CFString?, nil,
                                path.baseAddress)?.takeRetainedValue()
        }
        return space ?? (color ? CGColorSpaceCreateDeviceRGB() : CGColorSpaceCreateDeviceGray())
    }
}
