// MARK: - File System Manager
// OnDeviceAIIDE/Services/Storage/FileSystemManager.swift
//
// Multi-file workspace file manager with project hierarchies,
// file creation/deletion/rename, and iOS sandbox integration.

import Foundation
import UIKit
import UniformTypeIdentifiers
import os.log

/// Manages the on-device file system workspace for projects
actor FileSystemManager {
    
    static let shared = FileSystemManager()
    
    private let logger = Logger(subsystem: "com.ondeviceaiide", category: "FileSystemManager")
    private let fileManager = FileManager.default
    
    /// Root directory for all projects
    private(set) var projectsDirectory: URL!
    
    private init() {
        setupDirectoryStructure()
    }
    
    private func setupDirectoryStructure() {
        let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        projectsDirectory = docs.appendingPathComponent("Projects", isDirectory: true)
        try? fileManager.createDirectory(at: projectsDirectory, withIntermediateDirectories: true)
    }
    
    // MARK: - Project Management
    
    /// Create a new project with standard directory structure
    func createProject(name: String, template: ProjectTemplate = .empty) throws -> Project {
        let sanitized = sanitizeProjectName(name)
        let projectDir = projectsDirectory.appendingPathComponent(sanitized, isDirectory: true)
        
        guard !fileManager.fileExists(atPath: projectDir.path) else {
            throw FileSystemError.projectAlreadyExists(name)
        }
        
        try fileManager.createDirectory(at: projectDir, withIntermediateDirectories: true)
        
        // Create standard directories based on template
        for dir in template.defaultDirectories {
            let subDir = projectDir.appendingPathComponent(dir, isDirectory: true)
            try fileManager.createDirectory(at: subDir, withIntermediateDirectories: true)
        }
        
        // Create template files
        for (filePath, content) in template.defaultFiles {
            let fileURL = projectDir.appendingPathComponent(filePath)
            try? fileManager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.write(to: fileURL, atomically: true, encoding: .utf8)
        }
        
        let project = Project(
            id: UUID(),
            name: sanitized,
            rootPath: projectDir,
            template: template,
            createdAt: Date(),
            lastModified: Date()
        )
        
        logger.info("Created project: \(sanitized)")
        return project
    }
    
    /// Delete a project and all its contents
    func deleteProject(_ project: Project) throws {
        guard fileManager.fileExists(atPath: project.rootPath.path) else {
            throw FileSystemError.projectNotFound(project.name)
        }
        try fileManager.removeItem(at: project.rootPath)
        logger.info("Deleted project: \(project.name)")
    }
    
    /// Rename a project
    func renameProject(_ project: Project, to newName: String) throws -> Project {
        let sanitized = sanitizeProjectName(newName)
        let newPath = projectsDirectory.appendingPathComponent(sanitized, isDirectory: true)
        
        guard !fileManager.fileExists(atPath: newPath.path) else {
            throw FileSystemError.projectAlreadyExists(sanitized)
        }
        
        try fileManager.moveItem(at: project.rootPath, to: newPath)
        
        logger.info("Renamed project \(project.name) -> \(sanitized)")
        return Project(
            id: project.id,
            name: sanitized,
            rootPath: newPath,
            template: project.template,
            createdAt: project.createdAt,
            lastModified: Date()
        )
    }
    
    /// List all projects
    func listProjects() throws -> [Project] {
        let contents = try fileManager.contentsOfDirectory(at: projectsDirectory, includingPropertiesForKeys: nil)
        return contents
            .filter { $0.hasDirectoryPath }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .enumerated()
            .map { index, url in
                Project(
                    id: UUID(),
                    name: url.lastPathComponent,
                    rootPath: url,
                    template: .empty,
                    createdAt: Date(),
                    lastModified: Date()
                )
            }
    }
    
    /// Duplicate a project
    func duplicateProject(_ project: Project) throws -> Project {
        let newName = project.name + "_copy"
        let newPath = projectsDirectory.appendingPathComponent(newName, isDirectory: true)
        try fileManager.copyItem(at: project.rootPath, to: newPath)
        
        return Project(
            id: UUID(),
            name: newName,
            rootPath: newPath,
            template: project.template,
            createdAt: Date(),
            lastModified: Date()
        )
    }
    
    // MARK: - File Operations
    
    /// Create a new file at the specified path within a project
    func createFile(in project: Project, relativePath: String, content: String = "") throws -> FileNode {
        let fileURL = project.rootPath.appendingPathComponent(relativePath)
        
        guard !fileManager.fileExists(atPath: fileURL.path) else {
            throw FileSystemError.fileAlreadyExists(relativePath)
        }
        
        try? fileManager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: fileURL, atomically: true, encoding: .utf8)
        
        logger.info("Created file: \(relativePath)")
        return FileNode(
            name: fileURL.lastPathComponent,
            path: relativePath,
            type: .file,
            size: Int64(content.utf8.count)
        )
    }
    
    /// Read file contents
    func readFile(in project: Project, relativePath: String) throws -> String {
        let fileURL = project.rootPath.appendingPathComponent(relativePath)
        guard fileManager.fileExists(atPath: fileURL.path) else {
            throw FileSystemError.fileNotFound(relativePath)
        }
        return try String(contentsOf: fileURL, encoding: .utf8)
    }
    
    /// Write file contents (overwrite)
    func writeFile(in project: Project, relativePath: String, content: String) throws {
        let fileURL = project.rootPath.appendingPathComponent(relativePath)
        guard fileManager.fileExists(atPath: fileURL.path) else {
            throw FileSystemError.fileNotFound(relativePath)
        }
        try content.write(to: fileURL, atomically: true, encoding: .utf8)
    }
    
    /// Delete a file
    func deleteFile(in project: Project, relativePath: String) throws {
        let fileURL = project.rootPath.appendingPathComponent(relativePath)
        try fileManager.removeItem(at: fileURL)
        logger.info("Deleted file: \(relativePath)")
    }
    
    /// Rename/move a file
    func moveFile(in project: Project, from oldPath: String, to newPath: String) throws {
        let source = project.rootPath.appendingPathComponent(oldPath)
        let dest = project.rootPath.appendingPathComponent(newPath)
        try? fileManager.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.moveItem(at: source, to: dest)
    }
    
    /// Create a directory
    func createDirectory(in project: Project, relativePath: String) throws {
        let dirURL = project.rootPath.appendingPathComponent(relativePath)
        try fileManager.createDirectory(at: dirURL, withIntermediateDirectories: true)
    }
    
    /// Delete a directory and its contents
    func deleteDirectory(in project: Project, relativePath: String) throws {
        let dirURL = project.rootPath.appendingPathComponent(relativePath)
        try fileManager.removeItem(at: dirURL)
    }
    
    // MARK: - File Tree
    
    /// Build the complete file tree for a project
    func buildFileTree(for project: Project) throws -> FileNode {
        let root = FileNode(
            name: project.name,
            path: "",
            type: .directory,
            children: []
        )
        
        guard let enumerator = fileManager.enumerator(
            at: project.rootPath,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return root
        }
        
        var nodeMap: [String: FileNode] = ["": root]
        
        for case let url as URL in enumerator {
            let relativePath = url.path.replacingOccurrences(of: project.rootPath.path + "/", with: "")
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { Int64($0) } ?? 0
            
            let node = FileNode(
                name: url.lastPathComponent,
                path: relativePath,
                type: isDir ? .directory : .file,
                size: size
            )
            
            nodeMap[relativePath] = node
            
            // Attach to parent
            let parentPath = relativePath.components(separatedBy: "/").dropLast().joined(separator: "/")
            if var parent = nodeMap[parentPath] {
                parent.children?.append(node)
                nodeMap[parentPath] = parent
            }
        }
        
        return nodeMap[""] ?? root
    }
    
    // MARK: - Import / Export
    
    /// Export project as .zip archive
    func exportAsZip(project: Project) async throws -> URL {
        let zipName = project.name + ".zip"
        let zipURL = projectsDirectory.appendingPathComponent(zipName)
        
        // Remove existing
        if fileManager.fileExists(atPath: zipURL.path) {
            try fileManager.removeItem(at: zipURL)
        }
        
        // Create zip using archive utility
        // In production, use ZIPFoundation or similar
        var coordinator = NSFileCoordinator()
        var error: NSError?
        
        coordinator.coordinate(readingItemAt: project.rootPath, options: .forUploading, error: &error) { zipFileURL in
            try? fileManager.moveItem(at: zipFileURL, to: zipURL)
        }
        
        logger.info("Exported project as zip: \(zipURL.lastPathComponent)")
        return zipURL
    }
    
    /// Share project via iOS Share Sheet
    func shareProject(_ project: Project, from viewController: UIViewController) async throws {
        let zipURL = try await exportAsZip(project: project)
        
        await MainActor.run {
            let activityVC = UIActivityViewController(activityItems: [zipURL], applicationActivities: nil)
            
            if let popover = activityVC.popoverPresentationController {
                popover.sourceView = viewController.view
                popover.sourceRect = CGRect(x: viewController.view.bounds.midX, y: viewController.view.bounds.midY, width: 0, height: 0)
                popover.permittedArrowDirections = []
            }
            
            viewController.present(activityVC, animated: true)
        }
    }
    
    /// Import a project from a .zip file
    func importProject(from zipURL: URL) throws -> Project {
        let projectName = zipURL.deletingPathExtension().lastPathComponent
        let extractDir = projectsDirectory.appendingPathComponent(projectName, isDirectory: true)
        
        // Extract zip (using archive utility)
        try fileManager.unzipItem(at: zipURL, to: extractDir)
        
        return Project(
            id: UUID(),
            name: projectName,
            rootPath: extractDir,
            template: .imported,
            createdAt: Date(),
            lastModified: Date()
        )
    }
    
    // MARK: - Automation
    
    /// Execute a shell-like command within the project directory
    func executeCommand(_ command: String, in project: Project) async throws -> CommandResult {
        let task = Process()
        task.currentDirectoryURL = project.rootPath
        task.executableURL = URL(fileURLWithPath: "/bin/bash")
        task.arguments = ["-c", command]
        
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        task.standardOutput = outputPipe
        task.standardError = errorPipe
        
        try task.run()
        task.waitUntilExit()
        
        let output = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let errorOutput = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        
        return CommandResult(
            exitCode: Int(task.terminationStatus),
            stdout: output,
            stderr: errorOutput,
            duration: 0 // Would track with CFAbsoluteTime
        )
    }
    
    // MARK: - Private Helpers
    
    private func sanitizeProjectName(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\?%*|\"<>")
        return name.components(separatedBy: invalid).joined(separator: "_")
    }
}

