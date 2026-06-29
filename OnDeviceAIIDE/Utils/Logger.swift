// MARK: - Logger Utilities
// OnDeviceAIIDE/Utils/Logger.swift
//
// Centralized logging for the IDE.

import Foundation
import os.log

/// Shared logger instance
extension Logger {
    static let app = Logger(subsystem: "com.ondeviceaiide", category: "App")
    static let ml = Logger(subsystem: "com.ondeviceaiide", category: "ML")
    static let api = Logger(subsystem: "com.ondeviceaiide", category: "API")
    static let git = Logger(subsystem: "com.ondeviceaiide", category: "Git")
    static let lsp = Logger(subsystem: "com.ondeviceaiide", category: "LSP")
    static let rag = Logger(subsystem: "com.ondeviceaiide", category: "RAG")
    static let fs = Logger(subsystem: "com.ondeviceaiide", category: "FileSystem")
}

/// In-memory log collector for UI display
actor LogCollector {
    static let shared = LogCollector()
    
    private var entries: [LogEntry] = []
    private let maxEntries = 1000
    
    func log(level: LogLevel, category: String, message: String) {
        let entry = LogEntry(
            timestamp: Date(),
            level: level,
            category: category,
            message: message
        )
        
        entries.append(entry)
        
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }
    }
    
    func recentEntries(count: Int = 100) -> [LogEntry] {
        Array(entries.suffix(count))
    }
    
    func entries(for category: String) -> [LogEntry] {
        entries.filter { $0.category == category }
    }
    
    func clear() {
        entries.removeAll()
    }
}

struct LogEntry: Identifiable, Sendable {
    let id = UUID()
    let timestamp: Date
    let level: LogLevel
    let category: String
    let message: String
    
    var formattedTime: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter.string(from: timestamp)
    }
}

enum LogLevel: String, Sendable {
    case debug = "DEBUG"
    case info = "INFO"
    case warning = "WARN"
    case error = "ERROR"
    
    var color: String {
        switch self {
        case .debug: return "6B6560"
        case .info: return "9A9590"
        case .warning: return "8B6914"
        case .error: return "8B2020"
        }
    }
}
