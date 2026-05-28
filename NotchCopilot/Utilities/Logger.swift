import Foundation
import os

enum AppLog {
    static let subsystem = "com.notchcopilot.app"
    static let app = Logger(subsystem: subsystem, category: "app")
    static let audio = Logger(subsystem: subsystem, category: "audio")
    static let ai = Logger(subsystem: subsystem, category: "ai")
    static let persistence = Logger(subsystem: subsystem, category: "persistence")
}

