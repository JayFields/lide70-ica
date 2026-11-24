// SPDX-License-Identifier: Apache-2.0
// Portions adapted from Apple's VirtualScanner sample code, Copyright (C) 2012 Apple Inc.
//
// Logging for the device module. Messages go to the unified log:
//   /usr/bin/log stream --predicate 'subsystem == "local.lide70ica"'

import os

private let logger = Logger(subsystem: "local.lide70ica", category: "module")

/// Logs a message. Interpolated values are marked public so they are not redacted as <private>.
func log(_ message: String) {
    logger.log("\(message, privacy: .public)")
}
