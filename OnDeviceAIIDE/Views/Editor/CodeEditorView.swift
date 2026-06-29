// MARK: - Code Editor View
// OnDeviceAIIDE/Views/Editor/CodeEditorView.swift
//
// Syntax-highlighting code editor with line numbers and LSP integration.

import SwiftUI
import UIKit

struct CodeEditorView: View {
    let file: FileNode
    @State private var content: String = ""
    @State private var cursorPosition = (line: 1, column: 1)
    @State private var isDirty = false
    @FocusState private var isFocused: Bool
    
    var body: some View {
        HStack(spacing: 0) {
            // Line numbers
            LineNumberView(
                text: content,
                cursorLine: cursorPosition.line
            )
            .frame(width: 50)
            .background(Color.appBackground)
            
            // Editor
            TextEditor(text: $content)
                .font(Font.custom("SFMono-Regular", size: 14))
                .foregroundColor(.appTextPrimary)
                .scrollContentBackground(.hidden)
                .background(Color.appBackground)
                .focused($isFocused)
                .onChange(of: content) { _ in
                    isDirty = true
                    updateCursorPosition()
                }
                .task {
                    await loadContent()
                }
                .onTapGesture {
                    updateCursorPosition()
                }
        }
        .background(Color.appBackground)
        .overlay(
            Rectangle()
                .fill(Color.appDivider)
                .frame(width: 0.5)
                .padding(.leading, 50),
            alignment: .leading
        )
    }
    
    private func loadContent() async {
        // In production, load from FileSystemManager
        // content = try? await FileSystemManager.shared.readFile(...)
        
        // Placeholder content based on file type
        content = generatePlaceholderContent()
    }
    
    private func updateCursorPosition() {
        // Would calculate actual cursor position from UITextView
    }
    
    private func generatePlaceholderContent() -> String {
        // Sample content showing the project's own architecture
        """
        // MARK: - Hugging Face Download Manager
        // OnDeviceAIIDE/Services/ML/HuggingFaceDownloadManager.swift
        //
        // Secure, cached model downloading from Hugging Face Hub.
        
        import Foundation
        import CryptoKit
        
        /// Manages downloading AI models from Hugging Face Hub
        actor HuggingFaceDownloadManager {
            
            static let shared = HuggingFaceDownloadManager()
            
            private let maxConcurrentDownloads = 3
            private let maxRetryAttempts = 3
            private let downloadChunkSize = 8 * 1024 * 1024
            
            private let logger = Logger(
                subsystem: "com.ondeviceaiide",
                category: "HFDownloadManager"
            )
            
            // Active download tasks keyed by task ID
            private var activeTasks: [UUID: ModelDownloadTask] = [:]
            
            /// Resolve and list available files in a HF repository
            func resolveRepository(
                modelID: String,
                repoURL: String? = nil
            ) async throws -> [HFFileEntry] {
                // Implementation...
                return []
            }
            
            /// Start downloading a model
            func downloadModel(
                modelID: String,
                format: ModelFormat,
                files: [HFFileEntry]? = nil,
                quantization: QuantizationLevel? = nil
            ) async throws -> UUID {
                // Implementation...
                return UUID()
            }
        }
        
        // MARK: - Model Configuration Store
        
        actor ModelConfigurationStore {
            
            static let shared = ModelConfigurationStore()
            
            private let persistence: CoreDataStack
            private var modelCache: [UUID: AIModelDTO] = [:]
            
            /// Create and persist a new model configuration
            func createModel(
                modelID: String,
                name: String,
                format: ModelFormat
            ) async throws -> AIModelDTO {
                // Implementation...
                return AIModelDTO(modelID: modelID, name: name)
            }
        }
        """
    }
}

// MARK: - Line Number View

struct LineNumberView: View {
    let text: String
    let cursorLine: Int
    
    private var lineCount: Int {
        text.components(separatedBy: .newlines).count
    }
    
    var body: some View {
        ScrollView(showsIndicators: false) {
            LazyVStack(alignment: .trailing, spacing: 0) {
                ForEach(1...max(lineCount, 1), id: \.self) { line in
                    Text("\(line)")
                        .font(Font.custom("SFMono-Regular", size: 14))
                        .foregroundColor(line == cursorLine ? .appCrimson : .appTextMuted)
                        .frame(height: 22, alignment: .center)
                        .padding(.horizontal, 8)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .background(
                            line == cursorLine
                            ? Color.appCrimson.opacity(0.08)
                            : Color.clear
                        )
                }
            }
        }
    }
}

// MARK: - Editor Tab Bar

struct EditorTabBar: View {
    let tabs: [FileNode]
    @Binding var activeTab: FileNode?
    let onClose: (FileNode) -> Void
    
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(tabs) { file in
                    EditorTab(
                        file: file,
                        isActive: activeTab?.id == file.id,
                        onSelect: { activeTab = file },
                        onClose: { onClose(file) }
                    )
                }
            }
            .padding(.horizontal, 4)
        }
        .frame(height: 36)
        .background(Color.appSurface)
        .overlay(
            Rectangle()
                .fill(Color.appDivider)
                .frame(height: 0.5),
            alignment: .bottom
        )
    }
}

// MARK: - Editor Tab

struct EditorTab: View {
    let file: FileNode
    let isActive: Bool
    let onSelect: () -> Void
    let onClose: () -> Void
    
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: file.iconName)
                .font(.system(size: 12))
                .foregroundColor(fileIconColor)
            
            Text(file.name)
                .font(.system(size: 12, weight: isActive ? .medium : .regular))
                .foregroundColor(isActive ? .appTextPrimary : .appTextSecondary)
                .lineLimit(1)
            
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.appTextMuted)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(isActive ? Color.appSurfaceActive : Color.clear)
        .overlay(
            Rectangle()
                .fill(isActive ? Color.appCrimson : Color.clear)
                .frame(height: 2),
            alignment: .bottom
        )
        .onTapGesture { onSelect() }
    }
    
    private var fileIconColor: Color {
        switch file.fileExtension?.lowercased() {
        case "swift": return Color(hex: "C7455C")
        case "py": return Color(hex: "7D9A6D")
        case "js", "ts": return Color(hex: "B89A6A")
        case "json": return Color(hex: "9A7DB5")
        default: return .appTextMuted
        }
    }
}
