// MARK: - AI Model Entity
// OnDeviceAIIDE/Models/AIModel.swift

import Foundation
import CoreData

/// Represents a downloaded or configured AI model in the system
@objc(AIModelEntity)
public class AIModelEntity: NSManagedObject {
    @NSManaged public var id: UUID
    @NSManaged public var modelID: String          // Hugging Face model ID, e.g., "microsoft/Phi-3-mini-4k-instruct"
    @NSManaged public var name: String             // Display name
    @NSManaged public var formatRaw: String        // ModelFormat raw value
    @NSManaged public var localPath: String?       // Local filesystem path
    @NSManaged public var quantizationRaw: String? // QuantizationLevel raw value
    @NSManaged public var fileSize: Int64          // Size in bytes
    @NSManaged public var isDownloaded: Bool
    @NSManaged public var downloadProgress: Double
    @NSManaged public var isDefault: Bool
    @NSManaged public var contextLength: Int32
    @NSManaged public var supportsVision: Bool
    @NSManaged public var supportsText: Bool
    @NSManaged public var accelerationPrefRaw: String
    @NSManaged public var customRepoURL: String?    // Direct HF repo URL override
    @NSManaged public var dateAdded: Date
    @NSManaged public var lastUsed: Date?
    @NSManaged public var parameters: String?       // e.g., "3B", "7B", "13B"
    
    public override func awakeFromInsert() {
        super.awakeFromInsert()
        id = UUID()
        dateAdded = Date()
        isDownloaded = false
        downloadProgress = 0.0
        isDefault = false
        supportsText = true
        supportsVision = false
        contextLength = 4096
        accelerationPrefRaw = AccelerationPreference.auto.rawValue
    }
}

extension AIModelEntity {
    @nonobjc public class func fetchRequest() -> NSFetchRequest<AIModelEntity> {
        return NSFetchRequest<AIModelEntity>(entityName: "AIModelEntity")
    }
    
    var format: ModelFormat {
        get { ModelFormat(rawValue: formatRaw) ?? .gguf }
        set { formatRaw = newValue.rawValue }
    }
    
    var quantization: QuantizationLevel? {
        get { quantizationRaw.flatMap { QuantizationLevel(rawValue: $0) } }
        set { quantizationRaw = newValue?.rawValue }
    }
    
    var accelerationPreference: AccelerationPreference {
        get { AccelerationPreference(rawValue: accelerationPrefRaw) ?? .auto }
        set { accelerationPrefRaw = newValue.rawValue }
    }
    
    var inferenceEngine: InferenceEngineType {
        format.preferredInferenceEngine
    }
    
    /// Whether this model can run on-device
    var isOnDeviceCapable: Bool {
        format != .coreml || localPath != nil
    }
    
    /// Formatted file size string
    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
    }
    
    /// Full Hugging Face URL for this model
    var huggingFaceURL: URL? {
        if let custom = customRepoURL {
            return URL(string: custom)
        }
        return URL(string: "https://huggingface.co/\(modelID)")
    }
    
    /// Files API endpoint for this model
    var filesAPIURL: URL? {
        URL(string: "https://huggingface.co/api/models/\(modelID)/tree/main")
    }
}

// MARK: - Swift Model (non-CoreData)

/// Lightweight Swift struct for model data transfer and UI binding
struct AIModelDTO: Identifiable, Codable, Sendable {
    let id: UUID
    var modelID: String
    var name: String
    var format: ModelFormat
    var localPath: String?
    var quantization: QuantizationLevel?
    var fileSize: Int64
    var isDownloaded: Bool
    var downloadProgress: Double
    var isDefault: Bool
    var contextLength: Int
    var supportsVision: Bool
    var supportsText: Bool
    var accelerationPreference: AccelerationPreference
    var customRepoURL: String?
    var dateAdded: Date
    var lastUsed: Date?
    var parameters: String?
    
    init(from entity: AIModelEntity) {
        self.id = entity.id
        self.modelID = entity.modelID
        self.name = entity.name
        self.format = entity.format
        self.localPath = entity.localPath
        self.quantization = entity.quantization
        self.fileSize = entity.fileSize
        self.isDownloaded = entity.isDownloaded
        self.downloadProgress = entity.downloadProgress
        self.isDefault = entity.isDefault
        self.contextLength = Int(entity.contextLength)
        self.supportsVision = entity.supportsVision
        self.supportsText = entity.supportsText
        self.accelerationPreference = entity.accelerationPreference
        self.customRepoURL = entity.customRepoURL
        self.dateAdded = entity.dateAdded
        self.lastUsed = entity.lastUsed
        self.parameters = entity.parameters
    }
    
