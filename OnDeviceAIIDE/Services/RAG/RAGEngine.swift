// MARK: - RAG Engine (Retrieval-Augmented Generation)
// OnDeviceAIIDE/Services/RAG/RAGEngine.swift
//
// Local vector database for codebase embeddings.
// Enables context-aware AI prompts across the entire multi-file project.

import Foundation
import NaturalLanguage
import CoreML
import os.log

/// RAG Engine for codebase context retrieval
actor RAGEngine {
    
    static let shared = RAGEngine()
    
    private let logger = Logger(subsystem: "com.ondeviceaiide", category: "RAGEngine")
    private let fileManager = FileManager.default
    
    /// Vector database storage
    private var vectorDB: VectorDatabase
    /// Embedding service for text-to-vector conversion
    private let embeddingService: EmbeddingService
    /// Document chunking strategy
    private let chunker: DocumentChunker
    
    /// Whether the engine is initialized and ready
    private(set) var isInitialized = false
    /// Currently indexed project
    private(set) var indexedProject: Project?
    /// Number of chunks in the index
    var chunkCount: Int { vectorDB.count }
    
    private init() {
        self.vectorDB = VectorDatabase()
        self.embeddingService = EmbeddingService()
        self.chunker = DocumentChunker()
    }
    
    // MARK: - Lifecycle
    
    /// Initialize the RAG engine with a project's codebase
    func initialize(for project: Project) async throws {
        logger.info("Initializing RAG engine for \(project.name)")
        
        // Clear previous index
        await vectorDB.clear()
        
        // Index all project files
        try await indexProject(project)
        
        indexedProject = project
        isInitialized = true
        
        logger.info("RAG engine ready with \(vectorDB.count) chunks")
    }
    
    /// Shutdown and clear resources
    func shutdown() async {
        await vectorDB.clear()
        indexedProject = nil
        isInitialized = false
        logger.info("RAG engine shutdown")
    }
    
    // MARK: - Indexing
    
    /// Index all source files in a project
    func indexProject(_ project: Project) async throws {
        let fileTree = try await FileSystemManager.shared.buildFileTree(for: project)
        
        // Collect all source code files
        let sourceFiles = collectSourceFiles(from: fileTree, in: project)
        
        logger.info("Indexing \(sourceFiles.count) files...")
        
        for fileURL in sourceFiles {
            do {
                let content = try String(contentsOf: fileURL, encoding: .utf8)
                let relativePath = fileURL.path.replacingOccurrences(
                    of: project.rootPath.path + "/",
                    with: ""
                )
                try await indexDocument(content: content, path: relativePath)
            } catch {
                logger.warning("Failed to index \(fileURL.lastPathComponent): \(error.localizedDescription)")
            }
        }
    }
    
    /// Index a single document (file)
    func indexDocument(content: String, path: String) async throws {
        // Skip binary or very large files
        guard content.count < 500_000 else {
            logger.debug("Skipping large file: \(path)")
            return
        }
        
        // Chunk the document
        let chunks = chunker.chunk(content: content, sourcePath: path)
        
        // Generate embeddings for each chunk
        for chunk in chunks {
            let embedding = try await embeddingService.embed(text: chunk.content)
            
            let vectorChunk = VectorChunk(
                id: UUID(),
                content: chunk.content,
                sourcePath: path,
                startLine: chunk.startLine,
                endLine: chunk.endLine,
                embedding: embedding,
                language: path.fileLanguage
            )
            
            await vectorDB.insert(vectorChunk)
        }
    }
    
    /// Re-index a specific file (for incremental updates)
    func reindexFile(content: String, path: String) async throws {
        // Remove old chunks for this file
        await vectorDB.deleteBySource(path: path)
        
        // Re-index
        try await indexDocument(content: content, path: path)
        
        logger.info("Re-indexed: \(path)")
    }
    
    // MARK: - Retrieval
    
    /// Retrieve relevant context chunks for a query
    func retrieve(
        query: String,
        topK: Int = 5,
        minRelevance: Float = 0.5
    ) async throws -> [RetrievalResult] {
        guard isInitialized else {
            throw RagError.notInitialized
        }
        
        // Embed the query
        let queryEmbedding = try await embeddingService.embed(text: query)
        
        // Search vector database
        let results = await vectorDB.search(
            queryEmbedding: queryEmbedding,
            topK: topK * 2, // Fetch extra for filtering
            minRelevance: minRelevance
        )
        
        // Deduplicate and rerank
        let deduplicated = deduplicate(results: results, maxPerFile: 3)
        let reranked = rerank(results: deduplicated, query: query)
        
        return Array(reranked.prefix(topK))
    }
    
    /// Build a context prompt from retrieved chunks
    func buildContextPrompt(query: String, maxTokens: Int = 2000) async throws -> String {
        let results = try await retrieve(query: query, topK: 10)
        
        guard !results.isEmpty else {
            return query
        }
        
        var context = "```\nRelevant code context:\n\n"
        var tokenCount = 0
        
        for result in results {
            let chunkHeader = "// File: \(result.sourcePath) (lines \(result.startLine)-\(result.endLine))\n"
            let chunkContent = result.content
            let chunkText = chunkHeader + chunkContent + "\n\n"
            
            // Approximate token count (1 token ~ 4 chars for code)
            let estimatedTokens = chunkText.count / 4
            if tokenCount + estimatedTokens > maxTokens {
                break
            }
            
            context += chunkText
            tokenCount += estimatedTokens
        }
        
        context += "```\n\nQuery: \(query)\n\nAnswer based on the provided code context."
        
        return context
    }
    
    // MARK: - Private Helpers
    
    private func collectSourceFiles(from node: FileNode, in project: Project) -> [URL] {
        var files: [URL] = []
        
        if node.isDirectory {
            // Skip common non-source directories
            let skipDirs = [".git", "node_modules", "venv", "__pycache__", ".build", "DerivedData", "dist", ".DS_Store"]
            if skipDirs.contains(node.name) { return [] }
            
            for child in node.children ?? [] {
                files.append(contentsOf: collectSourceFiles(from: child, in: project))
            }
        } else {
            // Only index source code files
            let sourceExtensions = [
                "swift", "py", "js", "ts", "jsx", "tsx", "html", "css",
                "c", "cpp", "cc", "cxx", "h", "hpp", "rs", "go",
                "java", "kt", "rb", "sh", "md", "json", "yml", "yaml",
                "sql", "r", "m", "scala", "groovy", "php"
            ]
            
            if let ext = node.fileExtension?.lowercased(), sourceExtensions.contains(ext) {
                files.append(project.rootPath.appendingPathComponent(node.path))
            }
        }
        
        return files
    }
    
    private func deduplicate(results: [RetrievalResult], maxPerFile: Int) -> [RetrievalResult] {
        var fileCount: [String: Int] = [:]
        return results.filter { result in
            let count = (fileCount[result.sourcePath] ?? 0) + 1
            fileCount[result.sourcePath] = count
            return count <= maxPerFile
        }
    }
    
    private func rerank(results: [RetrievalResult], query: String) -> [RetrievalResult] {
        // Simple reranking: boost exact matches and file name matches
        let queryLower = query.lowercased()
        let queryTerms = queryLower.split(separator: " ").map(String.init)
        
        return results.sorted { a, b in
            var scoreA = a.relevanceScore
            var scoreB = b.relevanceScore
            
            // Boost if filename matches query terms
            let fileA = a.sourcePath.lowercased()
            let fileB = b.sourcePath.lowercased()
            
            for term in queryTerms {
                if fileA.contains(term) { scoreA += 0.1 }
                if fileB.contains(term) { scoreB += 0.1 }
            }
            
            // Boost if content contains exact query
            if a.content.lowercased().contains(queryLower) { scoreA += 0.15 }
            if b.content.lowercased().contains(queryLower) { scoreB += 0.15 }
            
            return scoreA > scoreB
        }
    }
}

