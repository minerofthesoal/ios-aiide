// MARK: - Local Git Service
// OnDeviceAIIDE/Services/Git/GitService.swift
//
// Local Git operations for workspace version control.
// Uses command-line git via Process for full compatibility.
// Supports: Init, Add, Commit, Branch, Checkout, Diff, Log, Status

import Foundation
import os.log

/// Provides Git version control operations for project workspaces
actor GitService {
    
    static let shared = GitService()
    
    private let logger = Logger(subsystem: "com.ondeviceaiide", category: "GitService")
    private let fileManager = FileManager.default
    
    /// Check if git is available
    private var isGitAvailable: Bool {
        get async {
            let result = await runGitCommand(["--version"], in: fileManager.temporaryDirectory)
            return result.exitCode == 0
        }
    }
    
    // MARK: - Repository Operations
    
    /// Initialize a new Git repository in the project directory
    func initRepository(project: Project) async throws -> GitRepository {
        guard await isGitAvailable else {
            throw GitError.gitNotAvailable
        }
        
        let gitDir = project.rootPath.appendingPathComponent(".git")
        guard !fileManager.fileExists(atPath: gitDir.path) else {
            throw GitError.alreadyInitialized
        }
        
        let result = await runGitCommand(["init"], in: project.rootPath)
        guard result.exitCode == 0 else {
            throw GitError.initFailed(result.stderr)
        }
        
        // Configure default user if not set
        _ = await runGitCommand(["config", "user.email", "developer@ondevice.local"], in: project.rootPath)
        _ = await runGitCommand(["config", "user.name", "On-Device Developer"], in: project.rootPath)
        
        // Create initial .gitignore if template provides one
        let gitignorePath = project.rootPath.appendingPathComponent(".gitignore")
        if !fileManager.fileExists(atPath: gitignorePath.path) {
            let defaultIgnore = createDefaultGitignore(for: project)
            try? defaultIgnore.write(to: gitignorePath, atomically: true, encoding: .utf8)
        }
        
        logger.info("Initialized Git repository for \(project.name)")
        
        return GitRepository(
            project: project,
            isInitialized: true,
            currentBranch: "main",
            branches: ["main"],
            commitCount: 0
        )
    }
    
    /// Check if a project has a Git repository
    func isRepositoryInitialized(project: Project) async -> Bool {
        let gitDir = project.rootPath.appendingPathComponent(".git")
        return fileManager.fileExists(atPath: gitDir.path)
    }
    
    /// Get repository info
    func getRepositoryInfo(project: Project) async throws -> GitRepository {
        guard try await isRepositoryInitialized(project: project) else {
            return GitRepository(project: project, isInitialized: false, currentBranch: "", branches: [], commitCount: 0)
        }
        
        let branchResult = await runGitCommand(["branch", "--show-current"], in: project.rootPath)
        let currentBranch = branchResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        
        let branchesResult = await runGitCommand(["branch", "-a", "--format=%(refname:short)"], in: project.rootPath)
        let branches = branchesResult.stdout
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        
        let countResult = await runGitCommand(["rev-list", "--count", "HEAD"], in: project.rootPath)
        let commitCount = Int(countResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        
        return GitRepository(
            project: project,
            isInitialized: true,
            currentBranch: currentBranch,
            branches: branches.isEmpty ? ["main"] : branches,
            commitCount: commitCount
        )
    }
    
    // MARK: - Staging & Commit
    
    /// Get working directory status
    func status(project: Project) async throws -> GitStatus {
        guard try await isRepositoryInitialized(project: project) else {
            throw GitError.notInitialized
        }
        
        let result = await runGitCommand(
            ["status", "--porcelain=v1", "-uall"],
            in: project.rootPath
        )
        
        var staged: [GitFileStatus] = []
        var unstaged: [GitFileStatus] = []
        var untracked: [String] = []
        
        for line in result.stdout.split(separator: "\n") {
            let line = String(line)
            guard line.count >= 3 else { continue }
            
            let indexStatus = line.prefix(1)
            let worktreeStatus = line.dropFirst().prefix(1)
            let filePath = String(line.dropFirst(3))
            
            let status = GitFileStatus(
                path: filePath,
                indexStatus: String(indexStatus),
                worktreeStatus: String(worktreeStatus)
            )
            
            if indexStatus != " " && indexStatus != "?" {
                staged.append(status)
            }
            if worktreeStatus != " " {
                unstaged.append(status)
            }
            if indexStatus == "?" {
                untracked.append(filePath)
            }
        }
        
        return GitStatus(
            branch: try await getRepositoryInfo(project: project).currentBranch,
            staged: staged,
            unstaged: unstaged,
            untracked: untracked,
            isClean: staged.isEmpty && unstaged.isEmpty && untracked.isEmpty
        )
    }
    
    /// Stage files for commit
    func add(project: Project, paths: [String]) async throws {
        guard try await isRepositoryInitialized(project: project) else {
            throw GitError.notInitialized
        }
        
        var args = ["add"]
        args.append(contentsOf: paths)
        
        let result = await runGitCommand(args, in: project.rootPath)
        guard result.exitCode == 0 else {
            throw GitError.addFailed(result.stderr)
        }
    }
    
    /// Stage all changes
    func addAll(project: Project) async throws {
        try await add(project: project, paths: ["."])
    }
    
    /// Unstage files
    func reset(project: Project, paths: [String]) async throws {
        guard try await isRepositoryInitialized(project: project) else {
            throw GitError.notInitialized
        }
        
        var args = ["reset", "HEAD"]
        args.append(contentsOf: paths)
        
        let result = await runGitCommand(args, in: project.rootPath)
        guard result.exitCode == 0 else {
            throw GitError.resetFailed(result.stderr)
        }
    }
    
    /// Create a commit
    func commit(project: Project, message: String, author: String? = nil) async throws -> GitCommit {
        guard try await isRepositoryInitialized(project: project) else {
            throw GitError.notInitialized
        }
        
        // Check if there's anything to commit
        let status = try await status(project: project)
        guard !status.staged.isEmpty else {
            throw GitError.nothingToCommit
        }
        
        var args = ["commit", "-m", message]
        if let author = author {
            args.append("--author=\(author)")
        }
        
        let result = await runGitCommand(args, in: project.rootPath)
        guard result.exitCode == 0 else {
            throw GitError.commitFailed(result.stderr)
        }
        
        // Parse commit hash from output
        let hash = result.stdout
            .components(separatedBy: " ")
            .first { $0.count == 40 } ?? "unknown"
        
        let commit = GitCommit(
            hash: hash,
            shortHash: String(hash.prefix(7)),
            message: message,
            author: author ?? "On-Device Developer",
            date: Date(),
            filesChanged: status.staged.count
        )
        
        logger.info("Created commit \(commit.shortHash): \(message)")
        return commit
    }
    
    // MARK: - Branch Operations
    
    /// List all branches
    func listBranches(project: Project) async throws -> [GitBranch] {
        guard try await isRepositoryInitialized(project: project) else {
            throw GitError.notInitialized
        }
        
        let result = await runGitCommand(
            ["branch", "-a", "-v", "--format=%(refname:short)|%(objectname:short)|%(subject)"],
            in: project.rootPath
        )
        
        let currentResult = await runGitCommand(["branch", "--show-current"], in: project.rootPath)
        let current = currentResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        
        return result.stdout
            .split(separator: "\n")
            .compactMap { line -> GitBranch? in
                let parts = line.split(separator: "|", maxSplits: 2).map(String.init)
                guard parts.count >= 2 else { return nil }
                return GitBranch(
                    name: parts[0],
                    commitHash: parts[1],
                    lastCommitMessage: parts.count > 2 ? parts[2] : "",
                    isCurrent: parts[0] == current
                )
            }
    }
    
    /// Create a new branch
    func createBranch(project: Project, name: String, from commit: String? = nil) async throws {
        guard try await isRepositoryInitialized(project: project) else {
            throw GitError.notInitialized
        }
        
        var args = ["branch", name]
        if let commit = commit {
            args.append(commit)
        }
        
        let result = await runGitCommand(args, in: project.rootPath)
        guard result.exitCode == 0 else {
            throw GitError.branchFailed(result.stderr)
        }
        
        logger.info("Created branch: \(name)")
    }
    
    /// Checkout a branch or commit
    func checkout(project: Project, target: String) async throws {
        guard try await isRepositoryInitialized(project: project) else {
            throw GitError.notInitialized
        }
        
        let result = await runGitCommand(["checkout", target], in: project.rootPath)
        guard result.exitCode == 0 else {
            throw GitError.checkoutFailed(result.stderr)
        }
        
        logger.info("Checked out: \(target)")
    }
    
    /// Delete a branch
    func deleteBranch(project: Project, name: String, force: Bool = false) async throws {
        guard try await isRepositoryInitialized(project: project) else {
            throw GitError.notInitialized
        }
        
        var args = ["branch", "-d"]
        if force { args = ["branch", "-D"] }
        args.append(name)
        
        let result = await runGitCommand(args, in: project.rootPath)
        guard result.exitCode == 0 else {
            throw GitError.branchDeleteFailed(result.stderr)
        }
    }
    
    // MARK: - Log & History
    
    /// Get commit history
    func log(project: Project, maxCount: Int = 50) async throws -> [GitCommit] {
        guard try await isRepositoryInitialized(project: project) else {
            throw GitError.notInitialized
        }
        
        let format = "%H|%h|%s|%an|%ad"
        let result = await runGitCommand(
            ["log", "-\(maxCount)", "--pretty=format:\(format)", "--date=iso"],
            in: project.rootPath
        )
        
        let formatter = ISO8601DateFormatter()
        
        return result.stdout
            .split(separator: "\n")
            .compactMap { line -> GitCommit? in
                let parts = line.split(separator: "|", maxSplits: 4).map(String.init)
                guard parts.count >= 4 else { return nil }
                
                return GitCommit(
                    hash: parts[0],
                    shortHash: parts[1],
                    message: parts[2],
                    author: parts[3],
                    date: formatter.date(from: parts.count > 4 ? parts[4] : "") ?? Date(),
                    filesChanged: 0
                )
            }
    }
    
    // MARK: - Diff
    
    /// Get diff for staged changes
    func diffStaged(project: Project) async throws -> String {
        guard try await isRepositoryInitialized(project: project) else {
            throw GitError.notInitialized
        }
        
        let result = await runGitCommand(["diff", "--cached", "--no-color"], in: project.rootPath)
        return result.stdout
    }
    
    /// Get diff for unstaged changes
    func diffUnstaged(project: Project) async throws -> String {
        guard try await isRepositoryInitialized(project: project) else {
            throw GitError.notInitialized
        }
        
        let result = await runGitCommand(["diff", "--no-color"], in: project.rootPath)
        return result.stdout
    }
    
    /// Get diff for a specific file
    func diffFile(project: Project, path: String, staged: Bool = false) async throws -> String {
        guard try await isRepositoryInitialized(project: project) else {
            throw GitError.notInitialized
        }
        
        var args = ["diff", "--no-color"]
        if staged { args.append("--cached") }
        args.append("--")
        args.append(path)
        
        let result = await runGitCommand(args, in: project.rootPath)
        return result.stdout
    }
    
    // MARK: - Private Helpers
    
    private func runGitCommand(_ args: [String], in directory: URL) async -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        process.currentDirectoryURL = directory
        
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return CommandResult(exitCode: -1, stdout: "", stderr: error.localizedDescription, duration: 0)
        }
        
        let stdout = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        
        return CommandResult(
            exitCode: Int(process.terminationStatus),
            stdout: stdout,
            stderr: stderr,
            duration: 0
        )
    }
    
    private func createDefaultGitignore(for project: Project) -> String {
        var ignore = """
        .DS_Store
        .git/
        Thumbs.db
        *.swp
        *.swo
        *~
        .env
        .env.local
        """
        
        switch project.template {
        case .swift:
            ignore += "\n.build/\n*.xcodeproj/\nDerivedData/\n.swiftpm/\n"
        case .python:
            ignore += "\n__pycache__/\n*.pyc\nvenv/\n.venv/\ndist/\n*.egg-info/\n.pytest_cache/\n"
        case .web:
            ignore += "\nnode_modules/\ndist/\nbuild/\n*.log\n"
        default:
            break
        }
        
        return ignore
    }
}