// MARK: - Models

/// A project in the workspace
struct Project: Identifiable, Codable, Sendable {
    let id: UUID
    var name: String
    var rootPath: URL
    var template: ProjectTemplate
    let createdAt: Date
    var lastModified: Date
    
    var displayName: String {
        name.replacingOccurrences(of: "_", with: " ")
            .capitalized
    }
}

/// File tree node for the sidebar
struct FileNode: Identifiable, Codable, Sendable {
    let id = UUID()
    var name: String
    var path: String
    var type: FileType
    var size: Int64 = 0
    var children: [FileNode]?
    
    enum FileType: String, Codable, Sendable {
        case file
        case directory
    }
    
    var isDirectory: Bool { type == .directory }
    var fileExtension: String? {
        isDirectory ? nil : URL(fileURLWithPath: name).pathExtension
    }
    
    var iconName: String {
        if isDirectory { return "folder.fill" }
        switch fileExtension?.lowercased() {
        case "swift": return "swift"
        case "py", "python": return "chevron.left.forwardslash.chevron.right"
        case "js", "ts": return "j.circle"
        case "html", "htm": return "globe"
        case "css": return "paintbrush"
        case "json": return "curlybraces"
        case "md", "markdown": return "doc.text"
        case "yml", "yaml": return "list.bullet.rectangle"
        case "png", "jpg", "jpeg", "gif", "webp": return "photo"
        case "pdf": return "doc.fill"
        case "zip", "tar", "gz": return "archivebox"
        case "gitignore": return "arrowtriangle.branch"
        default: return "doc"
        }
    }
    