// MARK: - Document Chunker

/// Chunks source code documents for embedding
actor DocumentChunker {
    
    /// Target chunk size in characters
    private let targetChunkSize = 1000
    /// Overlap between chunks in characters
    private let chunkOverlap = 200
    /// Maximum chunk size
    private let maxChunkSize = 2000
    
    /// Chunk a document into processable pieces
    func chunk(content: String, sourcePath: String) -> [DocumentChunk] {
        let language = sourcePath.fileLanguage
        
        // Use language-aware chunking for code files
        if language != nil {
            return chunkCode(content: content, path: sourcePath)
        }
        
        // Simple chunking for non-code files
        return chunkText(content: content, path: sourcePath)
    }
    
    private func chunkCode(content: String, path: String) -> [DocumentChunk] {
        let lines = content.components(separatedBy: .newlines)
        var chunks: [DocumentChunk] = []
        var currentLines: [String] = []
        var currentSize = 0
        var startLine = 1
        var lineIndex = 0
        
        // Split on structural boundaries
        let structuralPatterns = [
            "func ", "class ", "struct ", "enum ", "protocol ",
            "extension ", "import ", "def ", "class ", "# ",
            "// MARK:", "#pragma mark", "module.exports"
        ]
        
        func flushChunk(endLine: Int) {
            guard !currentLines.isEmpty else { return }
            let chunkContent = currentLines.joined(separator: "\n")
            guard chunkContent.count >= 50 else { return } // Skip tiny chunks
            
            chunks.append(DocumentChunk(
                content: chunkContent,
                sourcePath: path,
                startLine: startLine,
                endLine: endLine
            ))
        }
        
        for (index, line) in lines.enumerated() {
            let lineNum = index + 1
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            
            // Check if this is a structural boundary
            let isBoundary = structuralPatterns.contains { trimmed.hasPrefix($0) }
            
            // Start new chunk at boundaries if current chunk is large enough
            if isBoundary && currentSize >= targetChunkSize && !currentLines.isEmpty {
                flushChunk(endLine: lineIndex)
                
                // Overlap: include last few lines
                let overlapLines = Array(currentLines.suffix(chunkOverlap / 50))
                currentLines = overlapLines + [line]
                currentSize = overlapLines.joined().count + line.count
                startLine = lineNum - overlapLines.count
            } else {
                currentLines.append(line)
                currentSize += line.count
            }
            
            // Force split if chunk gets too large
            if currentSize >= maxChunkSize {
                flushChunk(endLine: lineNum)
                let overlapLines = Array(currentLines.suffix(chunkOverlap / 50))
                currentLines = overlapLines
                currentSize = overlapLines.joined().count
                startLine = lineNum - overlapLines.count + 1
            }
            
            lineIndex = lineNum
        }
        
        // Flush remaining
        if !currentLines.isEmpty {
            flushChunk(endLine: lines.count)
        }
        
        return chunks
    }
    
    private func chunkText(content: String, path: String) -> [DocumentChunk] {
        // Simple sliding window for non-code
        var chunks: [DocumentChunk] = []
        let paragraphs = content.components(separatedBy: "\n\n")
        var currentText = ""
        var startLine = 1
        var currentLine = 1
        
        for paragraph in paragraphs {
            if currentText.count + paragraph.count > maxChunkSize && !currentText.isEmpty {
                chunks.append(DocumentChunk(
                    content: currentText,
                    sourcePath: path,
                    startLine: startLine,
                    endLine: currentLine
                ))
                currentText = String(currentText.suffix(chunkOverlap)) + "\n\n" + paragraph
                startLine = currentLine
            } else {
                if !currentText.isEmpty { currentText += "\n\n" }
                currentText += paragraph
            }
            currentLine += paragraph.components(separatedBy: .newlines).count + 1
        }
        
        if !currentText.isEmpty {
            chunks.append(DocumentChunk(
                content: currentText,
                sourcePath: path,
                startLine: startLine,
                endLine: currentLine
            ))
        }
        
        return chunks
    }
}

