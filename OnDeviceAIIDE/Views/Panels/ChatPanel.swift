// MARK: - AI Chat Panel
// OnDeviceAIIDE/Views/Panels/ChatPanel.swift
//
// Chat interface for AI interaction with on-device and remote models.
// Supports streaming responses, code blocks, and file context.

import SwiftUI

struct ChatPanel: View {
    @State private var messages: [ChatMessage] = []
    @State private var inputText = ""
    @State private var isGenerating = false
    @State private var selectedEngine = "On-Device"
    @State private var showingEnginePicker = false
    @State private var scrollToBottom = false
    @FocusState private var isInputFocused: Bool
    
    private let engines = ["On-Device", "OpenAI", "Anthropic", "Ollama"]
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            chatHeader
            
            // Messages
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(messages) { message in
                            ChatMessageBubble(message: message)
                                .id(message.id)
                        }
                        
                        // Typing indicator
                        if isGenerating {
                            TypingIndicator()
                                .id("typing")
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 16)
                }
                .onChange(of: messages.count) {
                    withAnimation {
                        proxy.scrollTo(messages.last?.id, anchor: .bottom)
                    }
                }
                .onChange(of: isGenerating) {
                    withAnimation {
                        proxy.scrollTo("typing", anchor: .bottom)
                    }
                }
            }
            .background(Color.appBackground)
            
            // Input area
            chatInput
        }
        .background(Color.appBackground)
    }
    
    private var chatHeader: some View {
        HStack {
            Text("AI Assistant")
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(.appTextPrimary)
            
            Spacer()
            
            // Engine selector
            Button(action: { showingEnginePicker = true }) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(selectedEngine == "On-Device" ? Color.appSuccess : Color.appCrimson)
                        .frame(width: 8, height: 8)
                    Text(selectedEngine)
                        .font(.system(size: 13, weight: .medium))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10))
                }
                .foregroundColor(.appTextSecondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.appSurfaceHighlight)
                .cornerRadius(6)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.appBorder, lineWidth: 0.5)
                )
            }
            
            // Clear button
            if !messages.isEmpty {
                Button(action: { messages.removeAll() }) {
                    Image(systemName: "trash")
                        .font(.system(size: 14))
                        .foregroundColor(.appTextMuted)
                }
                .padding(.leading, 8)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.appSurface)
        .overlay(
            Rectangle()
                .fill(Color.appDivider)
                .frame(height: 0.5),
            alignment: .bottom
        )
        .confirmationDialog("Select Engine", isPresented: $showingEnginePicker) {
            ForEach(engines, id: \.self) { engine in
                Button(engine) {
                    selectedEngine = engine
                }
            }
        }
    }
    
    private var chatInput: some View {
        VStack(spacing: 0) {
            Divider()
                .background(Color.appDivider)
            
            HStack(spacing: 12) {
                TextField("Ask about your code...", text: $inputText, axis: .vertical)
                    .font(.system(size: 15))
                    .foregroundColor(.appTextPrimary)
                    .focused($isInputFocused)
                    .lineLimit(1...5)
                    .padding(10)
                    .background(Color.appInputBackground)
                    .cornerRadius(8)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.appBorder, lineWidth: 0.5)
                    )
                
                Button(action: sendMessage) {
                    ZStack {
                        Circle()
                            .fill(inputText.isEmpty ? Color.appSurfaceHighlight : Color.appCrimson)
                            .frame(width: 38, height: 38)
                        
                        Image(systemName: isGenerating ? "stop.fill" : "arrow.up")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(inputText.isEmpty ? Color.appTextMuted : .white)
                    }
                }
                .disabled(inputText.isEmpty && !isGenerating)
            }
            .padding(12)
            .background(Color.appSurface)
        }
    }
    
    private func sendMessage() {
        if isGenerating {
            // Cancel generation
            isGenerating = false
            return
        }
        
        let userMessage = ChatMessage(
            id: UUID(),
            role: .user,
            content: inputText,
            timestamp: Date()
        )
        
        messages.append(userMessage)
        let query = inputText
        inputText = ""
        isGenerating = true
        
        // Generate response
        Task {
            let response = await generateResponse(for: query)
            await MainActor.run {
                let assistantMessage = ChatMessage(
                    id: UUID(),
                    role: .assistant,
                    content: response,
                    timestamp: Date()
                )
                messages.append(assistantMessage)
                isGenerating = false
            }
        }
    }
    
    private func generateResponse(for query: String) async -> String {
        // Check if RAG context is available
        if let ragResult = try? await generateRAGResponse(for: query) {
            return ragResult
        }
        
        // Fallback to direct model query
        return await queryOnDeviceModel(query)
    }
    
    private func generateRAGResponse(for query: String) async throws -> String {
        guard await RAGEngine.shared.isInitialized else {
            throw RagError.notInitialized
        }
        
        let contextPrompt = try await RAGEngine.shared.buildContextPrompt(query: query)
        return await queryOnDeviceModel(contextPrompt)
    }
    
    private func queryOnDeviceModel(_ prompt: String) async -> String {
        // Placeholder: In production, this routes to the active inference engine
        let sampleResponses = [
            "Based on your code context, I can see this is a Swift project with structured architecture. The `ModelConfigurationStore` uses Core Data for persistence and provides thread-safe access through Swift actors.",
            "I've analyzed the codebase. The `HuggingFaceDownloadManager` handles secure model downloads with resume capability, SHA-256 verification, and concurrent download limiting. It supports both regular files and Git LFS files.",
            "Looking at the file structure, you have a well-organized project with clear separation: Models for data, Services for business logic, Views for UI, and Utils for helpers. This follows clean architecture principles.",
        ]
        
        // Simulate streaming delay
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        return sampleResponses.randomElement() ?? "I'm analyzing your code..."
    }
}

