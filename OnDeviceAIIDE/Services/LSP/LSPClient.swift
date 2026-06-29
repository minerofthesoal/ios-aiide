// MARK: - Language Server Protocol (LSP) Client
// OnDeviceAIIDE/Services/LSP/LSPClient.swift
//
// LSP client for syntax highlighting, diagnostics, and autocompletion.
// Communicates with language servers via JSON-RPC over local sockets.

import Foundation
import os.log

#if os(iOS)
/// iOS does not expose Foundation.Process for spawning local language servers.
/// This shim keeps the LSP client buildable for the iOS app target while
/// preserving the same API surface for future app-extension or helper support.
private final class Process {
    var executableURL: URL?
    var arguments: [String]?
    var standardInput: Any?
    var standardOutput: Any?
    var standardError: Any?
    var isRunning: Bool { false }

    func run() throws {
        throw NSError(
            domain: "com.ondeviceaiide.lsp",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Local language server processes are unavailable on iOS."]
        )
    }

    func terminate() {}
}
#endif

/// LSP Client for IDE language features
actor LSPClient {
    
    static let shared = LSPClient()
    
    private let logger = Logger(subsystem: "com.ondeviceaiide", category: "LSPClient")
    
    /// Active language server connections by language ID
    private var connections: [String: LSPConnection] = [:]
    
    /// Available language server configurations
    private var serverConfigs: [String: ServerConfig] = [
        "swift": ServerConfig(
            executable: "sourcekit-lsp",
            args: [],
            initializationOptions: [:]
        ),
        "python": ServerConfig(
            executable: "pylsp",
            args: [],
            initializationOptions: [:]
        ),
        "javascript": ServerConfig(
            executable: "typescript-language-server",
            args: ["--stdio"],
            initializationOptions: [:]
        ),
        "typescript": ServerConfig(
            executable: "typescript-language-server",
            args: ["--stdio"],
            initializationOptions: [:]
        ),
        "rust": ServerConfig(
            executable: "rust-analyzer",
            args: [],
            initializationOptions: [:]
        ),
        "go": ServerConfig(
            executable: "gopls",
            args: [],
            initializationOptions: [:]
        ),
        "c": ServerConfig(
            executable: "clangd",
            args: [],
            initializationOptions: [:]
        ),
        "cpp": ServerConfig(
            executable: "clangd",
            args: [],
            initializationOptions: [:]
        ),
    ]
    
    private var messageID = 0
    private var pendingRequests: [Int: CheckedContinuation<LSPResponse, Error>] = [:]
    
    // MARK: - Server Lifecycle
    
    /// Start a language server for the given language
    func startServer(for language: String, workspaceRoot: URL) async throws {
        guard let config = serverConfigs[language] else {
            throw LSPError.unsupportedLanguage(language)
        }
        
        if connections[language] != nil {
            logger.info("LSP server for \(language) already running")
            return
        }
        
        logger.info("Starting LSP server for \(language): \(config.executable)")
        
        // Create process for language server
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [config.executable] + config.args
        
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        
        try process.run()
        
        let connection = LSPConnection(
            process: process,
            stdin: stdinPipe,
            stdout: stdoutPipe,
            stderr: stderrPipe,
            workspaceRoot: workspaceRoot
        )
        
        connections[language] = connection
        
        // Start reading responses
        Task {
            await readResponses(from: connection, language: language)
        }
        
        // Send initialize request
        let initParams = InitializeParams(
            processId: Int(ProcessInfo.processInfo.processIdentifier),
            rootUri: workspaceRoot.absoluteString,
            capabilities: ClientCapabilities(
                textDocument: TextDocumentClientCapabilities(
                    synchronization: .init(dynamicRegistration: false),
                    completion: .init(dynamicRegistration: false, completionItem: .init(snippetSupport: true)),
                    hover: .init(dynamicRegistration: false),
                    definition: .init(dynamicRegistration: false),
                    documentHighlight: .init(dynamicRegistration: false),
                    documentSymbol: .init(dynamicRegistration: false),
                    formatting: .init(dynamicRegistration: false),
                    rename: .init(dynamicRegistration: false),
                    publishDiagnostics: .init(relatedInformation: true),
                    semanticTokens: .init(
                        dynamicRegistration: false,
                        requests: .init(range: true, full: .init(delta: false)),
                        tokenTypes: ["namespace", "type", "class", "enum", "interface", "struct", "typeParameter", "parameter", "variable", "property", "enumMember", "event", "function", "method", "macro", "keyword", "modifier", "comment", "string", "number", "regexp", "operator"],
                        tokenModifiers: ["declaration", "definition", "readonly", "static", "deprecated", "abstract", "async", "modification", "documentation", "defaultLibrary"],
                        formats: ["relative"]
                    )
                ),
                workspace: WorkspaceClientCapabilities(
                    applyEdit: true,
                    workspaceEdit: .init(documentChanges: true),
                    didChangeConfiguration: .init(dynamicRegistration: false),
                    didChangeWatchedFiles: .init(dynamicRegistration: false)
                )
            )
        )
        
        let response = try await sendRequest(
            method: "initialize",
            params: initParams,
            language: language
        )
        
        logger.info("LSP server for \(language) initialized")
        
        // Send initialized notification
        try await sendNotification(method: "initialized", params: [String: Any](), language: language)
    }
    
    /// Stop a language server
    func stopServer(for language: String) async {
        guard let connection = connections[language] else { return }
        
        // Send shutdown request
        _ = try? await sendRequest(method: "shutdown", params: nil as [String: String]?, language: language)
        
        // Send exit notification
        try? await sendNotification(method: "exit", params: nil as [String: String]?, language: language)
        
        connection.process.terminate()
        connections.removeValue(forKey: language)
        
        logger.info("LSP server for \(language) stopped")
    }
    
    // MARK: - Text Document Operations
    
    /// Open a document in the language server
    func didOpenDocument(uri: String, language: String, text: String, version: Int = 1) async throws {
        let params: [String: Any] = [
            "textDocument": [
                "uri": uri,
                "languageId": language,
                "version": version,
                "text": text
            ]
        ]
        try await sendNotification(method: "textDocument/didOpen", params: params, language: language)
    }
    
    /// Send document change notification
    func didChangeDocument(uri: String, language: String, changes: [TextDocumentContentChangeEvent], version: Int) async throws {
        let params: [String: Any] = [
            "textDocument": [
                "uri": uri,
                "version": version
            ],
            "contentChanges": changes.map { [
                "range": $0.range != nil ? [
                    "start": ["line": $0.range!.start.line, "character": $0.range!.start.character],
                    "end": ["line": $0.range!.end.line, "character": $0.range!.end.character]
                ] : NSNull(),
                "text": $0.text
            ] as [String: Any] }
        ]
        try await sendNotification(method: "textDocument/didChange", params: params, language: language)
    }
    
    /// Close a document
    func didCloseDocument(uri: String, language: String) async throws {
        let params: [String: Any] = [
            "textDocument": ["uri": uri]
        ]
        try await sendNotification(method: "textDocument/didClose", params: params, language: language)
    }
    
    // MARK: - Language Features
    
    /// Request completions at a position
    func completion(uri: String, language: String, line: Int, character: Int) async throws -> [CompletionItem] {
        let params = TextDocumentPositionParams(
            textDocument: TextDocumentIdentifier(uri: uri),
            position: Position(line: line, character: character)
        )
        
        let response = try await sendRequest(
            method: "textDocument/completion",
            params: params,
            language: language
        )
        
        if let result = response.result as? [String: Any],
           let items = result["items"] as? [[String: Any]] {
            return items.compactMap { CompletionItem(from: $0) }
        }
        if let items = response.result as? [[String: Any]] {
            return items.compactMap { CompletionItem(from: $0) }
        }
        return []
    }
    
    /// Request hover information
    func hover(uri: String, language: String, line: Int, character: Int) async throws -> Hover? {
        let params = TextDocumentPositionParams(
            textDocument: TextDocumentIdentifier(uri: uri),
            position: Position(line: line, character: character)
        )
        
        let response = try await sendRequest(
            method: "textDocument/hover",
            params: params,
            language: language
        )
        
        guard let result = response.result else { return nil }
        return Hover(from: result)
    }
    
    /// Request go-to-definition
    func definition(uri: String, language: String, line: Int, character: Int) async throws -> [Location]? {
        let params = TextDocumentPositionParams(
            textDocument: TextDocumentIdentifier(uri: uri),
            position: Position(line: line, character: character)
        )
        
        let response = try await sendRequest(
            method: "textDocument/definition",
            params: params,
            language: language
        )
        
        guard let result = response.result else { return nil }
        if let locations = result as? [[String: Any]] {
            return locations.compactMap { Location(from: $0) }
        }
        if let location = result as? [String: Any] {
            return [Location(from: location)].compactMap { $0 }
        }
        return nil
    }
    
    /// Request semantic tokens for syntax highlighting
    func semanticTokens(uri: String, language: String) async throws -> SemanticTokens? {
        let params: [String: Any] = [
            "textDocument": ["uri": uri]
        ]
        
        let response = try await sendRequest(
            method: "textDocument/semanticTokens/full",
            params: params,
            language: language
        )
        
        guard let result = response.result as? [String: Any],
              let data = result["data"] as? [Int] else { return nil }
        
        return SemanticTokens(data: data)
    }
    
    // MARK: - Private Methods
    
    private func sendRequest<T: Encodable>(
        method: String,
        params: T,
        language: String
    ) async throws -> LSPResponse {
        try await sendRequest(method: method, encodedParams: try encodeToAny(params), language: language)
    }

    private func sendRequest(
        method: String,
        params: [String: Any],
        language: String
    ) async throws -> LSPResponse {
        try await sendRequest(method: method, encodedParams: params, language: language)
    }

    private func sendRequest(
        method: String,
        encodedParams: Any,
        language: String
    ) async throws -> LSPResponse {
        guard let connection = connections[language] else {
            throw LSPError.serverNotRunning(language)
        }

        messageID += 1
        let id = messageID

        let request = JSONRPCRequest(
            jsonrpc: "2.0",
            id: id,
            method: method,
            params: encodedParams
        )

        let data = try JSONSerialization.data(withJSONObject: request.dictionary, options: [.withoutEscapingSlashes])
        let header = "Content-Length: \(data.count)\r\n\r\n"
        let message = Data(header.utf8) + data

        return try await withCheckedThrowingContinuation { continuation in
            pendingRequests[id] = continuation

            connection.stdin.fileHandleForWriting.write(message)

            // Timeout
            Task {
                try? await Task.sleep(nanoseconds: 30_000_000_000) // 30s timeout
                if pendingRequests.removeValue(forKey: id) != nil {
                    continuation.resume(throwing: LSPError.requestTimeout)
                }
            }
        }
    }

    private func sendNotification<T: Encodable>(
        method: String,
        params: T,
        language: String
    ) async throws {
        try await sendNotification(method: method, encodedParams: try encodeToAny(params), language: language)
    }

    private func sendNotification(
        method: String,
        params: [String: Any],
        language: String
    ) async throws {
        try await sendNotification(method: method, encodedParams: params, language: language)
    }

    private func sendNotification(
        method: String,
        encodedParams: Any,
        language: String
    ) async throws {
        guard let connection = connections[language] else { return }

        let notification: [String: Any] = [
            "jsonrpc": "2.0",
            "method": method,
            "params": encodedParams
        ]

        let data = try JSONSerialization.data(withJSONObject: notification, options: [.withoutEscapingSlashes])
        let header = "Content-Length: \(data.count)\r\n\r\n"
        let message = Data(header.utf8) + data

        connection.stdin.fileHandleForWriting.write(message)
    }
    
    private func readResponses(from connection: LSPConnection, language: String) async {
        let handle = connection.stdout.fileHandleForReading
        
        do {
            while connection.process.isRunning {
                // Read header
                guard let headerData = try? handle.read(upToCount: 1024),
                      let header = String(data: headerData, encoding: .utf8) else { continue }
                
                // Parse Content-Length
                guard let lengthMatch = header.range(of: "Content-Length: "),
                      let lengthEnd = header[...].range(of: "\r\n\r\n") else { continue }
                
                let lengthStart = header.index(lengthMatch.upperBound, offsetBy: 0)
                if let contentLength = Int(header[lengthStart..<lengthEnd.lowerBound].trimmingCharacters(in: .whitespaces)) {
                    // Read body
                    let bodyData = try? handle.read(upToCount: contentLength)
                    if let bodyData = bodyData,
                       let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any] {
                        handleResponse(json)
                    }
                }
            }
        }
    }
    
    private func handleResponse(_ json: [String: Any]) {
        if let id = json["id"] as? Int,
           let continuation = pendingRequests.removeValue(forKey: id) {
            let response = LSPResponse(
                id: id,
                result: json["result"],
                error: json["error"] as? [String: Any]
            )
            continuation.resume(returning: response)
        }
    }
    
    private func encodeToAny<T: Encodable>(_ value: T) throws -> Any {
        let data = try JSONEncoder().encode(value)
        return try JSONSerialization.jsonObject(with: data)
    }
}