// MARK: - Models

/// Git repository metadata
struct GitRepository: Sendable {
    let project: Project
    let isInitialized: Bool
    let currentBranch: String
    let branches: [String]
    let commitCount: Int
}

/// Git branch info
struct GitBranch: Identifiable, Sendable {
    let id = UUID()
    let name: String
    let commitHash: String
    let lastCommitMessage: String
    let isCurrent: Bool
}

/// Git commit
struct GitCommit: Identifiable, Sendable {
    let id = UUID()
    let hash: String
    let shortHash: String
    let message: String
    let author: String
    let date: Date
    let filesChanged: Int
    
    var formattedDate: String {
        let formatter = RelativeDateTimeFormatter()
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

/// Working directory status
struct GitStatus: Sendable {
    let branch: String
    let staged: [GitFileStatus]
    let unstaged: [GitFileStatus]
    let untracked: [String]
    let isClean: Bool
    
    var hasChanges: Bool {
        !staged.isEmpty || !unstaged.isEmpty || !untracked.isEmpty
    }
}

/// Individual file status
struct GitFileStatus: Sendable {
    let path: String
    let indexStatus: String
    let worktreeStatus: String
    
    var changeType: ChangeType {
        switch (indexStatus, worktreeStatus) {
        case ("A", _), ("?", _): return .added
        case ("M", _), (_, "M"): return .modified
        case ("D", _), (_, "D"): return .deleted
        case ("R", _): return .renamed
        default: return .modified
        }
    }
    
    var isStaged: Bool {
        indexStatus != " " && indexStatus != "?"
    }
    
    var icon: String {
        switch changeType {
        case .added: return "plus.circle.fill"
        case .modified: return "pencil.circle.fill"
        case .deleted: return "minus.circle.fill"
        case .renamed: return "arrow.right.circle.fill"
        }
    }
    
    var color: String {
        switch changeType {
        case .added: return "2D6B2D"
        case .modified: return "8B6914"
        case .deleted: return "8B2020"
        case .renamed: return "1E4A6B"
        }
    }
    
    enum ChangeType {
        case added, modified, deleted, renamed
    }
}

// MARK: - Errors

enum GitError: Error, Sendable {
    case gitNotAvailable
    case alreadyInitialized
    case notInitialized
    case initFailed(String)
    case addFailed(String)
    case resetFailed(String)
    case commitFailed(String)
    case nothingToCommit
    case branchFailed(String)
    case checkoutFailed(String)
    case branchDeleteFailed(String)
    case mergeConflict(String)
    
    var localizedDescription: String {
        switch self {
        case .gitNotAvailable: return "Git is not available on this device"
        case .alreadyInitialized: return "Git repository already initialized"
        case .notInitialized: return "Git repository not initialized"
        case .initFailed(let msg): return "Init failed: \(msg)"
        case .addFailed(let msg): return "Add failed: \(msg)"
        case .resetFailed(let msg): return "Reset failed: \(msg)"
        case .commitFailed(let msg): return "Commit failed: \(msg)"
        case .nothingToCommit: return "No changes to commit"
        case .branchFailed(let msg): return "Branch operation failed: \(msg)"
        case .checkoutFailed(let msg): return "Checkout failed: \(msg)"
        case .branchDeleteFailed(let msg): return "Branch deletion failed: \(msg)"
        case .mergeConflict(let msg): return "Merge conflict: \(msg)"
        }
    }
}
