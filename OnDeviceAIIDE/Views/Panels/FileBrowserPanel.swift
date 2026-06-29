// MARK: - File Browser Panel
// OnDeviceAIIDE/Views/Panels/FileBrowserPanel.swift
//
// Collapsible sidebar for project file tree navigation.

import SwiftUI

struct FileBrowserPanel: View {
    let fileTree: FileNode?
    @Binding var selectedFile: FileNode?
    let onFileSelect: (FileNode) -> Void
    
    @State private var expandedDirectories: Set<String> = [""]
    @State private var showingAddMenu = false
    @State private var newFileName = ""
    @State private var isCreatingFile = false
    @State private var createInDirectory = ""
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Explorer")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.appTextMuted)
                    .textCase(.uppercase)
                
                Spacer()
                
                Menu {
                    Button("New File") {
                        isCreatingFile = true
                        createInDirectory = ""
                    }
                    Button("New Folder") {}
                    Divider()
                    Button("Refresh") {}
                } label: {
                    Image(systemName: "ellipsis")
                        .foregroundColor(.appTextMuted)
                        .font(.system(size: 14))
                        .frame(width: 28, height: 28)
                        .background(Color.appSurfaceHighlight)
                        .cornerRadius(4)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.appSurface)
            
            // File tree
            ScrollView {
                if let tree = fileTree {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(tree.children ?? []) { node in
                            FileTreeNodeView(
                                node: node,
                                level: 0,
                                selectedFile: $selectedFile,
                                expandedDirectories: $expandedDirectories,
                                onFileSelect: onFileSelect
                            )
                        }
                    }
                } else {
                    // Loading state
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity, minHeight: 200)
                        .foregroundColor(.appTextMuted)
                }
            }
            .background(Color.appSurface)
        }
        .background(Color.appSurface)
        .alert("New File", isPresented: $isCreatingFile) {
            TextField("Filename", text: $newFileName)
                .font(.system(.body, design: .monospaced))
            Button("Cancel", role: .cancel) { newFileName = "" }
            Button("Create") {
                // Would create file
                newFileName = ""
            }
        }
    }
}

// MARK: - File Tree Node

struct FileTreeNodeView: View {
    let node: FileNode
    let level: Int
    @Binding var selectedFile: FileNode?
    @Binding var expandedDirectories: Set<String>
    let onFileSelect: (FileNode) -> Void
    
    private var isExpanded: Bool {
        expandedDirectories.contains(node.path)
    }
    
    private var isSelected: Bool {
        selectedFile?.id == node.id
    }
    
    private var iconColor: Color {
        if isSelected { return .appCrimson }
        if node.isDirectory { return .appTextSecondary }
        switch node.fileExtension?.lowercased() {
        case "swift": return Color(hex: "C7455C")
        case "py": return Color(hex: "7D9A6D")
        case "js", "ts": return Color(hex: "B89A6A")
        case "json": return Color(hex: "9A7DB5")
        default: return .appTextMuted
        }
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Node row
            Button(action: handleTap) {
                HStack(spacing: 6) {
                    // Indentation
                    HStack(spacing: 0) {
                        ForEach(0..<level, id: \.self) { _ in
                            Rectangle()
                                .fill(Color.clear)
                                .frame(width: 16)
                        }
                    }
                    
                    // Expand/chevron for directories
                    if node.isDirectory {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.appTextMuted)
                            .frame(width: 16)
                    } else {
                        Rectangle()
                            .fill(Color.clear)
                            .frame(width: 16)
                    }
                    
                    // Icon
                    Image(systemName: node.iconName)
                        .font(.system(size: 14))
                        .foregroundColor(iconColor)
                        .frame(width: 20, alignment: .center)
                    
                    // Name
                    Text(node.name)
                        .font(.system(size: 13))
                        .foregroundColor(isSelected ? .appTextPrimary : .appTextSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    
                    Spacer()
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 8)
                .background(isSelected ? Color.appCrimson.opacity(0.15) : Color.clear)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            
            // Children
            if node.isDirectory && isExpanded {
                ForEach(node.children ?? []) { child in
                    FileTreeNodeView(
                        node: child,
                        level: level + 1,
                        selectedFile: $selectedFile,
                        expandedDirectories: $expandedDirectories,
                        onFileSelect: onFileSelect
                    )
                }
            }
        }
    }
    
    private func handleTap() {
        if node.isDirectory {
            if isExpanded {
                expandedDirectories.remove(node.path)
            } else {
                expandedDirectories.insert(node.path)
            }
        } else {
            selectedFile = node
            onFileSelect(node)
        }
    }
}
