// SPDX-License-Identifier: GPL-2.0-or-later
//
// The C entry points ICADevices calls. Each one finds the LiDE70Device stored in the ScannerObjectInfo's
// `privateData` and forwards to it. They are plain global functions so Swift can pass them to C as
// function pointers (see main.swift).

@preconcurrency import ICADevices
import Foundation

// MARK: - LiDE70Device <-> ScannerObjectInfo

/// Open scanners by USB locationID, so a device that is already open is not opened twice.
/// ICADevices calls from its own threads, hence the lock.
private final class ScannerRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var scanners: [UInt32: LiDE70Device] = [:]

    func contains(_ locationID: UInt32) -> Bool { lock.withLock { scanners[locationID] != nil } }
    func add(_ s: LiDE70Device) { lock.withLock { scanners[s.locationID] = s } }
    func remove(_ locationID: UInt32) { lock.withLock { _ = scanners.removeValue(forKey: locationID) } }
}

private let registry = ScannerRegistry()

/// The LiDE70Device stored in an object's privateData (device objects only).
private func device(_ info: UnsafePointer<ScannerObjectInfo>?) -> LiDE70Device? {
    guard let raw = info?.pointee.privateData else { return nil }
    return Unmanaged<LiDE70Device>.fromOpaque(UnsafeRawPointer(raw)).takeUnretainedValue()
}

private func device(_ info: UnsafeMutablePointer<ScannerObjectInfo>?) -> LiDE70Device? {
    device(UnsafePointer(info))
}

// MARK: - Device lifetime

/// Called when the USB device is attached (by icdd, with the device's IOKit locationID).
func openUSBDevice(_ locationID: UInt32, _ info: UnsafeMutablePointer<ScannerObjectInfo>?) -> ICAError {
    log("--> openUSBDevice")
    guard let info else { return ICAError(paramErr) }
    // A locationID of 0 meant "launched from Xcode" for the 2012 sample; current ICADevices no longer
    // runs a module that wasn't launched by icdd, so there is nothing to look up.
    guard locationID != 0, !registry.contains(locationID),
          let s = LiDE70Device(locationID: locationID)
    else { return ICAError(paramErr) }

    // Keep one strong reference in privateData (released in closeDevice) and one in the registry.
    info.pointee.privateData = Unmanaged.passRetained(s).toOpaque().assumingMemoryBound(to: CChar.self)
    info.pointee.flags = 0
    info.pointee.thumbnailSize = 1      // "has a thumbnail"; clients size thumbnails themselves
    info.pointee.dataSize = 0
    info.pointee.icaObjectInfo.objectType = OSType(kICADevice)
    info.pointee.icaObjectInfo.objectSubtype = OSType(kICADeviceScanner)
    copyCString(s.name, into: &info.pointee.name)

    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
    copyCString(formatter.string(from: Date()), into: &info.pointee.creationDate)

    s.deviceObjectInfo = info
    registry.add(s)
    return .ok
}

func closeDevice(_ info: UnsafeMutablePointer<ScannerObjectInfo>?) -> ICAError {
    log("--> closeDevice")
    guard let info, let raw = info.pointee.privateData else { return ICAError(paramErr) }
    let s = Unmanaged<LiDE70Device>.fromOpaque(UnsafeRawPointer(raw)).takeRetainedValue()
    info.pointee.privateData = nil
    registry.remove(s.locationID)
    return .ok
}

/// Called once for every object the module created. Nothing to free: the LiDE70Device is released in closeDevice.
func cleanup(_ info: UnsafeMutablePointer<ScannerObjectInfo>?) -> ICAError { .ok }

/// Called periodically; a module that polls the device (e.g. for button presses) would do it here.
func periodicTask(_ info: UnsafeMutablePointer<ScannerObjectInfo>?) -> ICAError { .ok }

// MARK: - Objects and messages

/// Scanned images are only published as child objects for remote clients, which are not supported,
/// so the device has no children.
func getObjectInfo(_ parent: UnsafePointer<ScannerObjectInfo>?, _ index: UInt32,
                   _ newInfo: UnsafeMutablePointer<ScannerObjectInfo>?) -> ICAError {
    ICAError(kICAIndexOutOfRangeErr)
}

