// MARK: - Model Configuration Store
// OnDeviceAIIDE/Services/ML/ModelConfigurationStore.swift
//
// Core Data-backed persistence layer for AI model configurations.
// Manages model metadata, inference parameters, and runtime configuration.
// Thread-safe with actor isolation for concurrent access.

import Foundation
import CoreData
import Combine
import os.log

/// Thread-safe store for AI model configurations backed by Core Data
actor ModelConfigurationStore {
    
    // MARK: - Singleton
    
    static let shared = ModelConfigurationStore()
    
    // MARK: - Properties
    
    private let logger = Logger(subsystem: "com.ondeviceaiide", category: "ModelConfigurationStore")
    private let persistence: CoreDataStack
    
    /// Published stream of model changes for UI observation
    nonisolated let modelChanges: AnyPublisher<ModelChangeEvent, Never>
    private let modelChangesSubject = PassthroughSubject<ModelChangeEvent, Never>()
    
    /// Currently selected (active) model ID
    private(set) var activeModelID: UUID? {
        didSet {
            if let id = activeModelID {
                modelChangesSubject.send(.activated(id))
            }
        }
    }
    
    /// Default inference parameters applied to new models
    private(set) var defaultParameters: InferenceParameters
    
    /// In-memory cache of model DTOs for fast access
    private var modelCache: [UUID: AIModelDTO] = [:]
    private var cacheInvalidated = true
    
    // MARK: - Init
    
    private init() {
        self.persistence = CoreDataStack.shared
        self.modelChanges = modelChangesSubject.eraseToAnyPublisher()
        self.defaultParameters = InferenceParameters.loadDefaults()
        
        // Load last active model
        Task {
            await loadLastActiveModel()
        }
    }
    
    // MARK: - CRUD Operations
    
    /// Create and persist a new model configuration
    func createModel(
        modelID: String,
        name: String,
        format: ModelFormat,
        quantization: QuantizationLevel? = nil,
        contextLength: Int = 4096,
        supportsVision: Bool = false,
        supportsText: Bool = true,
        accelerationPreference: AccelerationPreference = .auto,
        customRepoURL: String? = nil,
        parameters: String? = nil
    ) async throws -> AIModelDTO {
        
        // Check for duplicate modelID
        if let existing = try await fetchModel(byModelID: modelID) {
            logger.warning("Model with ID \(modelID) already exists, returning existing")
            return existing
        }
        
        let context = persistence.newBackgroundContext()
        
        let dto = try await context.perform {
            let entity = AIModelEntity(context: context)
            entity.modelID = modelID
            entity.name = name
            entity.format = format
            entity.quantization = quantization
            entity.contextLength = Int32(contextLength)
            entity.supportsVision = supportsVision
            entity.supportsText = supportsText
            entity.accelerationPreference = accelerationPreference
            entity.customRepoURL = customRepoURL
            entity.parameters = parameters
            entity.isDownloaded = false
            entity.downloadProgress = 0
            
            try context.save()
            
            return AIModelDTO(from: entity)
        }
        
        modelCache[dto.id] = dto
        modelChangesSubject.send(.created(dto.id))
        logger.info("Created model config: \(name) (\(modelID))")
        
        return dto
    }
    
    /// Create model configuration from a HuggingFace download
    func createModelFromDownload(
        modelID: String,
        format: ModelFormat,
        localPath: URL,
        files: [HFFileEntry],
        quantization: QuantizationLevel? = nil
    ) async throws -> AIModelDTO {
        let name = modelID.components(separatedBy: "/").last ?? modelID
        let totalSize = files.reduce(0) { $0 + ($1.lfs?.size ?? $1.size) }
        
        let contextLength = inferContextLength(from: modelID, files: files)
        let supportsVision = files.contains { $0.path.contains("vision") || modelID.lowercased().contains("vision") }
        let parameters = inferParameterCount(from: modelID, files: files)
        
        let dto = try await createModel(
            modelID: modelID,
            name: name,
            format: format,
            quantization: quantization,
            contextLength: contextLength,
            supportsVision: supportsVision,
            supportsText: true,
            accelerationPreference: format == .mlx ? .metalOnly : .auto,
            parameters: parameters
        )
        
        // Update with download-specific info
        try await updateModel(
            id: dto.id,
            updates: {
                $0.localPath = localPath.path
                $0.fileSize = totalSize
                $0.isDownloaded = true
                $0.downloadProgress = 1.0
            }
        )
        
        return dto
    }
    
    /// Fetch all model configurations
    func fetchAllModels() async throws -> [AIModelDTO] {
        if !cacheInvalidated, !modelCache.isEmpty {
            return Array(modelCache.values).sorted { $0.dateAdded > $1.dateAdded }
        }
        
        let context = persistence.newBackgroundContext()
        
        let models = try await context.perform {
            let request = AIModelEntity.fetchRequest()
            request.sortDescriptors = [NSSortDescriptor(key: "dateAdded", ascending: false)]
            let results = try context.fetch(request)
            return results.map { AIModelDTO(from: $0) }
        }
        
        // Update cache
        modelCache = Dictionary(uniqueKeysWithValues: models.map { ($0.id, $0) })
        cacheInvalidated = false
        
        return models
    }
    
    /// Fetch only downloaded models
    func fetchDownloadedModels() async throws -> [AIModelDTO] {
        let all = try await fetchAllModels()
        return all.filter { $0.isDownloaded }
    }
    
    /// Fetch model by UUID
    func fetchModel(byID id: UUID) async throws -> AIModelDTO? {
        if let cached = modelCache[id] {
            return cached
        }
        
        let context = persistence.newBackgroundContext()
        
        return try await context.perform {
            let request = AIModelEntity.fetchRequest()
            request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
            request.fetchLimit = 1
            let results = try context.fetch(request)
            return results.first.map { AIModelDTO(from: $0) }
        }
    }
    
    /// Fetch model by HuggingFace modelID string
    func fetchModel(byModelID modelID: String) async throws -> AIModelDTO? {
        let context = persistence.newBackgroundContext()
        
        return try await context.perform {
            let request = AIModelEntity.fetchRequest()
            request.predicate = NSPredicate(format: "modelID == %@", modelID)
            request.fetchLimit = 1
            let results = try context.fetch(request)
            return results.first.map { AIModelDTO(from: $0) }
        }
    }
    
    /// Update specific properties of a model
    func updateModel(
        id: UUID,
        updates: @Sendable (AIModelEntity) -> Void
    ) async throws -> AIModelDTO {
        let context = persistence.newBackgroundContext()
        
        let dto = try await context.perform {
            let request = AIModelEntity.fetchRequest()
            request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
            request.fetchLimit = 1
            
            guard let entity = try context.fetch(request).first else {
                throw StoreError.modelNotFound(id)
            }
            
            updates(entity)
            try context.save()
            
            return AIModelDTO(from: entity)
        }
        
        modelCache[id] = dto
        modelChangesSubject.send(.updated(id))
        
        return dto
    }
    
    /// Update download progress for a model
    func updateDownloadProgress(id: UUID, progress: Double) async throws {
        try await updateModel(id: id) { entity in
            entity.downloadProgress = progress
            if progress >= 1.0 {
                entity.isDownloaded = true
            }
        }
    }
    
    /// Delete a model configuration (and optionally its downloaded files)
    func deleteModel(id: UUID, removeFiles: Bool = true) async throws {
        let context = persistence.newBackgroundContext()
        
        var localPath: String?
        var modelID: String?
        
        try await context.perform {
            let request = AIModelEntity.fetchRequest()
            request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
            guard let entity = try context.fetch(request).first else {
                throw StoreError.modelNotFound(id)
            }
            
            localPath = entity.localPath
            modelID = entity.modelID
            
            context.delete(entity)
            try context.save()
        }
        
        // Remove files if requested
        if removeFiles, let path = localPath {
            let url = URL(fileURLWithPath: path)
            try? FileManager.default.removeItem(at: url)
        }
        
        modelCache.removeValue(forKey: id)
        if activeModelID == id {
            activeModelID = nil
        }
        
        modelChangesSubject.send(.deleted(id))
        logger.info("Deleted model \(modelID ?? "unknown")")
    }
    
    /// Set the active model for inference
    func setActiveModel(id: UUID) async throws {
        // Verify model exists and is downloaded
        guard let model = try await fetchModel(byID: id) else {
            throw StoreError.modelNotFound(id)
        }
        
        guard model.isDownloaded || model.format == .coreml else {
            throw StoreError.modelNotDownloaded(model.name)
        }
        
        // Clear previous default
        if let currentId = activeModelID {
            _ = try? await updateModel(id: currentId) { $0.isDefault = false }
        }
        
        // Set new active
        _ = try await updateModel(id: id) { entity in
            entity.isDefault = true
            entity.lastUsed = Date()
        }
        
        activeModelID = id
        UserDefaults.standard.set(id.uuidString, forKey: "lastActiveModelID")
        
        logger.info("Set active model: \(model.name)")
    }
    
    /// Get the currently active model DTO
    func getActiveModel() async throws -> AIModelDTO? {
        guard let id = activeModelID else { return nil }
        return try await fetchModel(byID: id)
    }
    
    // MARK: - Inference Parameters
    
    /// Get inference parameters for a specific model (with overrides)
    func inferenceParameters(for modelID: UUID) async throws -> InferenceParameters {
        guard let model = try await fetchModel(byID: modelID) else {
            return defaultParameters
        }
        
        var params = defaultParameters
        
        // Apply model-specific overrides based on format and size
        switch model.format {
        case .gguf:
            // GGUF models via llama.cpp benefit from specific settings
            if model.quantization?.rawValue.hasPrefix("Q4") == true {
                params.nBatch = 256  // Smaller batch for Q4
            }
        case .mlx:
            // MLX models use Metal performance primitives
            params.useMetal = true
            params.nBatch = 512
        case .coreml:
            params.useANE = true
            params.nBatch = 256
        }
        
        // Adjust context length
        params.nCtx = min(model.contextLength, params.nCtx)
        
        return params
    }
    
    /// Update default inference parameters
    func updateDefaultParameters(_ params: InferenceParameters) {
        defaultParameters = params
        params.saveDefaults()
        modelChangesSubject.send(.parametersUpdated)
    }
    
    // MARK: - Import / Export
    
    /// Export model configuration to JSON
    func exportConfiguration(id: UUID) async throws -> Data {
        guard let model = try await fetchModel(byID: id) else {
            throw StoreError.modelNotFound(id)
        }
        
        let export = ModelConfigurationExport(
            model: model,
            inferenceParameters: defaultParameters,
            exportedAt: Date()
        )
        
        return try JSONEncoder().encode(export)
    }
    
    /// Import model configuration from JSON
    func importConfiguration(from data: Data) async throws -> AIModelDTO {
        let export = try JSONDecoder().decode(ModelConfigurationExport.self, from: data)
        
        return try await createModel(
            modelID: export.model.modelID,
            name: export.model.name,
            format: export.model.format,
            quantization: export.model.quantization,
            contextLength: export.model.contextLength,
            supportsVision: export.model.supportsVision,
            supportsText: export.model.supportsText,
            accelerationPreference: export.model.accelerationPreference,
            customRepoURL: export.model.customRepoURL,
            parameters: export.model.parameters
        )
    }
    
    // MARK: - Storage Management
    
    /// Get total storage used by all downloaded models
    func totalStorageUsed() async -> Int64 {
        guard let models = try? await fetchDownloadedModels() else { return 0 }
        return models.reduce(0) { $0 + $1.fileSize }
    }
    
    /// Get storage breakdown by model
    func storageBreakdown() async -> [(model: AIModelDTO, size: Int64)] {
        guard let models = try? await fetchDownloadedModels() else { return [] }
        return models.map { ($0, $0.fileSize) }.sorted { $0.size > $1.size }
    }
    
    /// Clean up incomplete downloads and orphaned files
    func cleanupIncompleteDownloads() async throws {
        let models = try await fetchAllModels()
        let fm = FileManager.default
        
        for model in models where !model.isDownloaded {
            // Remove any partial files
            if let path = model.localPath {
                let url = URL(fileURLWithPath: path)
                try? fm.removeItem(at: url)
            }
        }
        
        logger.info("Cleanup completed")
    }
    
    // MARK: - Private Helpers
    
    private func loadLastActiveModel() {
        if let saved = UserDefaults.standard.string(forKey: "lastActiveModelID"),
           let uuid = UUID(uuidString: saved) {
            activeModelID = uuid
        }
    }
    
    private func inferContextLength(from modelID: String, files: [HFFileEntry]) -> Int {
        // Check config.json for context window
        if files.contains(where: { $0.path == "config.json" }) {
            // Would need to download and parse config.json.
            // For now, use heuristics.
        }
        
        // Heuristic based on model name
        if modelID.contains("4k") || modelID.contains("4K") { return 4096 }
        if modelID.contains("8k") || modelID.contains("8K") { return 8192 }
        if modelID.contains("16k") || modelID.contains("16K") { return 16384 }
        if modelID.contains("32k") || modelID.contains("32K") { return 32768 }
        if modelID.contains("128k") || modelID.contains("128K") { return 131072 }
        
        // Default based on model size
        if modelID.contains("mini") || modelID.contains("small") { return 4096 }
        if modelID.contains("medium") { return 8192 }
        return 4096 // Safe default for mobile
    }
    
    private func inferParameterCount(from modelID: String, files: [HFFileEntry]) -> String? {
        let patterns = [
            ("([0-9]+\\.?[0-9]*)b", 1),
            ("([0-9]+\\.?[0-9]*)B", 1),
            ("([0-9]+)\\.([0-9]+)B", 1)
        ]
        
        let lowercased = modelID.lowercased()
        for (pattern, _) in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: []),
               let match = regex.firstMatch(in: lowercased, range: NSRange(lowercased.startIndex..., in: lowercased)),
               let range = Range(match.range(at: 1), in: lowercased) {
                return String(lowercased[range]) + "B"
            }
        }
        
        // Check GGUF filename for parameter count
        if let ggufFile = files.first(where: { $0.path.hasSuffix(".gguf") }) {
            let name = ggufFile.path.lowercased()
            if name.contains("1b") { return "1B" }
            if name.contains("3b") { return "3B" }
            if name.contains("7b") { return "7B" }
        }
        
        return nil
    }
}