// MARK: - Connection

struct LSPConnection {
    let process: Process
    let stdin: Pipe
    let stdout: Pipe
    let stderr: Pipe
    let workspaceRoot: URL
}

// MARK: - Models

struct ServerConfig {
    let executable: String
    let args: [String]
    let initializationOptions: [String: Any]
}

struct LSPResponse {
    let id: Int?
    let result: Any?
    let error: [String: Any]?
}

struct JSONRPCRequest {
    let jsonrpc: String
    let id: Int
    let method: String
    let params: Any
    
    var dictionary: [String: Any] {
        var dict: [String: Any] = [
            "jsonrpc": jsonrpc,
            "id": id,
            "method": method
        ]
        if !(params is NSNull) {
            dict["params"] = params
        }
        return dict
    }
}

// MARK: - LSP Types

struct InitializeParams: Encodable {
    let processId: Int
    let rootUri: String
    let capabilities: ClientCapabilities
}

struct ClientCapabilities: Encodable {
    let textDocument: TextDocumentClientCapabilities
    let workspace: WorkspaceClientCapabilities
}

struct TextDocumentClientCapabilities: Encodable {
    let synchronization: DynamicRegistrationCapability
    let completion: CompletionCapability
    let hover: DynamicRegistrationCapability
    let definition: DynamicRegistrationCapability
    let documentHighlight: DynamicRegistrationCapability
    let documentSymbol: DynamicRegistrationCapability
    let formatting: DynamicRegistrationCapability
    let rename: DynamicRegistrationCapability
    let publishDiagnostics: DiagnosticsCapability
    let semanticTokens: SemanticTokensCapability
}