// MARK: - Chat Message Bubble

struct ChatMessageBubble: View {
    let message: ChatMessage
    
    var body: some View {
        HStack {
            if message.role == .user {
                Spacer(minLength: 40)
            }
            
            VStack(alignment: .leading, spacing: 4) {
                Text(message.content)
                    .font(.system(size: 15))
                    .foregroundColor(message.role == .user ? .white : .appTextPrimary)
                    .padding(12)
                    .background(
                        message.role == .user
                        ? Color.appCrimson
                        : Color.appSurfaceHighlight
                    )
                    .cornerRadius(12)
                    .cornerRadius(message.role == .user ? 2 : 12, corners: .bottomTrailing)
                    .cornerRadius(message.role == .user ? 12 : 2, corners: .bottomLeading)
            }
            
            if message.role == .assistant {
                Spacer(minLength: 40)
            }
        }
    }
}

// MARK: - Typing Indicator

struct TypingIndicator: View {
    @State private var dotOffsets: [CGFloat] = [0, 0, 0]
    
    var body: some View {
        HStack {
            HStack(spacing: 4) {
                ForEach(0..<3) { i in
                    Circle()
                        .fill(Color.appTextMuted)
                        .frame(width: 6, height: 6)
                        .offset(y: dotOffsets[i])
                        .animation(
                            Animation.easeInOut(duration: 0.5)
                                .repeatForever(autoreverses: true)
                                .delay(Double(i) * 0.15),
                            value: dotOffsets[i]
                        )
                }
            }
            .padding(12)
            .background(Color.appSurfaceHighlight)
            .cornerRadius(12)
            
            Spacer()
        }
        .onAppear {
            dotOffsets = [-4, -4, -4]
            withAnimation {
                dotOffsets = [0, 0, 0]
            }
        }
    }
}

// MARK: - Corner Radius Helper

private extension View {
    func cornerRadius(_ radius: CGFloat, corners: UIRectCorner) -> some View {
        clipShape(RoundedCorner(radius: radius, corners: corners))
    }
}

private struct RoundedCorner: Shape {
    var radius: CGFloat = .infinity
    var corners: UIRectCorner = .allCorners
    
    func path(in rect: CGRect) -> Path {
        let path = UIBezierPath(
            roundedRect: rect,
            byRoundingCorners: corners,
            cornerRadii: CGSize(width: radius, height: radius)
        )
        return Path(path.cgPath)
    }
}