// MARK: - Embedding Service

/// Generates vector embeddings using on-device CoreML/BERT
actor EmbeddingService {
    
    private let logger = Logger(subsystem: "com.ondeviceaiide", category: "EmbeddingService")
    
    /// Embedding dimension (384 for MiniLM, 768 for BERT-base)
    private let embeddingDimension = 384
    
    /// Whether the embedding model is loaded
    private(set) var isLoaded = false
    
    /// The embedding model (placeholder - would load a CoreML converted MiniLM model)
    // private var embeddingModel: MLModel?
    
    init() {
        // In production, load a CoreML-converted sentence-transformers model
        // e.g., all-MiniLM-L6-v2 converted to CoreML
    }
    
    /// Generate embedding vector for text
    func embed(text: String) async throws -> [Float] {
        // In production, this would:
        // 1. Tokenize the text using the model's tokenizer
        // 2. Run inference through the CoreML model
        // 3. Apply mean pooling over token embeddings
        // 4. Normalize the vector
        
        // Placeholder: Generate deterministic pseudo-embeddings
        // This produces consistent results for the same text
        return generatePseudoEmbedding(for: text, dimension: embeddingDimension)
    }
    
    /// Batch embed multiple texts
    func embedBatch(texts: [String]) async throws -> [[Float]] {
        var embeddings: [[Float]] = []
        for text in texts {
            let embedding = try await embed(text: text)
            embeddings.append(embedding)
        }
        return embeddings
    }
    
    /// Cosine similarity between two embeddings
    func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count else { return 0 }
        
        var dotProduct: Float = 0
        var normA: Float = 0
        var normB: Float = 0
        
        for i in 0..<a.count {
            dotProduct += a[i] * b[i]
            normA += a[i] * a[i]
            normB += b[i] * b[i]
        }
        
        let denom = sqrt(normA) * sqrt(normB)
        guard denom > 0 else { return 0 }
        
        return dotProduct / denom
    }
    
    // MARK: - Private
    
    /// Generate deterministic pseudo-embeddings for placeholder
    private func generatePseudoEmbedding(for text: String, dimension: Int) -> [Float] {
        // Use a hash-based approach for consistent pseudo-embeddings
        var seed = text.hashValue
        var embedding = [Float](repeating: 0, count: dimension)
        
        var generator = SeededRandomNumberGenerator(seed: UInt64(bitPattern: Int64(seed)))
        
        for i in 0..<dimension {
            embedding[i] = Float.random(in: -1...1, using: &generator)
        }
        
        // Normalize
        let norm = sqrt(embedding.map { $0 * $0 }.reduce(0, +))
        if norm > 0 {
            embedding = embedding.map { $0 / norm }
        }
        
        return embedding
    }
}