struct DynamicRegistrationCapability: Encodable {
    let dynamicRegistration: Bool
}

struct CompletionCapability: Encodable {
    let dynamicRegistration: Bool
    let completionItem: CompletionItemCapability
}

struct CompletionItemCapability: Encodable {
    let snippetSupport: Bool
}

struct DiagnosticsCapability: Encodable {
    let relatedInformation: Bool
}

struct SemanticTokensCapability: Encodable {
    let dynamicRegistration: Bool
    let requests: SemanticTokenRequests
    let tokenTypes: [String]
    let tokenModifiers: [String]
    let formats: [String]
}

struct SemanticTokenRequests: Encodable {
    let range: Bool
    let full: FullSemanticTokenRequest
}

struct FullSemanticTokenRequest: Encodable {
    let delta: Bool
}

struct WorkspaceClientCapabilities: Encodable {
    let applyEdit: Bool
    let workspaceEdit: WorkspaceEditCapability
    let didChangeConfiguration: DynamicRegistrationCapability
    let didChangeWatchedFiles: DynamicRegistrationCapability
}

struct WorkspaceEditCapability: Encodable {
    let documentChanges: Bool
}

struct TextDocumentIdentifier: Encodable {
    let uri: String
}

struct TextDocumentPositionParams: Encodable {
    let textDocument: TextDocumentIdentifier
    let position: Position
}