    init(id: UUID = UUID(),
         modelID: String,
         name: String,
         format: ModelFormat = .gguf,
         localPath: String? = nil,
         quantization: QuantizationLevel? = nil,
         fileSize: Int64 = 0,
         isDownloaded: Bool = false,
         downloadProgress: Double = 0,
         isDefault: Bool = false,
         contextLength: Int = 4096,
         supportsVision: Bool = false,
         supportsText: Bool = true,
         accelerationPreference: AccelerationPreference = .auto,
         customRepoURL: String? = nil,
         dateAdded: Date = Date(),
         lastUsed: Date? = nil,
         parameters: String? = nil) {
        self.id = id
        self.modelID = modelID
        self.name = name
        self.format = format
        self.localPath = localPath
        self.quantization = quantization
        self.fileSize = fileSize
        self.isDownloaded = isDownloaded
        self.downloadProgress = downloadProgress
        self.isDefault = isDefault
        self.contextLength = contextLength
        self.supportsVision = supportsVision
        self.supportsText = supportsText
        self.accelerationPreference = accelerationPreference
        self.customRepoURL = customRepoURL
        self.dateAdded = dateAdded
        self.lastUsed = lastUsed
        self.parameters = parameters
    }
}

// MARK: - Model Download States

enum ModelDownloadState: Equatable, Sendable {
    case idle
    case resolving          // Fetching file list from HuggingFace
    case downloading(progress: Double, bytesDownloaded: Int64, totalBytes: Int64)
    case verifying          // Checksum verification
    case completed
    case failed(ModelDownloadError)
    case cancelled
    
    var isActive: Bool {
        switch self {
        case .downloading, .resolving, .verifying:
            return true
        default:
            return false
        }
    }
    
    var progress: Double {
        switch self {
        case .downloading(let progress, _, _):
            return progress
        default:
            return 0
        }
    }
}

enum ModelDownloadError: Error, Equatable, Sendable {
    case invalidURL
    case networkError(String)
    case insufficientStorage(required: Int64, available: Int64)
    case checksumMismatch
    case invalidModelFormat
    case modelNotFound
    case downloadCancelled
    case fileSystemError(String)
    case concurrentDownloadLimitReached
    
    var localizedDescription: String {
        switch self {
        case .invalidURL:
            return "Invalid HuggingFace repository URL"
        case .networkError(let message):
            return "Network error: \(message)"
        case .insufficientStorage(let required, let available):
            return "Insufficient storage. Required: \(ByteCountFormatter.string(fromByteCount: required, countStyle: .file)), Available: \(ByteCountFormatter.string(fromByteCount: available, countStyle: .file))"
        case .checksumMismatch:
            return "Downloaded file checksum does not match expected value"
        case .invalidModelFormat:
            return "The model format is not supported"
        case .modelNotFound:
            return "Model not found in the HuggingFace repository"
        case .downloadCancelled:
            return "Download was cancelled"
        case .fileSystemError(let message):
            return "File system error: \(message)"
        case .concurrentDownloadLimitReached:
            return "Maximum concurrent download limit reached"
        }
    }
}

// MARK: - Hugging Face API Models

/// Response from Hugging Face models API
struct HFModelInfo: Decodable, Sendable {
    let id: String
    let modelId: String
    let tags: [String]
    let pipelineTag: String?
    let downloads: Int?
    let likes: Int?
    let lastModified: String?
    
    var supportsVision: Bool {
        tags.contains("vision") || modelId.lowercased().contains("vision")
    }
    
    var supportsTextGeneration: Bool {
        pipelineTag == "text-generation" || tags.contains("text-generation")
    }
}

/// File entry in HF repo file tree
struct HFFileEntry: Decodable, Sendable {
    let type: String
    let oid: String
    let size: Int64
    let path: String
    let lfs: HFLfsInfo?
    
    var isLFS: Bool { lfs != nil }
    var isDirectory: Bool { type == "directory" }
    var fileExtension: String? {
        URL(fileURLWithPath: path).pathExtension.isEmpty ? nil : URL(fileURLWithPath: path).pathExtension
    }
    
    func matchesFormat(_ format: ModelFormat) -> Bool {
        guard let ext = fileExtension else { return false }
        return format.fileExtensions.contains(ext.lowercased())
    }
}

struct HFLfsInfo: Decodable, Sendable {
    let oid: String
    let size: Int64
    let pointerSize: Int
    let sha256: String?
}

/// Download task metadata
struct ModelDownloadTask: Identifiable, Sendable {
    let id: UUID
    let modelID: String
    let targetFiles: [HFFileEntry]
    let destinationDirectory: URL
    let format: ModelFormat
    let startDate: Date
    var completedFiles: Int
    var totalBytesDownloaded: Int64
    var totalBytesExpected: Int64
    var state: ModelDownloadState
    
    var overallProgress: Double {
        guard totalBytesExpected > 0 else { return 0 }
        return min(Double(totalBytesDownloaded) / Double(totalBytesExpected), 1.0)
    }
    
    init(modelID: String, targetFiles: [HFFileEntry], destination: URL, format: ModelFormat) {
        self.id = UUID()
        self.modelID = modelID
        self.targetFiles = targetFiles
        self.destinationDirectory = destination
        self.format = format
        self.startDate = Date()
        self.completedFiles = 0
        self.totalBytesDownloaded = 0
        self.totalBytesExpected = targetFiles.reduce(0) { $0 + ($1.lfs?.size ?? $1.size) }
        self.state = .idle
    }
}