func readFileData(_ info: UnsafePointer<ScannerObjectInfo>?, _ dataType: UInt32, _ buffer: UnsafeMutablePointer<CChar>?,
                  _ offset: UInt32, _ length: UnsafeMutablePointer<UInt32>?) -> ICAError {
    ICAError(paramErr)
}

func sendMessage(_ info: UnsafePointer<ScannerObjectInfo>?, _ pb: UnsafeMutablePointer<ICD_ScannerObjectSendMessagePB>?,
                 _ completion: ICDCompletion?) -> ICAError {
    guard let pb else { return ICAError(paramErr) }
    var err = ICAError.ok

    switch Int(pb.pointee.message.messageType) {
    case kICAMessageGetLastButtonPressed:
        // The LiDE 70's buttons are not read by the backend: report "no button".
        if let data = pb.pointee.message.dataPtr, pb.pointee.message.dataSize == 4 {
            data.assumingMemoryBound(to: OSType.self).pointee = 0
            pb.pointee.message.dataType = 0
        } else {
            err = ICAError(paramErr)
        }
    case kICAMessageScannerOverviewSelectionChanged:
        break   // the selection needs no device-side processing
    default:
        err = ICAError(paramErr)
        pb.pointee.result = UInt32(bitPattern: Int32(err))
    }

    pb.pointee.header.err = err
    if err == .ok, let completion {
        pb.withMemoryRebound(to: ICDHeader.self, capacity: 1) { completion($0) }
    }
    return err
}

func addPropertiesToDictionary(_ info: UnsafeMutablePointer<ScannerObjectInfo>?,
                               _ dict: CFMutableDictionary?) -> ICAError {
    guard let s = device(info), info?.pointee.icaObjectInfo.objectType == OSType(kICADevice),
          let dict = dict as NSMutableDictionary?
    else { return ICAError(paramErr) }
    s.addProperties(to: dict)
    return .ok
}

// MARK: - Sessions, parameters, scanning

func openSession(_ info: UnsafePointer<ScannerObjectInfo>?, _ pb: UnsafeMutablePointer<ICD_ScannerOpenSessionPB>?)
    -> ICAError {
    log("--> openSession")
    return device(info)?.openSession() ?? ICAError(paramErr)
}

func closeSession(_ info: UnsafePointer<ScannerObjectInfo>?, _ pb: UnsafeMutablePointer<ICD_ScannerCloseSessionPB>?)
    -> ICAError {
    log("--> closeSession")
    return device(info)?.closeSession() ?? ICAError(paramErr)
}

func getParameters(_ info: UnsafePointer<ScannerObjectInfo>?, _ pb: UnsafeMutablePointer<ICD_ScannerGetParametersPB>?)
    -> ICAError {
    log("--> getParameters")
    guard let s = device(info), let cf = pb?.pointee.theDict?.takeUnretainedValue() else { return ICAError(paramErr) }
    let dict = cf as NSMutableDictionary
    return s.getParameters(into: dict)
}

func setParameters(_ info: UnsafePointer<ScannerObjectInfo>?, _ pb: UnsafeMutablePointer<ICD_ScannerSetParametersPB>?)
    -> ICAError {
    log("--> setParameters")
    guard let s = device(info), let cf = pb?.pointee.theDict?.takeUnretainedValue() else { return ICAError(paramErr) }
    let dict = cf as NSDictionary
    return s.setParameters(from: dict)
}

/// Not called by current Image Capture.
func status(_ info: UnsafePointer<ScannerObjectInfo>?, _ pb: UnsafeMutablePointer<ICD_ScannerStatusPB>?) -> ICAError {
    .ok
}

func start(_ info: UnsafePointer<ScannerObjectInfo>?, _ pb: UnsafeMutablePointer<ICD_ScannerStartPB>?) -> ICAError {
    log("--> start")
    return device(info)?.startScan() ?? ICAError(paramErr)
}
