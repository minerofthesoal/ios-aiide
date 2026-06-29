// MARK: - API Client Infrastructure
// OnDeviceAIIDE/Services/API/GenericAPIClient.swift
//
// Unified API client protocol and implementations for all remote providers:
// OpenAI, Anthropic, Ollama, LM Studio, and generic REST endpoints.

import Foundation

// MARK: - Protocol

/// Protocol for all API client implementations
protocol APIClientProtocol: Sendable {
    /// Send a health check / availability ping
    func healthCheck() async throws -> Bool
    /// Stream completion from the API
    func streamCompletion(prompt: String, options: GenerationOptions) async throws -> AsyncStream<TokenOutput>
    /// Non-streaming completion
    func completion(prompt: String, options: GenerationOptions) async throws -> String
    /// Cancel ongoing request
    func cancel() async
    /// Get available models from this endpoint
    func listModels() async throws -> [String]
}

// MARK: - API Provider Configuration

enum APIProvider: String, CaseIterable, Codable, Sendable, Identifiable {
    case openAI = "OpenAI"
    case anthropic = "Anthropic"
    case ollama = "Ollama"
    case lmStudio = "LM Studio"
    case generic = "Custom REST API"
    
    var id: String { rawValue }
    
    var defaultEndpoint: String {
        switch self {
        case .openAI: return "https://api.openai.com/v1"
        case .anthropic: return "https://api.anthropic.com/v1"
        case .ollama: return "http://localhost:11434"
        case .lmStudio: return "http://localhost:1234/v1"
        case .generic: return ""
        }
    }
    
    var requiresAPIKey: Bool {
        switch self {
        case .openAI, .anthropic: return true
        case .ollama, .lmStudio, .generic: return false
        }
    }
    
    var apiKeyName: String {
        switch self {
        case .openAI: return "OpenAI API Key"
        case .anthropic: return "Anthropic API Key"
        case .ollama: return ""
        case .lmStudio: return ""
        case .generic: return "API Key (Optional)"
        }
    }
    
    var defaultModel: String {
        switch self {
        case .openAI: return "gpt-4o-mini"
        case .anthropic: return "claude-3-haiku-20240307"
        case .ollama: return "llama3"
        case .lmStudio: return "local-model"
        case .generic: return ""
        }
    }
    
    func createClient(endpoint: String? = nil, apiKey: String? = nil, model: String? = nil) -> any APIClientProtocol {
        switch self {
        case .openAI:
            return OpenAIClient(endpoint: endpoint ?? defaultEndpoint, apiKey: apiKey ?? "", model: model ?? defaultModel)
        case .anthropic:
            return AnthropicClient(endpoint: endpoint ?? defaultEndpoint, apiKey: apiKey ?? "", model: model ?? defaultModel)
        case .ollama:
            return OllamaClient(endpoint: endpoint ?? defaultEndpoint, model: model ?? defaultModel)
        case .lmStudio:
            return LMStudioClient(endpoint: endpoint ?? defaultEndpoint, model: model ?? defaultModel)
        case .generic:
            return GenericAPIClient(endpoint: endpoint ?? "", apiKey: apiKey, model: model)
        }
    }
}

// MARK: - OpenAI Client

