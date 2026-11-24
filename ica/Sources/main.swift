// SPDX-License-Identifier: Apache-2.0
// Portions adapted from Apple's VirtualScanner sample code, Copyright (C) 2012 Apple Inc.
//
// LiDE70Scanner: Image Capture device module for the Canon CanoScan LiDE 70 / LiDE 600.
//
// icdd launches this app when a client (Image Capture, Preview) selects the scanner. The module registers its
// callbacks with ICADevices and hands control to ICD_ScannerMain, which runs until the device is deselected.

@preconcurrency import ICADevices

// ICADevices calls the module through this table of C function pointers. Unset entries are not called.
gICDScannerCallbackFunctions.f_ICD_ScannerOpenUSBDevice = openUSBDevice
gICDScannerCallbackFunctions.f_ICD_ScannerCloseDevice = closeDevice
gICDScannerCallbackFunctions.f_ICD_ScannerPeriodicTask = periodicTask
gICDScannerCallbackFunctions.f_ICD_ScannerGetObjectInfo = getObjectInfo
gICDScannerCallbackFunctions.f_ICD_ScannerCleanup = cleanup
gICDScannerCallbackFunctions.f_ICD_ScannerReadFileData = readFileData
gICDScannerCallbackFunctions.f_ICD_ScannerSendMessage = sendMessage
gICDScannerCallbackFunctions.f_ICD_ScannerAddPropertiesToCFDictionary = addPropertiesToDictionary
gICDScannerCallbackFunctions.f_ICD_ScannerOpenSession = openSession
gICDScannerCallbackFunctions.f_ICD_ScannerCloseSession = closeSession
gICDScannerCallbackFunctions.f_ICD_ScannerGetParameters = getParameters
gICDScannerCallbackFunctions.f_ICD_ScannerSetParameters = setParameters
gICDScannerCallbackFunctions.f_ICD_ScannerStatus = status
gICDScannerCallbackFunctions.f_ICD_ScannerStart = start

let result = CommandLine.unsafeArgv.withMemoryRebound(to: UnsafePointer<CChar>?.self, capacity: Int(CommandLine.argc)) {
    ICD_ScannerMain(CommandLine.argc, $0)
}
exit(result)