// MARK: - Inference Parameters

/// Configurable inference parameters for model execution
struct InferenceParameters: Codable, Sendable, Equatable {
    /// Temperature for sampling (0.0 = deterministic, 1.0 = creative)
    var temperature: Double
    /// Top-p (nucleus) sampling threshold
    var topP: Double
    /// Top-k sampling limit
    var topK: Int
    /// Maximum tokens to generate
    var maxTokens: Int
    /// Context window size
    var nCtx: Int
    /// Batch size for prompt processing
    var nBatch: Int
    /// Number of GPU layers to offload (GGUF)
    var nGpuLayers: Int
    /// Penalize repeating tokens
    var repeatPenalty: Double
    /// Repeat penalty window
    var repeatLastN: Int
    /// Seed for reproducible generation (nil = random)
    var seed: UInt32?
    /// Use Metal GPU acceleration
    var useMetal: Bool
    /// Use Apple Neural Engine
    var useANE: Bool
    /// Stop sequences
    var stopSequences: [String]
    /// System prompt override
    var systemPrompt: String?
    
    static let `default` = InferenceParameters(
        temperature: 0.7,
        topP: 0.9,
        topK: 40,
        maxTokens: 2048,
        nCtx: 4096,
        nBatch: 512,
        nGpuLayers: -1, // All layers
        repeatPenalty: 1.1,
        repeatLastN: 64,
        seed: nil,
        useMetal: true,
        useANE: false,
        stopSequences: ["<|im_end|>", "<|endoftext|>", "Human:", "Assistant:"],
        systemPrompt: nil
    )
    