actor OpenAIClient: APIClientProtocol {
    
    private let endpoint: String
    private let apiKey: String
    private let model: String
    private var currentTask: URLSessionDataTask?
    
    init(endpoint: String, apiKey: String, model: String) {
        self.endpoint = endpoint
        self.apiKey = apiKey
        self.model = model
    }
    
    func healthCheck() async throws -> Bool {
        let request = try makeRequest(path: "/models")
        let (_, response) = try await URLSession.shared.data(for: request)
        return (response as? HTTPURLResponse)?.statusCode == 200
    }
    
    func streamCompletion(prompt: String, options: GenerationOptions) async throws -> AsyncStream<TokenOutput> {
        return AsyncStream { continuation in
            Task {
                do {
                    let request = try self.makeChatRequest(prompt: prompt, options: options, stream: true)
                    
                    let (bytes, _) = try await URLSession.shared.bytes(for: request)
                    
                    var tokenIndex = 0
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data: ") else { continue }
                        let data = String(line.dropFirst(6))
                        
                        if data == "[DONE]" {
                            continuation.yield(TokenOutput(text: "", tokenId: tokenIndex, isComplete: true, metadata: nil))
                            break
                        }
                        
                        if let jsonData = data.data(using: .utf8),
                           let chunk = try? JSONDecoder().decode(OpenAIStreamChunk.self, from: jsonData) {
                            if let content = chunk.choices.first?.delta.content {
                                continuation.yield(TokenOutput(
                                    text: content,
                                    tokenId: tokenIndex,
                                    isComplete: false,
                                    metadata: nil
                                ))
                                tokenIndex += 1
                            }
                        }
                    }
                    
                    continuation.finish()
                } catch {
                    continuation.finish()
                }
            }
        }
    }
    
    func completion(prompt: String, options: GenerationOptions) async throws -> String {
        let request = try makeChatRequest(prompt: prompt, options: options, stream: false)
        let (data, _) = try await URLSession.shared.data(for: request)
        let response = try JSONDecoder().decode(OpenAICompletionResponse.self, from: data)
        return response.choices.first?.message.content ?? ""
    }
    
    func cancel() async {
        currentTask?.cancel()
        currentTask = nil
    }
    
    func listModels() async throws -> [String] {
        let request = try makeRequest(path: "/models")
        let (data, _) = try await URLSession.shared.data(for: request)
        let response = try JSONDecoder().decode(OpenAIModelsResponse.self, from: data)
        return response.data.map { $0.id }
    }
    
    // MARK: - Private
    
    private func makeRequest(path: String) throws -> URLRequest {
        guard let url = URL(string: endpoint + path) else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }
    
    private func makeChatRequest(prompt: String, options: GenerationOptions, stream: Bool) throws -> URLRequest {
        guard let url = URL(string: endpoint + "/chat/completions") else {
            throw URLError(.badURL)
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        var messages: [[String: String]] = []
        if let system = options.systemPrompt {
            messages.append(["role": "system", "content": system])
        }
        messages.append(["role": "user", "content": prompt])
        
        let body: [String: Any] = [
            "model": model,
            "messages": messages,
            "temperature": options.temperature ?? 0.7,
            "max_tokens": options.maxTokens ?? 2048,
            "top_p": options.topP ?? 0.9,
            "stream": stream
        ]
        
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }
}

// MARK: - Anthropic Client