// MARK: - Seeded Random

struct SeededRandomNumberGenerator: RandomNumberGenerator {
    private var state: UInt64
    
    init(seed: UInt64) {
        self.state = seed
    }
    
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
}

// MARK: - Vector Database

/// In-memory vector database with cosine similarity search
actor VectorDatabase {
    
    private var chunks: [VectorChunk] = []
    private var index: [String: [VectorChunk]] = [:] // sourcePath -> chunks
    
    var count: Int { chunks.count }
    
    func insert(_ chunk: VectorChunk) {
        chunks.append(chunk)
        index[chunk.sourcePath, default: []].append(chunk)
    }
    
    func insertBatch(_ newChunks: [VectorChunk]) {
        for chunk in newChunks {
            insert(chunk)
        }
    }
    
    func search(queryEmbedding: [Float], topK: Int, minRelevance: Float) -> [RetrievalResult] {
        let results = chunks
            .map { chunk -> RetrievalResult in
                let similarity = cosineSimilarity(queryEmbedding, chunk.embedding)
                return RetrievalResult(
                    chunk: chunk,
                    relevanceScore: similarity
                )
            }
            .filter { $0.relevanceScore >= minRelevance }
            .sorted { $0.relevanceScore > $1.relevanceScore }
        
        return Array(results.prefix(topK))
    }
    
    func deleteBySource(path: String) {
        chunks.removeAll { $0.sourcePath == path }
        index.removeValue(forKey: path)
    }
    
    func clear() {
        chunks.removeAll()
        index.removeAll()
    }
    
    private func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count else { return 0 }
        
        var dotProduct: Float = 0
        var normA: Float = 0
        var normB: Float = 0
        
        for i in 0..<a.count {
            dotProduct += a[i] * b[i]
            normA += a[i] * a[i]
            normB += b[i] * b[i]
        }
        
        let denom = sqrt(normA) * sqrt(normB)
        guard denom > 0 else { return 0 }
        
        return dotProduct / denom
    }
}

// MARK: - Data Models

/// A chunk of a source document
struct DocumentChunk: Sendable {
    let content: String
    let sourcePath: String
    let startLine: Int
    let endLine: Int
}

/// A chunk with its vector embedding
struct VectorChunk: Sendable {
    let id: UUID
    let content: String
    let sourcePath: String
    let startLine: Int
    let endLine: Int
    let embedding: [Float]
    let language: String?
}

/// Result of a vector search
struct RetrievalResult: Sendable {
    let chunk: VectorChunk
    let relevanceScore: Float
    
    var content: String { chunk.content }
    var sourcePath: String { chunk.sourcePath }
    var startLine: Int { chunk.startLine }
    var endLine: Int { chunk.endLine }
    var language: String? { chunk.language }
}

// MARK: - Errors

enum RagError: Error, Sendable {
    case notInitialized
    case embeddingFailed(String)
    case indexingFailed(String)
    case retrievalFailed(String)
    
    var localizedDescription: String {
        switch self {
        case .notInitialized: return "RAG engine not initialized"
        case .embeddingFailed(let msg): return "Embedding failed: \(msg)"
        case .indexingFailed(let msg): return "Indexing failed: \(msg)"
        case .retrievalFailed(let msg): return "Retrieval failed: \(msg)"
        }
    }
}

// MARK: - Extensions

private extension String {
    var fileLanguage: String? {
        let ext = (self as NSString).pathExtension.lowercased()
        switch ext {
        case "swift": return "swift"
        case "py": return "python"
        case "js": return "javascript"
        case "ts": return "typescript"
        case "html", "htm": return "html"
        case "css": return "css"
        case "c": return "c"
        case "cpp", "cc", "cxx", "hpp": return "cpp"
        case "h": return "objc"
        case "rs": return "rust"
        case "go": return "go"
        case "java": return "java"
        case "kt": return "kotlin"
        case "rb": return "ruby"
        case "sh": return "shell"
        case "md": return "markdown"
        case "json": return "json"
        case "yml", "yaml": return "yaml"
        case "sql": return "sql"
        default: return ext.isEmpty ? nil : ext
        }
    }
}
