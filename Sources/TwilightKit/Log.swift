import Foundation
import os
import TwilightKitC

/// Shared logger. moonlight-common-c log lines are routed here through `TwSetLogHandler`.
public enum TwilightLog {
    public static let logger = Logger(subsystem: "com.twilight.vision", category: "TwilightKit")

    static func installCoreHandler() {
        TwSetLogHandler { message in
            guard let message else { return }
            let text = String(cString: message).trimmingCharacters(in: .whitespacesAndNewlines)
            TwilightLog.logger.info("[core] \(text, privacy: .public)")
        }
    }

    public static func info(_ message: String) {
        logger.info("\(message, privacy: .public)")
    }

    /// Diagnostics that are only kept while debugging (not persisted by the system log).
    public static func debug(_ message: String) {
        logger.debug("\(message, privacy: .public)")
    }

    public static func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
    }
}
