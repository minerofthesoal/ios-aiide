// MARK: - Platform Process Compatibility
// OnDeviceAIIDE/Utils/PlatformProcess.swift
//
// iOS does not expose Foundation.Process for spawning local command-line tools.
// The app still keeps process-backed service APIs for macOS tooling and future
// helper integration, while iOS builds fail gracefully if execution is attempted.

import Foundation

#if os(iOS)
final class Process {
    var executableURL: URL?
    var arguments: [String]?
    var currentDirectoryURL: URL?
    var standardInput: Any?
    var standardOutput: Any?
    var standardError: Any?
    var isRunning: Bool { false }
    var terminationStatus: Int32 { 127 }

    func run() throws {
        throw NSError(
            domain: "com.ondeviceaiide.process",
            code: Int(terminationStatus),
            userInfo: [NSLocalizedDescriptionKey: "Local command processes are unavailable on iOS."]
        )
    }

    func waitUntilExit() {}
    func terminate() {}
}
#endif
