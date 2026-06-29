// MARK: - Hugging Face Download Manager
// OnDeviceAIIDE/Services/ML/HuggingFaceDownloadManager.swift
//
// Secure, cached model downloading from Hugging Face Hub with:
// - Background download support with progress tracking
// - Checksum verification (SHA-256)
// - Resume capability for interrupted downloads
// - Concurrent download limiting
// - LFS file handling

import Foundation
import CryptoKit
import os.log

/// Manages downloading AI models from Hugging Face Hub
/// Handles both regular files and Git LFS files with resume support
actor HuggingFaceDownloadManager {
    
    // MARK: - Singleton & Init
    
    static let shared = HuggingFaceDownloadManager()
    
    private init() {
        self.urlSession = URLSession(configuration: Self.makeSessionConfig(),
                                      delegate: sessionDelegate,
                                      delegateQueue: delegateQueue)
        self.sessionDelegate.manager = self
        setupCacheDirectory()
    }
    
    // MARK: - Configuration
    
    /// Maximum concurrent file downloads
    private let maxConcurrentDownloads = 3
    /// Retry attempts for failed downloads
    private let maxRetryAttempts = 3
    /// Base delay between retries (exponential backoff)
    private let baseRetryDelay: TimeInterval = 2.0
    /// Chunk size for streaming downloads (8MB)
    private let downloadChunkSize = 8 * 1024 * 1024
    
    // MARK: - Dependencies
    
    private let logger = Logger(subsystem: "com.ondeviceaiide", category: "HFDownloadManager")
    private let fileManager = FileManager.default
    private let delegateQueue = OperationQueue()
    private let urlSession: URLSession
    private let sessionDelegate = DownloadSessionDelegate()
    
    /// Active download tasks keyed by task ID
    private var activeTasks: [UUID: ModelDownloadTask] = [:]
    /// URLSession tasks mapped to our task IDs
    private var sessionTaskMap: [Int: UUID] = [:]
    /// Track completed byte ranges for resume support: [taskID: [filePath: Set<Ranges>]]
    private var resumeData: [UUID: [String: ResumeInfo]] = [:]
    /// Current download count for concurrency limiting
    private var activeDownloadCount = 0
    /// Pending downloads queue
    private var pendingQueue: [(UUID, HFFileEntry)] = []
    
    // MARK: - Cache / Storage
    
    /// Root directory for all downloaded models
    private(set) var modelsDirectory: URL!
    /// Temporary download directory for in-progress files
    private var tempDirectory: URL!
    /// Metadata store path
    private var metadataURL: URL!
    
    private static func makeSessionConfig() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 300
        config.timeoutIntervalForResource = 3600 * 24 // 24 hours for large models
        config.allowsCellularAccess = true
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        config.httpAdditionalHeaders = [
            "User-Agent": "OnDeviceAIIDE/1.0 (iOS; Swift)"
        ]
        return config
    }
    
    private func setupCacheDirectory() {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        modelsDirectory = appSupport.appendingPathComponent("Models", isDirectory: true)
        tempDirectory = appSupport.appendingPathComponent("Downloads", isDirectory: true)
        metadataURL = appSupport.appendingPathComponent("download-metadata.json")
        
        try? fileManager.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }
    
    // MARK: - Public API
    
    /// Resolve and list available files in a Hugging Face repository
    /// - Parameters:
    ///   - modelID: HuggingFace model ID (e.g., "microsoft/Phi-3-mini-4k-instruct")
    ///   - repoURL: Optional direct repository URL override
    /// - Returns: Array of file entries in the repository
    func resolveRepository(
        modelID: String,
        repoURL: String? = nil
    ) async throws -> [HFFileEntry] {
        logger.info("Resolving repository for model: \(modelID)")
        
        let url: URL
        if let repoURL = repoURL {
            guard let parsed = URL(string: repoURL) else {
                throw ModelDownloadError.invalidURL
            }
            url = parsed
        } else {
            guard let parsed = URL(string: "https://huggingface.co/api/models/\(modelID)/tree/main") else {
                throw ModelDownloadError.invalidURL
            }
            url = parsed
        }
        
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        
        let (data, response) = try await urlSession.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ModelDownloadError.networkError("Invalid response type")
        }
        
        guard httpResponse.statusCode == 200 else {
            if httpResponse.statusCode == 404 {
                throw ModelDownloadError.modelNotFound
            }
            throw ModelDownloadError.networkError("HTTP \(httpResponse.statusCode)")
        }
        
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let files = try decoder.decode([HFFileEntry].self, from: data)
        
        logger.info("Resolved \(files.count) files for model \(modelID)")
        return files.filter { !$0.isDirectory }
    }
    
    /// Resolve repository and auto-detect model format
    func resolveWithFormat(
        modelID: String,
        repoURL: String? = nil
    ) async throws -> (files: [HFFileEntry], detectedFormat: ModelFormat) {
        let files = try await resolveRepository(modelID: modelID, repoURL: repoURL)
        
        // Auto-detect format based on file extensions
        let format = detectFormat(from: files)
        let targetFiles = files.filter { $0.matchesFormat(format) || isMetadataFile($0) }
        
        logger.info("Auto-detected format: \(format.rawValue) with \(targetFiles.count) target files")
        return (targetFiles, format)
    }
    
    /// Start downloading a model from Hugging Face
    /// - Parameters:
    ///   - modelID: HuggingFace model ID
    ///   - format: Target model format
    ///   - files: Specific files to download (nil = auto-resolve)
    ///   - quantization: Optional quantization filter for GGUF
    /// - Returns: Download task ID for tracking
    func downloadModel(
        modelID: String,
        format: ModelFormat,
        files: [HFFileEntry]? = nil,
        quantization: QuantizationLevel? = nil
    ) async throws -> UUID {
        // Resolve files if not provided
        let targetFiles: [HFFileEntry]
        if let files = files {
            targetFiles = files
        } else {
            let (resolved, detectedFormat) = try await resolveWithFormat(modelID: modelID)
            targetFiles = detectedFormat == format ? resolved : resolved.filter { $0.matchesFormat(format) }
        }
        
        guard !targetFiles.isEmpty else {
            throw ModelDownloadError.invalidModelFormat
        }
        
        // Filter by quantization for GGUF
        let filteredFiles: [HFFileEntry]
        if format == .gguf, let quant = quantization {
            filteredFiles = targetFiles.filter {
                $0.path.contains(quant.rawValue) || isMetadataFile($0)
            }
        } else {
            filteredFiles = targetFiles
        }
        
        // Check storage
        let totalSize = filteredFiles.reduce(0) { $0 + ($1.lfs?.size ?? $1.size) }
        try await verifyAvailableStorage(requiredBytes: totalSize)
        
        // Create destination directory
        let modelDir = modelsDirectory.appendingPathComponent(modelID.replacingOccurrences(of: "/", with: "_"), isDirectory: true)
        try? fileManager.createDirectory(at: modelDir, withIntermediateDirectories: true)
        
        // Create download task
        let task = ModelDownloadTask(
            modelID: modelID,
            targetFiles: filteredFiles,
            destination: modelDir,
            format: format
        )
        
        activeTasks[task.id] = task
        
        // Start downloading
        Task {
            await processDownloadQueue(taskID: task.id)
        }
        
        logger.info("Started download task \(task.id) for \(modelID) (\(filteredFiles.count) files)")
        return task.id
    }
    
    /// Cancel an active download
    func cancelDownload(taskID: UUID) async {
        logger.info("Cancelling download: \(taskID)")
        
        // Cancel all URLSession tasks for this download
        urlSession.getAllTasks { [weak self] tasks in
            for task in tasks {
                if let id = self?.sessionTaskMap[task.taskIdentifier],
                   id == taskID {
                    task.cancel()
                }
            }
        }
        
        // Clean up temp files
        if let task = activeTasks[taskID] {
            let tempModelDir = tempDirectory.appendingPathComponent(task.id.uuidString)
            try? fileManager.removeItem(at: tempModelDir)
        }
        
        // Update state
        activeTasks[taskID]?.state = .cancelled
        activeTasks.removeValue(forKey: taskID)
        resumeData.removeValue(forKey: taskID)
    }
    
    /// Pause a download (preserves resume data)
    func pauseDownload(taskID: UUID) async {
        logger.info("Pausing download: \(taskID)")
        urlSession.getAllTasks { tasks in
            for task in tasks {
                if self.sessionTaskMap[task.taskIdentifier] == taskID {
                    task.suspend()
                }
            }
        }
    }
    
    /// Resume a paused download
    func resumeDownload(taskID: UUID) async {
        logger.info("Resuming download: \(taskID)")
        guard activeTasks[taskID] != nil else { return }
        Task {
            await processDownloadQueue(taskID: taskID)
        }
    }
    
    /// Get current state of a download task
    func state(for taskID: UUID) -> ModelDownloadState? {
        activeTasks[taskID]?.state
    }
    
    /// All active download tasks
    var activeDownloads: [ModelDownloadTask] {
        Array(activeTasks.values)
    }
    
    /// Verify downloaded model integrity
    func verifyDownloadedModel(taskID: UUID) async throws -> Bool {
        guard let task = activeTasks[taskID] else { return false }
        
        for file in task.targetFiles {
            let fileURL = task.destinationDirectory.appendingPathComponent(file.path)
            guard fileManager.fileExists(atPath: fileURL.path) else {
                logger.error("Missing file: \(file.path)")
                return false
            }
            
            // Verify checksum if available
            if let expectedSHA = file.lfs?.sha256 {
                let data = try Data(contentsOf: fileURL)
                let computedSHA = SHA256.hash(data: data).compactMap { String(format: "%02x", $0) }.joined()
                guard computedSHA.lowercased() == expectedSHA.lowercased() else {
                    logger.error("Checksum mismatch for \(file.path)")
                    return false
                }
            }
        }
        
        logger.info("Verification passed for task \(taskID)")
        return true
    }
    
    /// Clean up temporary download data
    func cleanupTempFiles(taskID: UUID) async {
        let tempModelDir = tempDirectory.appendingPathComponent(taskID.uuidString)
        try? fileManager.removeItem(at: tempModelDir)
        resumeData.removeValue(forKey: taskID)
    }
    
    /// Delete a downloaded model from local storage
    func deleteDownloadedModel(modelID: String) async throws {
        let modelDir = modelsDirectory.appendingPathComponent(modelID.replacingOccurrences(of: "/", with: "_"))
        guard fileManager.fileExists(atPath: modelDir.path) else {
            return
        }
        try fileManager.removeItem(at: modelDir)
        logger.info("Deleted model: \(modelID)")
    }
    
    /// Get the local URL for a downloaded model
    func localURL(for modelID: String) -> URL? {
        let modelDir = modelsDirectory.appendingPathComponent(modelID.replacingOccurrences(of: "/", with: "_"))
        guard fileManager.fileExists(atPath: modelDir.path) else { return nil }
        return modelDir
    }
    
    /// List all downloaded models on disk
    func listDownloadedModels() -> [(modelID: String, path: URL, size: Int64)] {
        var results: [(String, URL, Int64)] = []
        guard let contents = try? fileManager.contentsOfDirectory(at: modelsDirectory, includingPropertiesForKeys: nil) else {
            return results
        }
        for url in contents where url.hasDirectoryPath {
            let name = url.lastPathComponent.replacingOccurrences(of: "_", with: "/")
            let size = directorySize(url)
            results.append((name, url, size))
        }
        return results
    }
    
    // MARK: - Private Methods
    
    private func processDownloadQueue(taskID: UUID) async {
        guard var task = activeTasks[taskID] else { return }
        task.state = .resolving
        activeTasks[taskID] = task
        
        let tempModelDir = tempDirectory.appendingPathComponent(taskID.uuidString)
        try? fileManager.createDirectory(at: tempModelDir, withIntermediateDirectories: true)
        
        for file in task.targetFiles {
            // Check if cancelled
            guard activeTasks[taskID]?.state != .cancelled else { break }
            
            // Wait for concurrency slot
            while activeDownloadCount >= maxConcurrentDownloads {
                try? await Task.sleep(nanoseconds: 500_000_000) // 0.5s
            }
            
            activeDownloadCount += 1
            
            do {
                try await downloadFile(
                    file: file,
                    taskID: taskID,
                    tempDirectory: tempModelDir
                )
                
                // Move to final destination
                let tempFile = tempModelDir.appendingPathComponent(file.path)
                let destFile = task.destinationDirectory.appendingPathComponent(file.path)
                try? fileManager.createDirectory(at: destFile.deletingLastPathComponent(), withIntermediateDirectories: true)
                if fileManager.fileExists(atPath: destFile.path) {
                    try? fileManager.removeItem(at: destFile)
                }
                try fileManager.moveItem(at: tempFile, to: destFile)
                
                task.completedFiles += 1
                task.totalBytesDownloaded += (file.lfs?.size ?? file.size)
                task.state = .downloading(
                    progress: task.overallProgress,
                    bytesDownloaded: task.totalBytesDownloaded,
                    totalBytes: task.totalBytesExpected
                )
                activeTasks[taskID] = task
                
            } catch {
                logger.error("Failed to download \(file.path): \(error.localizedDescription)")
                if let downloadError = error as? ModelDownloadError {
                    task.state = .failed(downloadError)
                } else {
                    task.state = .failed(.networkError(error.localizedDescription))
                }
                activeTasks[taskID] = task
                activeDownloadCount -= 1
                return
            }
            
            activeDownloadCount -= 1
        }
        
        // Mark completed if not cancelled
        if var finalTask = activeTasks[taskID], finalTask.state != .cancelled {
            finalTask.state = .completed
            activeTasks[taskID] = finalTask
            logger.info("Download completed: \(taskID)")
            
            // Cleanup temp files
            try? fileManager.removeItem(at: tempModelDir)
        }
    }
    
    private func downloadFile(
        file: HFFileEntry,
        taskID: UUID,
        tempDirectory: URL,
        attempt: Int = 1
    ) async throws {
        let downloadURL = downloadURL(for: file, modelID: activeTasks[taskID]?.modelID ?? "")
        let tempFile = tempDirectory.appendingPathComponent(file.path)
        
        try? fileManager.createDirectory(at: tempFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        
        // Check for existing partial download
        let resumeOffset: Int64
        if let attrs = try? fileManager.attributesOfItem(atPath: tempFile.path),
           let existingSize = attrs[.size] as? Int64,
           existingSize > 0,
           existingSize < (file.lfs?.size ?? file.size) {
            resumeOffset = existingSize
            logger.debug("Resuming \(file.path) from byte \(resumeOffset)")
        } else {
            resumeOffset = 0
        }
        
        var request = URLRequest(url: downloadURL)
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        if resumeOffset > 0 {
            request.setValue("bytes=\(resumeOffset)-", forHTTPHeaderField: "Range")
        }
        
        let (asyncBytes, response) = try await urlSession.bytes(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              (200...206).contains(httpResponse.statusCode) else {
            throw ModelDownloadError.networkError("HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        
        // Stream to file
        let fileHandle: FileHandle
        if resumeOffset > 0, fileManager.fileExists(atPath: tempFile.path) {
            fileHandle = try FileHandle(forWritingTo: tempFile)
            try fileHandle.seekToEnd()
        } else {
            fileManager.createFile(atPath: tempFile.path, contents: nil)
            fileHandle = try FileHandle(forWritingTo: tempFile)
        }
        defer { try? fileHandle.close() }
        
        var bytesWritten = resumeOffset
        let totalExpected = file.lfs?.size ?? file.size
        
        for try await byte in asyncBytes {
            var data = Data()
            data.append(byte)
            try fileHandle.write(contentsOf: data)
            bytesWritten += 1
            
            // Update progress periodically (every 1MB)
            if bytesWritten % (1024 * 1024) == 0 {
                if var task = activeTasks[taskID] {
                    task.totalBytesDownloaded += 1024 * 1024
                    task.state = .downloading(
                        progress: task.overallProgress,
                        bytesDownloaded: task.totalBytesDownloaded,
                        totalBytes: task.totalBytesExpected
                    )
                    activeTasks[taskID] = task
                }
            }
        }
        
        // Verify file size
        let finalAttrs = try fileManager.attributesOfItem(atPath: tempFile.path)
        let finalSize = finalAttrs[.size] as? Int64 ?? 0
        
        guard finalSize == totalExpected else {
            if attempt < maxRetryAttempts {
                let delay = baseRetryDelay * pow(2.0, Double(attempt - 1))
                logger.warning("Size mismatch for \(file.path), retrying in \(delay)s...")
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                try await downloadFile(file: file, taskID: taskID, tempDirectory: tempDirectory, attempt: attempt + 1)
                return
            }
            throw ModelDownloadError.fileSystemError("Downloaded file size \(finalSize) does not match expected \(totalExpected)")
        }
    }
    
    private func downloadURL(for file: HFFileEntry, modelID: String) -> URL {
        // Use Hugging Face CDN for LFS files
        if file.isLFS {
            return URL(string: "https://huggingface.co/\(modelID)/resolve/main/\(file.path)")!
        }
        return URL(string: "https://huggingface.co/\(modelID)/resolve/main/\(file.path)")!
    }
    
    private func verifyAvailableStorage(requiredBytes: Int64) async throws {
        let fileURL = URL(fileURLWithPath: NSHomeDirectory())
        let values = try fileURL.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        if let available = values.volumeAvailableCapacityForImportantUsage, available < requiredBytes {
            throw ModelDownloadError.insufficientStorage(required: requiredBytes, available: available)
        }
    }
    
    private func detectFormat(from files: [HFFileEntry]) -> ModelFormat {
        for format in ModelFormat.allCases {
            if files.contains(where: { $0.matchesFormat(format) }) {
                return format
            }
        }
        // Default to GGUF if can't detect
        return .gguf
    }
    
    private func isMetadataFile(_ file: HFFileEntry) -> Bool {
        let metadataNames = ["config.json", "tokenizer.json", "tokenizer_config.json",
                            "generation_config.json", "README.md", ".gitattributes", "model.card.md"]
        return metadataNames.contains(file.path)
    }
    
    private func directorySize(_ url: URL) -> Int64 {
        var size: Int64 = 0
        guard let enumerator = fileManager.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else {
            return 0
        }
        for case let fileURL as URL in enumerator {
            if let attrs = try? fileManager.attributesOfItem(atPath: fileURL.path),
               let fileSize = attrs[.size] as? Int64 {
                size += fileSize
            }
        }
        return size
    }
    
    // MARK: - Resume Data Structures
    
    struct ResumeInfo: Codable {
        let filePath: String
        let bytesReceived: Int64
        let totalBytes: Int64
        let lastModified: Date
    }
}

// MARK: - URLSession Delegate

/// Handles download progress and task lifecycle events
private class DownloadSessionDelegate: NSObject, URLSessionTaskDelegate, URLSessionDataDelegate {
    weak var manager: HuggingFaceDownloadManager?
    
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        if let error = error {
            Task {
                await manager?.handleDownloadError(task: task, error: error)
            }
        }
    }
}

extension HuggingFaceDownloadManager {
    func handleDownloadError(task: URLSessionTask, error: Error) async {
        guard let taskID = sessionTaskMap[task.taskIdentifier] else { return }
        
        if let urlError = error as? URLError, urlError.code == .cancelled {
            activeTasks[taskID]?.state = .cancelled
        } else {
            activeTasks[taskID]?.state = .failed(.networkError(error.localizedDescription))
        }
    }
    
    func registerSessionTask(_ task: URLSessionTask, for downloadID: UUID) {
        sessionTaskMap[task.taskIdentifier] = downloadID
    }
}

// MARK: - Search & Discovery

extension HuggingFaceDownloadManager {
    
    /// Search Hugging Face Hub for models matching query
    func searchModels(
        query: String,
        filter: String? = nil,
        limit: Int = 20
    ) async throws -> [HFModelInfo] {
        var components = URLComponents(string: "https://huggingface.co/api/models")!
        components.queryItems = [
            URLQueryItem(name: "search", value: query),
            URLQueryItem(name: "limit", value: "\(limit)")
        ]
        if let filter = filter {
            components.queryItems?.append(URLQueryItem(name: "filter", value: filter))
        }
        
        let request = URLRequest(url: components.url!)
        let (data, response) = try await urlSession.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw ModelDownloadError.networkError("Search failed")
        }
        
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode([HFModelInfo].self, from: data)
    }
    
    /// Get trending/popular models suited for on-device use
    func getRecommendedModels() async throws -> [HFModelInfo] {
        // Query for small LLMs suited for mobile
        return try await searchModels(
            query: "",
            filter: "gguf,mlx,text-generation",
            limit: 50
        )
    }
}