    var languageIdentifier: String? {
        switch fileExtension?.lowercased() {
        case "swift": return "swift"
        case "py", "python": return "python"
        case "js": return "javascript"
        case "ts": return "typescript"
        case "html", "htm": return "html"
        case "css": return "css"
        case "json": return "json"
        case "md", "markdown": return "markdown"
        case "yml", "yaml": return "yaml"
        case "c": return "c"
        case "cpp", "cc", "cxx": return "cpp"
        case "rs": return "rust"
        case "go": return "go"
        case "rb": return "ruby"
        case "java": return "java"
        case "kt": return "kotlin"
        case "sh": return "shell"
        default: return fileExtension
        }
    }
}

/// Project template presets
enum ProjectTemplate: String, Codable, CaseIterable, Sendable {
    case empty = "Empty"
    case swift = "Swift"
    case python = "Python"
    case web = "Web"
    case imported = "Imported"
    
    var defaultDirectories: [String] {
        switch self {
        case .empty:
            return []
        case .swift:
            return ["Sources", "Tests", "Resources"]
        case .python:
            return ["src", "tests", "docs", "venv"]
        case .web:
            return ["src", "public", "dist"]
        case .imported:
            return []
        }
    }
    
    var defaultFiles: [(path: String, content: String)] {
        switch self {
        case .empty:
            return []
        case .swift:
            return [
                ("Sources/main.swift", "import Foundation\n\nprint(\"Hello, On-Device AI IDE!\")\n"),
                ("Package.swift", "// swift-tools-version:5.9\nimport PackageDescription\n\nlet package = Package(\n    name: \"MyApp\"\n)\n"),
                ("README.md", "# MyApp\n\nA Swift project created with On-Device AI IDE.\n"),
                (".gitignore", ".DS_Store\n.build\n*.xcodeproj\n"),
            ]
        case .python:
            return [
                ("src/main.py", "#!/usr/bin/env python3\n\ndef main():\n    print('Hello, On-Device AI IDE!')\n\nif __name__ == '__main__':\n    main()\n"),
                ("requirements.txt", "# Dependencies\n"),
                ("README.md", "# My Python Project\n\nCreated with On-Device AI IDE.\n"),
                (".gitignore", "__pycache__/\n*.pyc\nvenv/\n"),
            ]
        case .web:
            return [
                ("src/index.html", "<!DOCTYPE html>\n<html>\n<head>\n    <title>My App</title>\n    <link rel=\"stylesheet\" href=\"style.css\">\n</head>\n<body>\n    <h1>Hello, On-Device AI IDE!</h1>\n    <script src=\"app.js\"></script>\n</body>\n</html>\n"),
                ("src/style.css", "body {\n    font-family: system-ui, sans-serif;\n    background: #1a1a1a;\n    color: #e0e0e0;\n}\n"),
                ("src/app.js", "console.log('Hello from On-Device AI IDE!');\n"),
                ("README.md", "# Web Project\n\nCreated with On-Device AI IDE.\n"),
            ]
        case .imported:
            return []
        }
    }
}