struct Position: Encodable {
    let line: Int
    let character: Int
}

struct TextDocumentContentChangeEvent {
    let range: LSPRange?
    let text: String
}

struct LSPRange {
    let start: Position
    let end: Position
}

struct Location {
    let uri: String
    let range: LSPRange
    
    init?(from dict: [String: Any]) {
        guard let uri = dict["uri"] as? String,
              let rangeDict = dict["range"] as? [String: Any],
              let startDict = rangeDict["start"] as? [String: Int],
              let endDict = rangeDict["end"] as? [String: Int] else { return nil }
        
        self.uri = uri
        self.range = LSPRange(
            start: Position(line: startDict["line"] ?? 0, character: startDict["character"] ?? 0),
            end: Position(line: endDict["line"] ?? 0, character: endDict["character"] ?? 0)
        )
    }
}

struct CompletionItem {
    let label: String
    let kind: Int?
    let detail: String?
    let documentation: String?
    let insertText: String?
    
    init?(from dict: [String: Any]) {
        guard let label = dict["label"] as? String else { return nil }
        self.label = label
        self.kind = dict["kind"] as? Int
        self.detail = dict["detail"] as? String
        self.documentation = dict["documentation"] as? String
        self.insertText = dict["insertText"] as? String
    }
}

struct Hover {
    let contents: String
    let range: LSPRange?
    
