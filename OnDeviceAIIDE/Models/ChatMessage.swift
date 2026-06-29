// MARK: - Chat Message Model
// OnDeviceAIIDE/Models/ChatMessage.swift

import Foundation

/// Represents a message in the AI chat interface
struct ChatMessage: Identifiable, Codable, Sendable {
    let id: UUID
    let role: ChatRole
    let content: String
    let timestamp: Date
    let referencedFiles: [String]?
    let modelUsed: String?
    let tokenCount: Int?
    
    enum ChatRole: String, Codable, Sendable {
        case user
        case assistant
        case system
    }
    
    init(
        id: UUID = UUID(),
        role: ChatRole,
        content: String,
        timestamp: Date = Date(),
        referencedFiles: [String]? = nil,
        modelUsed: String? = nil,
        tokenCount: Int? = nil
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.timestamp = timestamp
        self.referencedFiles = referencedFiles
        self.modelUsed = modelUsed
        self.tokenCount = tokenCount
    }
    
    /// System prompt for code assistance context
    static func systemPrompt(projectContext: String?) -> ChatMessage {
        var content = """
        You are an expert programming assistant running in an on-device IDE.
        You have access to the user's codebase through RAG retrieval.
        Provide concise, accurate code assistance.
        Always prefer showing code examples when applicable.
        If referencing code, include the file path and line numbers.
        """
        
        if let context = projectContext {
            content += "\n\nProject context: \(context)"
        }
        
        return ChatMessage(role: .system, content: content)
    }
}

/// A conversation session between user and AI
struct ChatSession: Identifiable, Codable, Sendable {
    let id: UUID
    var title: String
    var messages: [ChatMessage]
    let createdAt: Date
    var lastModified: Date
    var projectContext: String?
    var activeModelID: UUID?
    
    var messageCount: Int { messages.count }
    
    var previewText: String {
        messages.last { $0.role == .user }?.content ?? "New conversation"
    }
}
