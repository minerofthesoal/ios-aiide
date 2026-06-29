// MARK: - Git Panel
// OnDeviceAIIDE/Views/Panels/GitPanel.swift
//
// Git interface for version control: commit history, diffs, branching.

import SwiftUI

struct GitPanel: View {
    @State private var repository: GitRepository?
    @State private var commits: [GitCommit] = []
    @State private var branches: [GitBranch] = []
    @State private var gitStatus: GitStatus?
    @State private var commitMessage = ""
    @State private var selectedCommit: GitCommit?
    @State private var showingInitAlert = false
    @State private var diffText = ""
    @State private var isLoading = false
    @State private var project: Project?
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let repo = repository, repo.isInitialized {
                    initializedView(repo: repo)
                } else {
                    emptyStateView
                }
            }
            .background(Color.appBackground)
            .navigationTitle("Source Control")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                if repository?.isInitialized == true {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button(action: refreshRepository) {
                            Image(systemName: "arrow.clockwise")
                                .foregroundColor(.appTextSecondary)
                        }
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
        .task {
            await loadRepository()
        }
    }
    
    // MARK: - Empty State
    
    private var emptyStateView: some View {
        VStack(spacing: 20) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 50))
                .foregroundColor(.appTextMuted.opacity(0.5))
            
            Text("Git Repository Not Initialized")
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(.appTextPrimary)
            
            Text("Initialize Git to track changes, create commits, and manage branches for your project.")
                .font(.system(size: 14))
                .foregroundColor(.appTextSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            
            Button("Initialize Repository") {
                showingInitAlert = true
            }
            .crimsonButton(isProminent: true)
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.appBackground)
        .alert("Initialize Git Repository?", isPresented: $showingInitAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Initialize") {
                Task { await initializeRepository() }
            }
        } message: {
            Text("This will create a new Git repository for your current project.")
        }
    }
    
    // MARK: - Initialized State
    
    private func initializedView(repo: GitRepository) -> some View {
        VStack(spacing: 0) {
            // Branch selector
            branchBar(repo: repo)
            
            // Status summary
            if let status = gitStatus {
                StatusSummaryBar(status: status)
            }
            
            // Commit message input (if changes exist)
            if gitStatus?.hasChanges == true {
                commitInput
            }
            
            // Commit history
            List {
                Section(header: SectionHeader(title: "Commit History")) {
                    ForEach(commits) { commit in
                        CommitRow(
                            commit: commit,
                            isSelected: selectedCommit?.id == commit.id
                        )
                        .listRowBackground(Color.appSurface)
                        .onTapGesture {
                            selectedCommit = commit
                            Task { await loadDiff(for: commit) }
                        }
                    }
                }
            }
            .listStyle(.plain)
            .background(Color.appBackground)
        }
    }
    
    private func branchBar(repo: GitRepository) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.triangle.branch")
                .foregroundColor(.appCrimson)
                .font(.system(size: 14))
            
            Text(repo.currentBranch)
                .font(.system(size: 14, weight: .semibold, design: .monospaced))
                .foregroundColor(.appTextPrimary)
            
            Text("\(repo.commitCount) commits")
                .font(.system(size: 12))
                .foregroundColor(.appTextMuted)
            
            Spacer()
            
            if let status = gitStatus, !status.isClean {
                HStack(spacing: 4) {
                    Circle()
                        .fill(Color.appWarning)
                        .frame(width: 6, height: 6)
                    Text("\(status.staged.count + status.unstaged.count) changes")
                        .font(.system(size: 11))
                        .foregroundColor(.appWarning)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.appWarning.opacity(0.12))
                .cornerRadius(4)
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
    }
    
    private var commitInput: some View {
        VStack(spacing: 8) {
            TextEditor(text: $commitMessage)
                .font(.system(size: 14))
                .foregroundColor(.appTextPrimary)
                .scrollContentBackground(.hidden)
                .background(Color.appInputBackground)
                .frame(height: 60)
                .cornerRadius(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.appBorder, lineWidth: 0.5)
                )
                .overlay(
                    Group {
                        if commitMessage.isEmpty {
                            Text("Commit message...")
                                .font(.system(size: 14))
                                .foregroundColor(.appTextMuted)
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                                .padding(8)
                        }
                    }
                )
            
            HStack {
                Button("Stage All") {
                    Task { await stageAll() }
                }
                .font(.system(size: 13))
                .foregroundColor(.appTextSecondary)
                
                Spacer()
                
                Button("Commit") {
                    Task { await createCommit() }
                }
                .crimsonButton(isProminent: true)
                .disabled(commitMessage.isEmpty)
            }
        }
        .padding(12)
        .background(Color.appSurface)
        .overlay(
            Rectangle()
                .fill(Color.appDivider)
                .frame(height: 0.5),
            alignment: .bottom
        )
    }
    
    // MARK: - Actions
    
    private func loadRepository() async {
        do {
            let projects = try await FileSystemManager.shared.listProjects()
            guard let project = projects.first else { return }
            self.project = project
            
            let git = GitService.shared
            if await git.isRepositoryInitialized(project: project) {
                repository = try await git.getRepositoryInfo(project: project)
                commits = try await git.log(project: project, maxCount: 50)
                branches = try await git.listBranches(project: project)
                gitStatus = try await git.status(project: project)
            }
        } catch {
            print("Git load error: \(error)")
        }
    }
    
    private func initializeRepository() async {
        guard let project = project else { return }
        do {
            repository = try await GitService.shared.initRepository(project: project)
            await loadRepository()
        } catch {
            print("Git init error: \(error)")
        }
    }
    
    private func refreshRepository() {
        Task { await loadRepository() }
    }
    
    private func stageAll() async {
        guard let project = project else { return }
        do {
            try await GitService.shared.addAll(project: project)
            gitStatus = try await GitService.shared.status(project: project)
        } catch {
            print("Stage error: \(error)")
        }
    }
    
    private func createCommit() async {
        guard let project = project, !commitMessage.isEmpty else { return }
        do {
            _ = try await GitService.shared.commit(project: project, message: commitMessage)
            commitMessage = ""
            await loadRepository()
        } catch {
            print("Commit error: \(error)")
        }
    }
    
    private func loadDiff(for commit: GitCommit) async {
        // Would show diff for this commit
        diffText = "Showing changes for \(commit.shortHash): \(commit.message)"
    }
}