actor AnthropicClient: APIClientProtocol {
    
    private let endpoint: String
    private let apiKey: String
    private let model: String
    
    init(endpoint: String, apiKey: String, model: String) {
        self.endpoint = endpoint
        self.apiKey = apiKey
        self.model = model
    }
    
    func healthCheck() async throws -> Bool {
        var request = URLRequest(url: URL(string: endpoint + "/models")!)
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        let (_, response) = try await URLSession.shared.data(for: request)
        return (response as? HTTPURLResponse)?.statusCode == 200
    }
    
    func streamCompletion(prompt: String, options: GenerationOptions) async throws -> AsyncStream<TokenOutput> {
        return AsyncStream { continuation in
            Task {
                do {
                    var request = URLRequest(url: URL(string: self.endpoint + "/messages")!)
                    request.httpMethod = "POST"
                    request.setValue(self.apiKey, forHTTPHeaderField: "x-api-key")
                    request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    
                    var messages: [[String: String]] = []
                    if let system = options.systemPrompt {
                        // Anthropic handles system separately
                    }
                    messages.append(["role": "user", "content": prompt])
                    
                    let body: [String: Any] = [
                        "model": self.model,
                        "max_tokens": options.maxTokens ?? 4096,
                        "temperature": options.temperature ?? 0.7,
                        "messages": messages,
                        "stream": true
                    ]
                    request.httpBody = try JSONSerialization.data(withJSONObject: body)
                    
                    let (bytes, _) = try await URLSession.shared.bytes(for: request)
                    
                    var tokenIndex = 0
                    for try await line in bytes.lines {
                        if line.hasPrefix("data: "),
                           let jsonData = line.dropFirst(6).data(using: .utf8),
                           let chunk = try? JSONDecoder().decode(AnthropicStreamChunk.self, from: jsonData) {
                            if let text = chunk.delta?.text {
                                continuation.yield(TokenOutput(
                                    text: text,
                                    tokenId: tokenIndex,
                                    isComplete: chunk.type == "message_stop",
                                    metadata: nil
                                ))
                                tokenIndex += 1
                            }
                            if chunk.type == "message_stop" {
                                break
                            }
                        }
                    }
                    
                    continuation.finish()
                } catch {
                    continuation.finish()
                }
            }
        }
    }
    
    func completion(prompt: String, options: GenerationOptions) async throws -> String {
        var request = URLRequest(url: URL(string: endpoint + "/messages")!)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let body: [String: Any] = [
            "model": model,
            "max_tokens": options.maxTokens ?? 4096,
            "temperature": options.temperature ?? 0.7,
            "messages": [["role": "user", "content": prompt]]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        let (data, _) = try await URLSession.shared.data(for: request)
        let response = try JSONDecoder().decode(AnthropicMessageResponse.self, from: data)
        return response.content.first?.text ?? ""
    }
    
    func cancel() async {}
    
    func listModels() async throws -> [String] {
        return [model]
    }
}

// MARK: - Ollama Client

actor OllamaClient: APIClientProtocol {
    
    private let endpoint: String
    private let model: String
    
    init(endpoint: String, model: String) {
        self.endpoint = endpoint
        self.model = model
    }
    
    func healthCheck() async throws -> Bool {
        let request = URLRequest(url: URL(string: endpoint + "/api/tags")!)
        let (_, response) = try await URLSession.shared.data(for: request)
        return (response as? HTTPURLResponse)?.statusCode == 200
    }
    
    func streamCompletion(prompt: String, options: GenerationOptions) async throws -> AsyncStream<TokenOutput> {
        return AsyncStream { continuation in
            Task {
                do {
                    var request = URLRequest(url: URL(string: self.endpoint + "/api/generate")!)
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    
                    let body: [String: Any] = [
                        "model": self.model,
                        "prompt": prompt,
                        "stream": true,
                        "options": [
                            "temperature": options.temperature ?? 0.7,
                            "num_predict": options.maxTokens ?? 2048
                        ]
                    ]
                    request.httpBody = try JSONSerialization.data(withJSONObject: body)
                    
                    let (bytes, _) = try await URLSession.shared.bytes(for: request)
                    
                    var tokenIndex = 0
                    for try await line in bytes.lines {
                        if let data = line.data(using: .utf8),
                           let chunk = try? JSONDecoder().decode(OllamaGenerateChunk.self, from: data) {
                            continuation.yield(TokenOutput(
                                text: chunk.response,
                                tokenId: tokenIndex,
                                isComplete: chunk.done,
                                metadata: nil
                            ))
                            tokenIndex += 1
                            if chunk.done { break }
                        }
                    }
                    
                    continuation.finish()
                } catch {
                    continuation.finish()
                }
            }
        }
    }
    
    func completion(prompt: String, options: GenerationOptions) async throws -> String {
        var request = URLRequest(url: URL(string: endpoint + "/api/generate")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let body: [String: Any] = [
            "model": model,
            "prompt": prompt,
            "stream": false,
            "options": ["temperature": options.temperature ?? 0.7]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        let (data, _) = try await URLSession.shared.data(for: request)
        let response = try JSONDecoder().decode(OllamaGenerateResponse.self, from: data)
        return response.response
    }
    
    func cancel() async {}
    
    func listModels() async throws -> [String] {
        let request = URLRequest(url: URL(string: endpoint + "/api/tags")!)
        let (data, _) = try await URLSession.shared.data(for: request)
        let response = try JSONDecoder().decode(OllamaTagsResponse.self, from: data)
        return response.models.map { $0.name }
    }
}

// MARK: - LM Studio Client

actor LMStudioClient: APIClientProtocol {
    
    private let endpoint: String
    private let model: String
    
    init(endpoint: String, model: String) {
        self.endpoint = endpoint
        self.model = model
    }
    
    func healthCheck() async throws -> Bool {
        let (_, response) = try await URLSession.shared.data(from: URL(string: endpoint + "/models")!)
        return (response as? HTTPURLResponse)?.statusCode == 200
    }
    
    func streamCompletion(prompt: String, options: GenerationOptions) async throws -> AsyncStream<TokenOutput> {
        // LM Studio uses OpenAI-compatible API
        var request = URLRequest(url: URL(string: endpoint + "/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let body: [String: Any] = [
            "model": model,
            "messages": [["role": "user", "content": prompt]],
            "temperature": options.temperature ?? 0.7,
            "max_tokens": options.maxTokens ?? 2048,
            "stream": true
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        return AsyncStream { continuation in
            Task {
                do {
                    let (bytes, _) = try await URLSession.shared.bytes(for: request)
                    var tokenIndex = 0
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data: ") else { continue }
                        let dataStr = String(line.dropFirst(6))
                        if dataStr == "[DONE]" { break }
                        if let jsonData = dataStr.data(using: .utf8),
                           let chunk = try? JSONDecoder().decode(OpenAIStreamChunk.self, from: jsonData),
                           let content = chunk.choices.first?.delta.content {
                            continuation.yield(TokenOutput(text: content, tokenId: tokenIndex, isComplete: false, metadata: nil))
                            tokenIndex += 1
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish()
                }
            }
        }
    }
    
    func completion(prompt: String, options: GenerationOptions) async throws -> String {
        var request = URLRequest(url: URL(string: endpoint + "/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let body: [String: Any] = [
            "model": model,
            "messages": [["role": "user", "content": prompt]],
            "temperature": options.temperature ?? 0.7,
            "stream": false
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        let (data, _) = try await URLSession.shared.data(for: request)
        let response = try JSONDecoder().decode(OpenAICompletionResponse.self, from: data)
        return response.choices.first?.message.content ?? ""
    }
    
    func cancel() async {}
    
    func listModels() async throws -> [String] {
        let (data, _) = try await URLSession.shared.data(from: URL(string: endpoint + "/models")!)
        let response = try JSONDecoder().decode(OpenAIModelsResponse.self, from: data)
        return response.data.map { $0.id }
    }
}

// MARK: - Generic REST API Client

actor GenericAPIClient: APIClientProtocol {
    
    private let endpoint: String
    private let apiKey: String?
    private let model: String?
    
    init(endpoint: String, apiKey: String?, model: String?) {
        self.endpoint = endpoint
        self.apiKey = apiKey
        self.model = model
    }
    
    func healthCheck() async throws -> Bool {
        guard let url = URL(string: endpoint) else { return false }
        let (_, response) = try await URLSession.shared.data(from: url)
        return (response as? HTTPURLResponse) != nil
    }
    
    func streamCompletion(prompt: String, options: GenerationOptions) async throws -> AsyncStream<TokenOutput> {
        // Generic implementation assumes OpenAI-compatible streaming format
        // Users can customize via configuration
        return AsyncStream { continuation in
            Task {
                do {
                    guard let url = URL(string: self.endpoint) else {
                        continuation.finish()
                        return
                    }
                    
                    var request = URLRequest(url: url)
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    if let key = self.apiKey {
                        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
                    }
                    
                    let body: [String: Any] = [
                        "prompt": prompt,
                        "temperature": options.temperature ?? 0.7,
                        "max_tokens": options.maxTokens ?? 2048,
                        "stream": true
                    ]
                    request.httpBody = try JSONSerialization.data(withJSONObject: body)
                    
                    let (bytes, _) = try await URLSession.shared.bytes(for: request)
                    var tokenIndex = 0
                    for try await line in bytes.lines {
                        continuation.yield(TokenOutput(text: line, tokenId: tokenIndex, isComplete: false, metadata: nil))
                        tokenIndex += 1
                    }
                    continuation.finish()
                } catch {
                    continuation.finish()
                }
            }
        }
    }
    
    func completion(prompt: String, options: GenerationOptions) async throws -> String {
        guard let url = URL(string: endpoint) else { return "" }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let key = apiKey {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        
        let body: [String: Any] = [
            "prompt": prompt,
            "temperature": options.temperature ?? 0.7,
            "max_tokens": options.maxTokens ?? 2048
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        let (data, _) = try await URLSession.shared.data(for: request)
        return String(data: data, encoding: .utf8) ?? ""
    }
    
    func cancel() async {}
    
    func listModels() async throws -> [String] {
        return model.map { [$0] } ?? []
    }
}

// MARK: - API Response Models

private struct OpenAIStreamChunk: Decodable {
    struct Choice: Decodable {
        struct Delta: Decodable {
            let content: String?
            let role: String?
        }
        let delta: Delta
        let index: Int
        let finish_reason: String?
    }
    let choices: [Choice]
    let model: String
}

private struct OpenAICompletionResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable {
            let role: String
            let content: String
        }
        let message: Message
    }
    let choices: [Choice]
}

private struct OpenAIModelsResponse: Decodable {
    struct ModelEntry: Decodable {
        let id: String
    }
    let data: [ModelEntry]
}

private struct AnthropicStreamChunk: Decodable {
    struct Delta: Decodable {
        let text: String?
        let stop_reason: String?
    }
    let type: String
    let delta: Delta?
}

private struct AnthropicMessageResponse: Decodable {
    struct ContentBlock: Decodable {
        let type: String
        let text: String
    }
    let content: [ContentBlock]
}

private struct OllamaGenerateChunk: Decodable {
    let response: String
    let done: Bool
}

private struct OllamaGenerateResponse: Decodable {
    let response: String
}

private struct OllamaTagsResponse: Decodable {
    struct ModelEntry: Decodable {
        let name: String
    }
    let models: [ModelEntry]
}
