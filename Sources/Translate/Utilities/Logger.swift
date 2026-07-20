import Foundation
import os.log

enum Log {
    private static let subsystem = "com.translate.app"

    static let app     = Logger(subsystem: subsystem, category: "app")
    static let api     = Logger(subsystem: subsystem, category: "api")
    static let ocr     = Logger(subsystem: subsystem, category: "ocr")
    static let screen  = Logger(subsystem: subsystem, category: "screen")
    static let hotkey  = Logger(subsystem: subsystem, category: "hotkey")
    static let sel     = Logger(subsystem: subsystem, category: "selection")
}
