// MARK: - Model Manager Panel
// OnDeviceAIIDE/Views/Panels/ModelManagerPanel.swift
//
// UI for managing downloaded AI models, HuggingFace downloads,
// and model configuration. Follows the charcoal/crimson design system.

import SwiftUI

struct ModelManagerPanel: View {
    @State private var models: [AIModelDTO] = []
    @State private var searchQuery = ""
    @State private var isAddingModel = false
    @State private var newModelID = ""
    @State private var downloadStates: [UUID: ModelDownloadState] = [:]
    @State private var selectedModel: AIModelDTO?
    @State private var showingDeleteConfirm = false
    
    @Environment(\.dismiss) private var dismiss
    
    private var filteredModels: [AIModelDTO] {
        if searchQuery.isEmpty { return models }
        return models.filter {
            $0.name.localizedCaseInsensitiveContains(searchQuery) ||
            $0.modelID.localizedCaseInsensitiveContains(searchQuery)
        }
    }
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Search bar
                searchBar
                
                // Model list
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(filteredModels) { model in
                            ModelCard(
                                model: model,
                                downloadState: downloadStates[model.id],
                                isSelected: selectedModel?.id == model.id,
                                onSelect: { selectedModel = model },
                                onDelete: { showingDeleteConfirm = true },
                                onSetActive: { setActiveModel(model) }
                            )
                        }
                    }
                    .padding(12)
                }
                .background(Color.appBackground)
            }
            .navigationTitle("Models")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Done") { dismiss() }
                        .foregroundColor(.appTextPrimary)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: { isAddingModel = true }) {
                        Image(systemName: "plus")
                            .foregroundColor(.appCrimson)
                    }
                }
            }
            .sheet(isPresented: $isAddingModel) {
                AddModelSheet { modelID, format, quantization in
                    Task {
                        await downloadModel(modelID: modelID, format: format, quantization: quantization)
                    }
                }
            }
            .task {
                await loadModels()
            }
        }
        .preferredColorScheme(.dark)
    }
    
    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.appTextMuted)
            TextField("Search models...", text: $searchQuery)
                .foregroundColor(.appTextPrimary)
                .font(.system(size: 14))
            if !searchQuery.isEmpty {
                Button(action: { searchQuery = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.appTextMuted)
                }
            }
        }
        .padding(10)
        .background(Color.appInputBackground)
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.appBorder, lineWidth: 0.5)
        )
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.appSurface)
    }
    
    private func loadModels() async {
        do {
            models = try await ModelConfigurationStore.shared.fetchAllModels()
        } catch {
            print("Failed to load models: \(error)")
        }
    }
    
    private func downloadModel(modelID: String, format: ModelFormat, quantization: QuantizationLevel?) async {
        isAddingModel = false
        
        do {
            let store = ModelConfigurationStore.shared
            let dto = try await store.createModel(
                modelID: modelID,
                name: modelID.components(separatedBy: "/").last ?? modelID,
                format: format,
                quantization: quantization
            )
            
            // Start download
            let taskID = try await HuggingFaceDownloadManager.shared.downloadModel(
                modelID: modelID,
                format: format,
                quantization: quantization
            )
            
            // Track download progress
            Task {
                while true {
                    guard let state = await HuggingFaceDownloadManager.shared.state(for: taskID) else { break }
                    await MainActor.run {
                        downloadStates[dto.id] = state
                    }
                    if case .completed = state {
                        _ = try? await store.updateDownloadProgress(id: dto.id, progress: 1.0)
                        break
                    }
                    if case .failed = state {
                        break
                    }
                    try? await Task.sleep(nanoseconds: 500_000_000)
                }
            }
            
            await loadModels()
        } catch {
            print("Download failed: \(error)")
        }
    }
    
    private func setActiveModel(_ model: AIModelDTO) {
        Task {
            try? await ModelConfigurationStore.shared.setActiveModel(id: model.id)
        }
    }
}

// MARK: - Model Card