/// Command execution result
struct CommandResult: Sendable {
    let exitCode: Int
    let stdout: String
    let stderr: String
    let duration: TimeInterval
    
    var isSuccess: Bool { exitCode == 0 }
}

// MARK: - Errors

enum FileSystemError: Error, Sendable {
    case projectAlreadyExists(String)
    case projectNotFound(String)
    case fileAlreadyExists(String)
    case fileNotFound(String)
    case directoryNotFound(String)
    case invalidPath(String)
    case insufficientPermissions
    case storageFull
    case importFailed(String)
    
    var localizedDescription: String {
        switch self {
        case .projectAlreadyExists(let name): return "Project '\(name)' already exists"
        case .projectNotFound(let name): return "Project '\(name)' not found"
        case .fileAlreadyExists(let path): return "File '\(path)' already exists"
        case .fileNotFound(let path): return "File '\(path)' not found"
        case .directoryNotFound(let path): return "Directory '\(path)' not found"
        case .invalidPath(let path): return "Invalid path: '\(path)'"
        case .insufficientPermissions: return "Insufficient permissions"
        case .storageFull: return "Device storage is full"
        case .importFailed(let msg): return "Import failed: \(msg)"
        }
    }
}

// MARK: - FileManager Extension

extension FileManager {
    func unzipItem(at sourceURL: URL, to destinationURL: URL) throws {
        // In production, use ZIPFoundation
        // This is a placeholder that uses the system's `unzip` command
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-o", sourceURL.path, "-d", destinationURL.path]
        try process.run()
        process.waitUntilExit()
    }
}