// MARK: - Commit Row

struct CommitRow: View {
    let commit: GitCommit
    let isSelected: Bool
    
    var body: some View {
        HStack(spacing: 12) {
            // Commit hash
            Text(commit.shortHash)
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundColor(.appCrimson)
                .frame(width: 55, alignment: .leading)
            
            VStack(alignment: .leading, spacing: 3) {
                Text(commit.message)
                    .font(.system(size: 14))
                    .foregroundColor(.appTextPrimary)
                    .lineLimit(1)
                
                HStack(spacing: 8) {
                    Text(commit.author)
                        .font(.system(size: 12))
                        .foregroundColor(.appTextSecondary)
                    
                    Text(commit.formattedDate)
                        .font(.system(size: 12))
                        .foregroundColor(.appTextMuted)
                }
            }
            
            Spacer()
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(isSelected ? Color.appSurfaceActive : Color.clear)
        .cornerRadius(6)
    }
}

// MARK: - Status Summary Bar

struct StatusSummaryBar: View {
    let status: GitStatus
    
    var body: some View {
        if !status.isClean {
            HStack(spacing: 16) {
                if !status.staged.isEmpty {
                    StatusBadge(count: status.staged.count, label: "staged", color: .appSuccess)
                }
                if !status.unstaged.isEmpty {
                    StatusBadge(count: status.unstaged.count, label: "modified", color: .appWarning)
                }
                if !status.untracked.isEmpty {
                    StatusBadge(count: status.untracked.count, label: "new", color: .appInfo)
                }
                
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color.appSurface.opacity(0.5))
        }
    }
}

struct StatusBadge: View {
    let count: Int
    let label: String
    let color: Color
    
    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text("\(count) \(label)")
                .font(.system(size: 11))
                .foregroundColor(color.opacity(0.8))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(color.opacity(0.12))
        .cornerRadius(4)
    }
}

// MARK: - Section Header

struct SectionHeader: View {
    let title: String
    
    var body: some View {
        Text(title)
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(.appTextMuted)
            .textCase(.uppercase)
            .padding(.vertical, 4)
    }
}
