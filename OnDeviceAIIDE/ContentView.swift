// MARK: - Main Content View
// OnDeviceAIIDE/ContentView.swift
//
// Root container with multi-panel responsive layout:
// Collapsible sidebar (file tree), code editor, and AI assistant panel.

import SwiftUI

struct ContentView: View {
    @State private var selectedTab = 0
    @State private var sidebarVisible = true
    @State private var showingModelManager = false
    @State private var showingSettings = false
    
    var body: some View {
        TabView(selection: $selectedTab) {
            // Editor Tab
            EditorWorkspaceView()
                .tabItem {
                    Image(systemName: "square.and.pencil")
                    Text("Editor")
                }
                .tag(0)
            
            // Models Tab
            ModelBrowserView()
                .tabItem {
                    Image(systemName: "cpu")
                    Text("Models")
                }
                .tag(1)
            
            // Chat Tab
            ChatPanel()
                .tabItem {
                    Image(systemName: "bubble.left.and.bubble.right")
                    Text("AI Chat")
                }
                .tag(2)
            
            // Git Tab
            GitPanel()
                .tabItem {
                    Image(systemName: "arrow.triangle.branch")
                    Text("Git")
                }
                .tag(3)
            
            // Settings Tab
            SettingsView()
                .tabItem {
                    Image(systemName: "gear")
                    Text("Settings")
                }
                .tag(4)
        }
        .tint(.appCrimson)
        .background(Color.appBackground.ignoresSafeArea())
    }
}

// MARK: - Editor Workspace

struct EditorWorkspaceView: View {
    @State private var selectedFile: FileNode?
    @State private var openFiles: [FileNode] = []
    @State private var fileTree: FileNode?
    @State private var showingSidebar = true
    @State private var selectedProject: Project?
    
    var body: some View {
        HStack(spacing: 0) {
            // Sidebar (File Tree)
            if showingSidebar {
                FileBrowserPanel(
                    fileTree: fileTree,
                    selectedFile: $selectedFile,
                    onFileSelect: openFile(_:)
                )
                .frame(width: 280)
                .background(Color.appSurface)
                .overlay(
                    Rectangle()
                        .fill(Color.appDivider)
                        .frame(width: 0.5)
                        .edgesIgnoringSafeArea(.vertical),
                    alignment: .trailing
                )
            }
            
            // Editor Area
            VStack(spacing: 0) {
                // Tab bar
                if !openFiles.isEmpty {
                    EditorTabBar(
                        tabs: openFiles,
                        activeTab: $selectedFile,
                        onClose: closeFile(_:)
                    )
                    .background(Color.appSurface)
                }
                
                // Editor content
                if let file = selectedFile {
                    CodeEditorView(file: file)
                        .background(Color.appBackground)
                } else {
                    EmptyEditorView()
                }
                
                // Status bar
                StatusBar(
                    file: selectedFile,
                    project: selectedProject
                )
                .background(Color.appSurface)
            }
            .background(Color.appBackground)
        }
        .background(Color.appBackground)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button(action: { showingSidebar.toggle() }) {
                    Image(systemName: showingSidebar ? "sidebar.left" : "sidebar.left")
                        .foregroundColor(.appTextSecondary)
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                HStack(spacing: 16) {
                    Button(action: {}) {
                        Image(systemName: "play.fill")
                            .foregroundColor(.appCrimson)
                    }
                    Button(action: {}) {
                        Image(systemName: "square.grid.2x2")
                            .foregroundColor(.appTextSecondary)
                    }
                }
            }
        }
        .task {
            await loadProject()
        }
    }
    
    private func openFile(_ file: FileNode) {
        if !openFiles.contains(where: { $0.id == file.id }) {
            openFiles.append(file)
        }
        selectedFile = file
    }
    
    private func closeFile(_ file: FileNode) {
        openFiles.removeAll { $0.id == file.id }
        if selectedFile?.id == file.id {
            selectedFile = openFiles.last
        }
    }
    
    private func loadProject() async {
        // Load first available project or create default
        do {
            let projects = try await FileSystemManager.shared.listProjects()
            if let project = projects.first {
                selectedProject = project
                fileTree = try? await FileSystemManager.shared.buildFileTree(for: project)
            } else {
                // Create default project
                let project = try? await FileSystemManager.shared.createProject(name: "MyProject", template: .swift)
                selectedProject = project
                fileTree = try? await FileSystemManager.shared.buildFileTree(for: project!)
            }
        } catch {
            print("Failed to load project: \(error)")
        }
    }
}

// MARK: - Empty Editor State

