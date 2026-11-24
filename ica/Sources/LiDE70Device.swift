// SPDX-License-Identifier: Apache-2.0
// Portions adapted from Apple's VirtualScanner sample code, Copyright (C) 2012 Apple Inc.
//
// One attached LiDE 70. Created when ICA opens the USB device; ICA then calls into it through the C entry
// points in EntryPoints.swift. Structure adapted from Apple's VirtualScanner sample (2012), USB path only.

@preconcurrency import ICADevices
import LiDE70C
import Foundation
import ShadingCalibration
import UniformTypeIdentifiers

/// A white-strip reading kept for reuse by later scans (see `stripCalibratedReference` in Scan.swift).
struct StripReading {
    let stripDPI: Int
    let gainCode: Int
    let strip: WhiteReference
    let time: Date
}

/// What the client asked for in its last SetParameters call.
struct ScanRequest {
    var widthPixels = 0             // at the scan resolution
    var heightPixels = 0
    var offsetX = 0.0               // in native-resolution units (1/1200 in)
    var offsetY = 0.0

    var overviewData = false        // send image data in progress notifications (preview scan)
    var bandData = false            // send image data as bands (ICDAddBandInfoToNotificationDictionary)
    var toFile = false              // write a document file and report its path
    var maxBandBytes = 512 * 1024

    var colorSyncMode: String?
    var documentName: String?
    var documentFolder: String?     // absent when the client is remote (not supported here)
    var documentUTI: String?
    var documentExtension: String?
    var metadata: NSDictionary?     // added to the saved image (e.g. orientation)
}

/// ICA calls the module from its own threads; the module serialises scans itself (one session at a time, and the
/// backend bridge refuses a second concurrent scan), so the class is marked @unchecked Sendable.
final class LiDE70Device: @unchecked Sendable {
    let locationID: UInt32
    let usbDeviceName: String               // shim name, "libusb:BUS:ADDR"
    let settings: ScannerSettings
    let deviceInfoURL: URL

    /// ICA's record for this device (owned by ICADevices); used for the device's ICAObject id.
    var deviceObjectInfo: UnsafeMutablePointer<ScannerObjectInfo>?
    var icaObject: ICAObject { deviceObjectInfo?.pointee.icaObject ?? 0 }

    var sessionOpen = false
    var request = ScanRequest()

    /// The most recent white-strip reading, reused by scans shortly after it. Only touched from the scan, which
    /// ICADevices runs on its callback thread one at a time.
    var lastStripReading: StripReading?

    var name: String { settings.name }

    init?(locationID: UInt32) {
        let bundle = Bundle.main
        guard let propsURL = bundle.url(forResource: "ScannerProperties", withExtension: "plist"),
              let infoURL = bundle.url(forResource: "DeviceInfo", withExtension: "plist"),
              let settings = ScannerSettings(contentsOf: propsURL)
        else {
            log("LiDE70: missing or unreadable ScannerProperties.plist / DeviceInfo.plist in bundle")
            return nil
        }

        // Map ICA's locationID to the libusb shim's device name.
        var buffer = [CChar](repeating: 0, count: 32)
        guard lide70_usb_name_for_location(locationID, &buffer, buffer.count) == 0 else {
            log(String(format: "LiDE70: no libusb device at locationID 0x%08x", locationID))
            return nil
        }
        let deviceName = buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }

        // Check that this process can claim the interface, then release it: the scanner is only held during a scan.
        let status = lide70_usb_probe_claim(deviceName)
        log(String(format: "LiDE70: locationID 0x%08x -> %@, probe claim status %d (0 = GOOD, 3 = DEVICE_BUSY)",
                   locationID, deviceName, status))

        self.locationID = locationID
        self.usbDeviceName = deviceName
        self.settings = settings
        self.deviceInfoURL = infoURL
    }

    // MARK: - Device properties

    /// Adds device properties for clients: the display name and support for ICA raw files.
    func addProperties(to dict: NSMutableDictionary) {
        if let info = NSDictionary(contentsOf: deviceInfoURL),
           let device = (info["devices"] as? NSDictionary)?[name] as? NSDictionary,
           let buttons = device["ButtonTypes"] {
            dict["Buttons"] = buttons
        }
        // Supersedes the 32-character name in the device's object info.
        dict[key(kICAUserAssignedDeviceNameKey)] = name
        dict["supportsICARawFileFormat"] = 1
    }

    // MARK: - Sessions (one client at a time)

    func openSession() -> ICAError {
        if sessionOpen { return ICAError(kICAInvalidSessionErr) }
        sessionOpen = true
        return .ok
    }

    func closeSession() -> ICAError {
        if !sessionOpen { return ICAError(kICAInvalidSessionErr) }
        sessionOpen = false
        return .ok
    }

    // MARK: - Parameters

    /// GetParameters: the flatbed's settings, under "device".
    func getParameters(into dict: NSMutableDictionary) -> ICAError {
        dict["device"] = settings.flatbed
        return .ok
    }

    /// SetParameters: the client's settings for the next scan, under "userScanArea" (a dictionary, or an array
    /// whose second element is the dictionary).
    func setParameters(from dict: NSDictionary) -> ICAError {
        log("Scan Parameters Passed In:\(dict)")

        let area: NSDictionary?
        if let array = dict["userScanArea"] as? NSArray, array.count > 1 {
            area = array[1] as? NSDictionary
        } else {
            area = dict["userScanArea"] as? NSDictionary
        }
        guard let area else { return .ok }

        // Only the flatbed exists, so a functional-unit change needs nothing else.
        if area["selectedFunctionalUnitType"] != nil { return .ok }

        for setting in ["ICAP_BITDEPTH", "ICAP_PIXELTYPE", "ICAP_UNITS", "ICAP_XRESOLUTION", "ICAP_YRESOLUTION",
                        "ICAP_XSCALING", "ICAP_YSCALING", "ICAP_THRESHOLD"] {
            settings.apply(setting, from: area)
        }

        var r = ScanRequest()
        r.overviewData = (area["progressNotificationWithData"] as? NSNumber)?.boolValue ?? false
        r.toFile = (area["progressNotificationNoData"] as? NSNumber)?.boolValue ?? false
        r.bandData = (area["progressNotificationWithScanData"] as? NSNumber)?.boolValue ?? false
        if let max = (area["progressNotificationWithScanDataMaxBandSize"] as? NSNumber)?.intValue, max > 0 {
            r.maxBandBytes = max
        }

        r.colorSyncMode = area["ColorSyncMode"] as? String
        r.documentName = area["document name"] as? String
        r.documentFolder = area["document folder"] as? String
        r.documentUTI = area["document format"] as? String
        if r.documentUTI == nil && r.toFile { r.documentUTI = UTType.tiff.identifier }
        r.documentExtension = area["document extension"] as? String
        if r.documentExtension == nil && r.toFile, let uti = r.documentUTI {
            r.documentExtension = UTType(uti)?.preferredFilenameExtension
        }
        r.metadata = area["metadata"] as? NSDictionary

        // Read numbers through NSNumber: `as? Int` would fail for a non-integral value such as 1401.5.
        r.widthPixels = (area["width"] as? NSNumber)?.intValue ?? 0
        r.heightPixels = (area["height"] as? NSNumber)?.intValue ?? 0
        r.offsetX = (area["offsetX"] as? NSNumber)?.doubleValue ?? 0
        r.offsetY = (area["offsetY"] as? NSNumber)?.doubleValue ?? 0
        request = r
        return .ok
    }
}
