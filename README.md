# On-Device AI IDE for iOS

A premium, distraction-free integrated development environment with on-device AI inference capabilities for iOS 26.x+.

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────┐
│                        UI Layer                              │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────────┐  │
│  │ Code Editor  │  │ File Browser │  │   AI Assistant   │  │
│  │   (LSP)      │  │   (Git)      │  │     Panel        │  │
│  └──────────────┘  └──────────────┘  └──────────────────┘  │
├─────────────────────────────────────────────────────────────┤
│                     ViewModel Layer                          │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────────┐  │
│  │ EditorVM     │  │ FileTreeVM   │  │   InferenceVM    │  │
│  │ WorkspaceVM  │  │ GitVM        │  │   ChatVM         │  │
│  └──────────────┘  └──────────────┘  └──────────────────┘  │
├─────────────────────────────────────────────────────────────┤
│                    Service Layer                             │
│  ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌────────────────┐ │
│  │ ML Engine│ │  API     │ │  RAG     │ │      Git       │ │
│  │ (MLX/    │ │ Clients  │ │  Engine  │ │   (SwiftGit2)  │ │
│  │  GGUF)   │ │ (OpenAI  │ │(CoreML   │ │                │ │
│  │          │ │  etc.)   │ │  Embed)  │ │                │ │
│  └──────────┘ └──────────┘ └──────────┘ └────────────────┘ │
│  ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌────────────────┐ │
│  │  LSP     │ │  File    │ │  HF      │ │  Automation    │ │
│  │  Client  │ │  Manager │ │Downloader│ │   Engine       │ │
│  │          │ │          │ │          │ │  (YAML/JSON)   │ │
│  └──────────┘ └──────────┘ └──────────┘ └────────────────┘ │
├─────────────────────────────────────────────────────────────┤
│                   Storage Layer                              │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────────┐  │
│  │ Core Data    │  │  Vector DB   │  │   File System    │  │
│  │ (Config)     │  │ (RAG Index)  │  │   (Sandbox)      │  │
│  └──────────────┘  └──────────────┘  └──────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

## Directory Structure

```
OnDeviceAIIDE/
├── OnDeviceAIIDE/
│   ├── OnDeviceAIIDEApp.swift          # App entry point
│   ├── ContentView.swift               # Root container
│   ├── Models/
│   │   ├── AIModel.swift               # AI model entity
│   │   ├── ModelFormat.swift           # GGUF, MLX enum
│   │   ├── Project.swift               # Workspace project
│   │   ├── FileNode.swift              # File tree node
│   │   ├── GitCommit.swift             # Git commit model
│   │   ├── ChatMessage.swift           # Chat message
│   │   └── Embedding.swift             # Vector embedding
│   ├── Services/
│   │   ├── ML/
│   │   │   ├── HuggingFaceDownloadManager.swift
│   │   │   ├── ModelConfigurationStore.swift
│   │   │   ├── GGUFInferenceEngine.swift
│   │   │   ├── MLXInferenceEngine.swift
│   │   │   └── InferenceEngineProtocol.swift
│   │   ├── API/
│   │   │   ├── OpenAIClient.swift
│   │   │   ├── AnthropicClient.swift
│   │   │   ├── OllamaClient.swift
│   │   │   ├── LMStudioClient.swift
│   │   │   └── GenericAPIClient.swift
│   │   ├── Storage/
│   │   │   ├── FileSystemManager.swift
│   │   │   ├── CoreDataStack.swift
│   │   │   └── VectorDatabase.swift
│   │   ├── Git/
│   │   │   └── GitService.swift
│   │   ├── RAG/
│   │   │   ├── RAGEngine.swift
│   │   │   ├── DocumentChunker.swift
│   │   │   └── EmbeddingService.swift
│   │   └── LSP/
│   │       ├── LSPClient.swift
│   │       └── LSPModels.swift
│   ├── Views/
│   │   ├── Components/
│   │   │   ├── SyntaxTextView.swift
│   │   │   ├── LineNumberView.swift
│   │   │   ├── StatusBar.swift
│   │   │   └── ResizablePanel.swift
│   │   ├── Editor/
│   │   │   ├── CodeEditorView.swift
│   │   │   ├── EditorTabBar.swift
│   │   │   └── CompletionPopup.swift
│   │   └── Panels/
│   │       ├── FileBrowserPanel.swift
│   │       ├── ChatPanel.swift
│   │       ├── TerminalPanel.swift
│   │       └── ModelManagerPanel.swift
│   ├── ViewModels/
│   │   ├── EditorViewModel.swift
│   │   ├── FileTreeViewModel.swift
│   │   ├── InferenceViewModel.swift
│   │   ├── ChatViewModel.swift
│   │   └── GitViewModel.swift
│   └── Utils/
│       ├── Color+Theme.swift
│       ├── Font+Mono.swift
│       ├── String+Code.swift
│       └── Logger.swift
├── OnDeviceAIIDETests/
└── OnDeviceAIIDEUITests/
```

## Core Dependencies

- **MLX Swift**: Apple Silicon optimized inference
- **llama.cpp (Swift bindings)**: GGUF model support
- **SwiftGit2**: Local Git operations
- **Starscream**: WebSocket for LSP
- **Yams**: YAML parsing for automation workflows

## Design System

### Color Palette
| Token              | Hex       | Usage                    |
|--------------------|-----------|--------------------------|
| background         | `#1A1D21` | App background           |
| surface            | `#22252A` | Panels, sidebar          |
| surfaceHighlight   | `#2A2E35` | Hover states             |
| surfaceActive      | `#3A3F47` | Active selection         |
| crimson            | `#8B0000` | Primary accent           |
| crimsonLight       | `#4A0E17` | Secondary accent         |
| textPrimary        | `#E8E6E3` | Primary text             |
| textSecondary      | `#9A9590` | Secondary text           |
| border             | `#3A3F47` | Divider lines            |

### Typography
- **Mono**: SF Mono / JetBrains Mono for code
- **UI**: SF Pro Display for interface elements

## Supported Model Formats

| Format | Backend      | Hardware Acceleration |
|--------|-------------|----------------------|
| GGUF   | llama.cpp   | Metal GPU + NEON     |
| MLX    | MLX Swift   | Metal Performance    |
| CoreML | CoreML      | Neural Engine        |

## Supported API Providers

- OpenAI (GPT-4, GPT-3.5)
- Anthropic (Claude)
- Ollama (local)
- LM Studio (local)
- Generic REST API (custom)