struct EmptyEditorView: View {
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 60))
                .foregroundColor(.appTextMuted.opacity(0.5))
            
            Text("Open a file to start editing")
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(.appTextSecondary)
            
            HStack(spacing: 20) {
                ShortcutHint(key: "⌘", action: "O", description: "Open")
                ShortcutHint(key: "⌘", action: "N", description: "New File")
                ShortcutHint(key: "⌘", action: "P", description: "Palette")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.appBackground)
    }
}

struct ShortcutHint: View {
    let key: String
    let action: String
    let description: String
    
    var body: some View {
        HStack(spacing: 4) {
            Text(key)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.appTextMuted)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Color.appSurfaceHighlight)
                .cornerRadius(4)
            
            Text(action)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.appTextMuted)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Color.appSurfaceHighlight)
                .cornerRadius(4)
            
            Text(description)
                .font(.system(size: 12))
                .foregroundColor(.appTextMuted)
        }
    }
}

// MARK: - Status Bar

struct StatusBar: View {
    let file: FileNode?
    let project: Project?
    
    var body: some View {
        HStack(spacing: 16) {
            // Left section
            HStack(spacing: 12) {
                if let file = file {
                    Text(file.name)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.appTextSecondary)
                    
                    if let lang = file.languageIdentifier {
                        Text(lang.uppercased())
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.appCrimson)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.appCrimson.opacity(0.12))
                            .cornerRadius(3)
                    }
                }
            }
            
            Spacer()
            
            // Right section
            HStack(spacing: 12) {
                Text("On-Device AI IDE")
                    .font(.system(size: 11))
                    .foregroundColor(.appTextMuted)
                
                Circle()
                    .fill(Color.appSuccess)
                    .frame(width: 6, height: 6)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .overlay(
            Rectangle()
                .fill(Color.appDivider)
                .frame(height: 0.5),
            alignment: .top
        )
    }
}

// MARK: - Model Browser View

struct ModelBrowserView: View {
    @State private var showingModelManager = false
    
    var body: some View {
        NavigationStack {
            VStack {
                Image(systemName: "cpu")
                    .font(.system(size: 50))
                    .foregroundColor(.appCrimson.opacity(0.5))
                
                Text("Model Manager")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(.appTextPrimary)
                    .padding(.top, 12)
                
                Text("Download and manage on-device AI models")
                    .font(.system(size: 14))
                    .foregroundColor(.appTextSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
                    .padding(.top, 4)
                
                Button("Manage Models") {
                    showingModelManager = true
                }
                .crimsonButton(isProminent: true)
                .padding(.top, 24)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.appBackground)
            .navigationTitle("Models")
            .sheet(isPresented: $showingModelManager) {
                ModelManagerPanel()
            }
        }
        .preferredColorScheme(.dark)
    }
}

// MARK: - Settings View

struct SettingsView: View {
    @State private var temperature: Double = 0.7
    @State private var maxTokens: Double = 2048
    @State private var selectedAPIProvider = APIProvider.openAI
    @State private var apiKey = ""
    @State private var useLocalModel = true
    
    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text("Inference").foregroundColor(.appTextSecondary)) {
                    Toggle("Use On-Device Model", isOn: $useLocalModel)
                    
                    VStack(alignment: .leading) {
                        Text("Temperature: \(String(format: "%.1f", temperature))")
                            .font(.system(size: 14))
                        Slider(value: $temperature, in: 0...2, step: 0.1)
                            .tint(.appCrimson)
                    }
                    
                    VStack(alignment: .leading) {
                        Text("Max Tokens: \(Int(maxTokens))")
                            .font(.system(size: 14))
                        Slider(value: $maxTokens, in: 256...8192, step: 256)
                            .tint(.appCrimson)
                    }
                }
                
                Section(header: Text("Remote API").foregroundColor(.appTextSecondary)) {
                    Picker("Provider", selection: $selectedAPIProvider) {
                        ForEach(APIProvider.allCases, id: \.self) { provider in
                            Text(provider.rawValue).tag(provider)
                        }
                    }
                    
                    if selectedAPIProvider.requiresAPIKey {
                        SecureField("API Key", text: $apiKey)
                            .font(.system(.body, design: .monospaced))
                    }
                }
                
                Section(header: Text("About").foregroundColor(.appTextSecondary)) {
                    HStack {
                        Text("Version")
                        Spacer()
                        Text("1.0.0 (26)")
                            .foregroundColor(.appTextMuted)
                    }
                    
                    HStack {
                        Text("Device")
                        Spacer()
                        Text(UIDevice.current.model)
                            .foregroundColor(.appTextMuted)
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.large)
            .scrollContentBackground(.hidden)
            .background(Color.appBackground.ignoresSafeArea())
        }
        .preferredColorScheme(.dark)
    }
}