    init?(from result: [String: Any]) {
        if let contentsDict = result["contents"] as? [String: Any],
           let value = contentsDict["value"] as? String {
            self.contents = value
        } else if let contents = result["contents"] as? String {
            self.contents = contents
        } else {
            return nil
        }
        self.range = nil
    }
}

struct SemanticTokens {
    let data: [Int]
    
    /// Decode tokens from the integer array
    /// Format: [deltaLine, deltaStartChar, length, tokenType, tokenModifiers, ...]
    func decodedTokens() -> [SemanticToken] {
        var tokens: [SemanticToken] = []
        var i = 0
        var currentLine = 0
        
        while i + 4 < data.count {
            let deltaLine = data[i]
            let deltaStart = data[i + 1]
            let length = data[i + 2]
            let tokenType = data[i + 3]
            let modifiers = data[i + 4]
            
            currentLine += deltaLine
            
            tokens.append(SemanticToken(
                line: currentLine,
                startChar: deltaStart,
                length: length,
                tokenType: tokenType,
                modifiers: modifiers
            ))
            
            i += 5
        }
        
        return tokens
    }
}

struct SemanticToken {
    let line: Int
    let startChar: Int
    let length: Int
    let tokenType: Int
    let modifiers: Int
}

// MARK: - Errors

enum LSPError: Error {
    case unsupportedLanguage(String)
    case serverNotRunning(String)
    case requestTimeout
    case parseError(String)
    
    var localizedDescription: String {
        switch self {
        case .unsupportedLanguage(let lang): return "Language '\(lang)' not supported by LSP"
        case .serverNotRunning(let lang): return "LSP server for '\(lang)' is not running"
        case .requestTimeout: return "LSP request timed out"
        case .parseError(let msg): return "LSP parse error: \(msg)"
        }
    }
}