    func saveDefaults() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: "inferenceParameters")
        }
    }
    
    static func loadDefaults() -> InferenceParameters {
        guard let data = UserDefaults.standard.data(forKey: "inferenceParameters"),
              let params = try? JSONDecoder().decode(InferenceParameters.self, from: data) else {
            return .default
        }
        return params
    }
}

// MARK: - Model Change Events

enum ModelChangeEvent: Sendable {
    case created(UUID)
    case updated(UUID)
    case deleted(UUID)
    case activated(UUID)
    case parametersUpdated
}

// MARK: - Export/Import

struct ModelConfigurationExport: Codable {
    let model: AIModelDTO
    let inferenceParameters: InferenceParameters
    let exportedAt: Date
    let version: String
    
    init(model: AIModelDTO, inferenceParameters: InferenceParameters, exportedAt: Date) {
        self.model = model
        self.inferenceParameters = inferenceParameters
        self.exportedAt = exportedAt
        self.version = "1.0"
    }
}

// MARK: - Errors

enum StoreError: Error, Sendable {
    case modelNotFound(UUID)
    case modelNotDownloaded(String)
    case invalidConfiguration(String)
    case persistenceFailure(String)
    case duplicateModelID(String)
    
    var localizedDescription: String {
        switch self {
        case .modelNotFound(let id):
            return "Model with ID \(id) not found in configuration store"
        case .modelNotDownloaded(let name):
            return "Model '\(name)' is not downloaded yet"
        case .invalidConfiguration(let detail):
            return "Invalid configuration: \(detail)"
        case .persistenceFailure(let detail):
            return "Database error: \(detail)"
        case .duplicateModelID(let id):
            return "A model with ID '\(id)' already exists"
        }
    }
}

// MARK: - Core Data Stack

/// Thread-safe Core Data stack with background context support
final class CoreDataStack {
    static let shared = CoreDataStack()
    
    private let persistentContainer: NSPersistentContainer
    
    var viewContext: NSManagedObjectContext {
        persistentContainer.viewContext
    }
    
    private init() {
        persistentContainer = NSPersistentContainer(name: "OnDeviceAIIDE")
        persistentContainer.loadPersistentStores { _, error in
            if let error = error {
                fatalError("Core Data load failed: \(error)")
            }
        }
        persistentContainer.viewContext.automaticallyMergesChangesFromParent = true
        persistentContainer.viewContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
    }
    
    func newBackgroundContext() -> NSManagedObjectContext {
        let context = persistentContainer.newBackgroundContext()
        context.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        return context
    }
    
    func save() throws {
        guard viewContext.hasChanges else { return }
        try viewContext.save()
    }
}
