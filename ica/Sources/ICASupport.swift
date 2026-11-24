// SPDX-License-Identifier: Apache-2.0
// Portions adapted from Apple's VirtualScanner sample code, Copyright (C) 2012 Apple Inc.
//
// Small helpers that make the C-based ICADevices API easier to use from Swift.

@preconcurrency import ICADevices
import Foundation

// MARK: - Error codes

/// ICADevices callbacks return `ICAError` (an Int16); the SDK's error constants are imported as Int.
extension ICAError {
    static let ok: ICAError = 0
    init(_ code: Int) { self = ICAError(truncatingIfNeeded: code) }
}

// MARK: - Notifications

/// Notification keys and types are imported as optional CFStrings; this unwraps them for dictionary use.
func key(_ s: CFString?) -> String { s! as String }

/// Sends an ICA notification about `object`.
///
/// - Parameters:
///   - type: one of the `kICANotificationType…` constants.
///   - fill: adds extra entries to the notification dictionary before it is sent.
///   - waitForReply: wait for the client's reply (used for scan progress, where the reply can be "cancel").
/// - Returns: the client's reply code when `waitForReply` is set, otherwise 0.
@discardableResult
func sendNotification(_ type: CFString?, object: ICAObject, waitForReply: Bool = false,
                      fill: (NSMutableDictionary) -> Void = { _ in }) -> UInt32 {
    let note = NSMutableDictionary()
    note[key(kICANotificationICAObjectKey)] = NSNumber(value: object)
    note[key(kICANotificationTypeKey)] = key(type)
    fill(note)

    var pb = ICASendNotificationPB()
    pb.notificationDictionary = Unmanaged.passUnretained(note as CFMutableDictionary)
    let err = waitForReply ? ICDSendNotificationAndWaitForReply(&pb) : ICDSendNotification(&pb)
    if err != .ok {
        log("LiDE70: sending \(key(type)) failed: \(err)")
        return 0
    }
    return waitForReply ? pb.replyCode : 0
}

// MARK: - Fixed-size C character arrays

/// Copies `string` into a fixed-size C char array (imported by Swift as a tuple), NUL-terminated.
func copyCString<T>(_ string: String, into field: inout T) {
    withUnsafeMutableBytes(of: &field) { buffer in
        buffer.initializeMemory(as: UInt8.self, repeating: 0)
        let bytes = Array(string.utf8.prefix(buffer.count - 1))
        buffer.copyBytes(from: bytes)
    }
}

/// An OSType such as 'btn?' as readable text, for logging.
func fourCharCode(_ code: UInt32) -> String {
    let bytes = [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: code >> $0) }
    return bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7f })
        ? String(decoding: bytes, as: UTF8.self) : String(format: "0x%08x", code)
}