struct ModelCard: View {
    let model: AIModelDTO
    let downloadState: ModelDownloadState?
    let isSelected: Bool
    let onSelect: () -> Void
    let onDelete: () -> Void
    let onSetActive: () -> Void
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                // Format icon
                formatIcon
                
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.name)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.appTextPrimary)
                        .lineLimit(1)
                    
                    Text(model.modelID)
                        .font(.system(size: 12, weight: .regular))
                        .foregroundColor(.appTextSecondary)
                        .lineLimit(1)
                    
                    // Tags row
                    HStack(spacing: 6) {
                        FormatTag(text: model.format.rawValue)
                        if let quant = model.quantization {
                            FormatTag(text: quant.rawValue)
                        }
                        if let params = model.parameters {
                            FormatTag(text: params)
                        }
                        if model.isDownloaded {
                            FormatTag(text: "Ready", isSuccess: true)
                        }
                    }
                }
                
                Spacer()
                
                // Status indicator
                statusIndicator
            }
            
            // Download progress
            if let state = downloadState, state.isActive {
                ProgressView(value: state.progress)
                    .tint(Color.appCrimson)
                    .padding(.top, 8)
                
                HStack {
                    Text(downloadStatusText(state))
                        .font(.system(size: 11))
                        .foregroundColor(.appTextMuted)
                    Spacer()
                    Text("\(Int(state.progress * 100))%")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.appCrimson)
                }
                .padding(.top, 4)
            }
        }
        .padding(12)
        .background(
            isSelected ? Color.appSurfaceActive : Color.appSurface
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(
                    isSelected ? Color.appCrimson.opacity(0.4) : Color.appBorder,
                    lineWidth: isSelected ? 1 : 0.5
                )
        )
        .cornerRadius(8)
        .contentShape(Rectangle())
        .onTapGesture { onSelect() }
        .contextMenu {
            if model.isDownloaded {
                Button(action: onSetActive) {
                    Label("Set as Active", systemImage: "checkmark.circle")
                }
            }
            Button(role: .destructive, action: onDelete) {
                Label("Delete", systemImage: "trash")
            }
        }
    }
    
    private var formatIcon: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(model.format == .mlx ? Color.appCrimson.opacity(0.15) : Color.appSurfaceHighlight)
                .frame(width: 44, height: 44)
            
            Text(formatAbbreviation)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundColor(model.format == .mlx ? .appCrimson : .appTextSecondary)
        }
    }
    
    private var formatAbbreviation: String {
        switch model.format {
        case .gguf: return "GGUF"
        case .mlx: return "MLX"
        case .coreml: return "CML"
        }
    }
    
    private var statusIndicator: some View {
        Group {
            if model.isDownloaded {
                if model.isDefault {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.appCrimson)
                        .font(.system(size: 18))
                } else {
                    Circle()
                        .fill(Color.appSuccess)
                        .frame(width: 10, height: 10)
                }
            } else {
                Image(systemName: "arrow.down.circle")
                    .foregroundColor(.appTextMuted)
                    .font(.system(size: 18))
            }
        }
    }
    
    private func downloadStatusText(_ state: ModelDownloadState) -> String {
        switch state {
        case .resolving: return "Resolving files..."
        case .downloading(_, let bytes, let total):
            let downloaded = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
            let full = ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
            return "\(downloaded) / \(full)"
        case .verifying: return "Verifying..."
        case .failed(let error): return "Failed: \(error.localizedDescription)"
        default: return ""
        }
    }
}

// MARK: - Format Tag

struct FormatTag: View {
    let text: String
    var isSuccess = false
    
    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .foregroundColor(isSuccess ? Color.appSuccess : .appTextMuted)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                (isSuccess ? Color.appSuccess : Color.appTextMuted).opacity(0.12)
            )
            .cornerRadius(4)
    }
}

// MARK: - Add Model Sheet

struct AddModelSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onAdd: (String, ModelFormat, QuantizationLevel?) -> Void
    
    @State private var modelID = ""
    @State private var selectedFormat: ModelFormat = .gguf
    @State private var selectedQuant: QuantizationLevel = .q4_0
    @State private var useCustomURL = false
    @State private var customURL = ""
    
    private let suggestedModels = [
        "microsoft/Phi-3-mini-4k-instruct",
        "Qwen/Qwen2.5-0.5B-Instruct",
        "TinyLlama/TinyLlama-1.1B-Chat-v1.0",
        "mlx-community/Llama-3.2-1B-Instruct-4bit",
        "mlx-community/Phi-3-mini-4k-instruct-4bit",
    ]
    
    var body: some View {
        NavigationStack {
            Form {
                Section("Model Source") {
                    if useCustomURL {
                        TextField("HuggingFace Repo URL", text: $customURL)
                            .font(.system(.body, design: .monospaced))
                    } else {
                        TextField("Model ID (e.g., owner/model)", text: $modelID)
                            .font(.system(.body, design: .monospaced))
                    }
                    
                    Toggle("Use Custom URL", isOn: $useCustomURL)
                }
                
                Section("Format") {
                    Picker("Model Format", selection: $selectedFormat) {
                        ForEach(ModelFormat.allCases, id: \.self) { format in
                            Text(format.rawValue).tag(format)
                        }
                    }
                    .pickerStyle(.segmented)
                }
                
                if selectedFormat == .gguf {
                    Section("Quantization") {
                        Picker("Quantization", selection: $selectedQuant) {
                            ForEach(QuantizationLevel.allCases, id: \.self) { level in
                                Text("\(level.rawValue) (Quality: \(level.qualityScore)/10)").tag(level)
                            }
                        }
                    }
                }
                
                Section("Suggested Models") {
                    ForEach(suggestedModels, id: \.self) { model in
                        Button(action: {
                            modelID = model
                        }) {
                            HStack {
                                Text(model)
                                    .font(.system(.callout, design: .monospaced))
                                    .foregroundColor(.appTextPrimary)
                                Spacer()
                                if modelID == model {
                                    Image(systemName: "checkmark")
                                        .foregroundColor(.appCrimson)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Download Model")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                        .foregroundColor(.appTextSecondary)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Download") {
                        let id = useCustomURL ? customURL : modelID
                        onAdd(id, selectedFormat, selectedFormat == .gguf ? selectedQuant : nil)
                        dismiss()
                    }
                    .foregroundColor(.appCrimson)
                    .fontWeight(.semibold)
                    .disabled(modelID.isEmpty && customURL.isEmpty)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.appBackground)
        }
        .preferredColorScheme(.dark)
    }
}
