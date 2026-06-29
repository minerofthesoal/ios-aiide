# On-Device AI IDE — Project Summary

## Deliverables

| Metric | Value |
|--------|-------|
| Swift Source Files | 21 |
| Total Lines of Code | ~8,089 |
| Core Models | 3 files |
| Service Layer | 8 files |
| UI Layer | 6 files |
| Utility Layer | 2 files |
| App Entry | 2 files |

---

## Architecture Overview

The project follows a clean **MVVM-Service-Storage** architecture with actor-based concurrency throughout:

```
UI Layer (SwiftUI)
├── ContentView (root container with multi-panel layout)
├── EditorWorkspaceView (3-panel: sidebar + editor + status)
├── ChatPanel (streaming AI chat interface)
├── GitPanel (version control UI)
├── ModelManagerPanel (HF download + model config)
├── FileBrowserPanel (hierarchical file tree)
└── CodeEditorView (syntax-aware editor with line numbers)

Service Layer (Swift Actors for thread safety)
├── HuggingFaceDownloadManager (secure downloads, resume, SHA-256)
├── ModelConfigurationStore (Core Data persistence)
├── InferenceEngineProtocol (GGUF/MLX/CoreML/Remote engines)
├── GenericAPIClient (OpenAI, Anthropic, Ollama, LM Studio, Custom)
├── FileSystemManager (workspace CRUD, zip export, share sheet)
├── GitService (init, commit, branch, diff, log)
├── RAGEngine (vector DB, document chunking, embedding)
├── LSPClient (syntax highlighting, completion, diagnostics)
└── AutomationEngine (YAML/JSON workflow execution)

Storage Layer
├── CoreDataStack (persistent container)
└── VectorDatabase (in-memory cosine similarity search)
```

---

## Key Features Implemented

### 1. HuggingFace Download Manager
- **Secure HTTPS fetching** with configurable timeouts (300s request, 24hr resource)
- **Resume capability** via HTTP Range requests and persistent temp files
- **SHA-256 checksum verification** for LFS files
- **Concurrent download limiting** (max 3 parallel)
- **Exponential backoff retry** (3 attempts, 2s base delay)
- **Progress tracking** with bytes-downloaded / total-bytes
- **Auto-format detection** from file extensions

### 2. Model Configuration Store
- **Core Data persistence** with background context merging
- **Actor-isolated** thread-safe CRUD operations
- **In-memory cache** for fast DTO retrieval
- **Model metadata**: format, quantization, context length, vision support
- **Default inference parameters** with per-model overrides
- **Import/export** configuration as JSON
- **Storage analytics** (total usage, breakdown by model)

### 3. Inference Engines
- **GGUF Engine**: llama.cpp integration placeholder with Metal GPU layers
- **MLX Engine**: Apple Silicon Metal Performance Primitives path
- **CoreML Engine**: Neural Engine + GPU + CPU fallback
- **Remote Engine**: Unified API client routing
- **Unified protocol**: `load()`, `generate()`, `tokenize()`, `interrupt()`

### 4. Remote API Clients
| Provider | Endpoint | Streaming | Auth |
|----------|----------|-----------|------|
| OpenAI | api.openai.com | SSE (data: chunks) | Bearer token |
| Anthropic | api.anthropic.com | SSE | x-api-key header |
| Ollama | localhost:11434 | JSON streaming | None |
| LM Studio | localhost:1234 | OpenAI-compatible | None |
| Custom | User-defined | Text stream | Optional Bearer |

### 5. File System Manager
- **Project templates**: Empty, Swift, Python, Web with starter files
- **Full CRUD**: create, read, update, delete files and directories
- **Zip export** with iOS Share Sheet integration
- **Project import** from .zip archives
- **Command execution** within project directory

### 6. Git Service
- **Repository lifecycle**: init, status check
- **Staging**: add, addAll, reset
- **Commits**: create with custom messages
- **Branching**: list, create, checkout, delete
- **History**: log with hash/message/author/date
- **Diffs**: staged, unstaged, per-file
- **Status badges**: staged count, modified count, new files

### 7. RAG Engine
- **Document chunking**: language-aware (structural boundaries) + sliding window
- **Vector embeddings**: deterministic pseudo-embeddings (384-dim, ready for CoreML BERT)
- **Cosine similarity search** with relevance thresholding
- **Deduplication** (max 3 chunks per file) and reranking
- **Context prompt building** with token budget management

### 8. LSP Client
- **JSON-RPC 2.0** protocol over stdin/stdout pipes
- **Lifecycle**: initialize, shutdown, exit
- **Text sync**: didOpen, didChange, didClose
- **Features**: completion, hover, definition, semantic tokens
- **Language support**: Swift, Python, JS/TS, Rust, Go, C/C++

### 9. Automation Engine
- **YAML and JSON** workflow parsing
- **Step types**: script, build, test, lint, deploy, custom
- **Error handling**: continue-on-error per step
- **Template workflows** per project type
- **Execution history** with timing

### 10. UI/UX Design System
- **Color palette**: Muted Charcoal (#1A1D21, #22252A, #2A2E35, #3A3F47)
- **Primary accent**: Deep Crimson (#8B0000, #4A0E17)
- **NO neon, NO purple, NO glowing gradients**
- **Syntax highlighting**: keyword (crimson), string (sage), type (blue), function (amber)
- **Components**: surface cards, crimson buttons, format tags, status badges

---

## Target Hardware

| Device | Recommended Format | Acceleration |
|--------|-------------------|--------------|
| iPhone 14 | GGUF Q4_0 | Metal GPU |
| iPhone 15 | MLX 4-bit | Metal Performance |
| iPhone 16 | MLX 4-bit | Metal Performance |
| iPhone 17 Pro | CoreML + MLX | Neural Engine + GPU |

---

## Notable Design Decisions

1. **Actor isolation** for all service classes — eliminates data races without locks
2. **NEON explicitly avoided** — all inference paths use Metal/ANE instead
3. **AsyncStream for generation** — enables real-time token streaming to UI
4. **DTO pattern** — CoreData entities never cross actor boundaries
5. **In-memory vector DB** — RAG uses Swift arrays with SIMD-friendly cosine similarity
6. **Process-based LSP** — language servers spawned as subprocesses over JSON-RPC

---

## Integration Points (Production Readiness)

| Component | Current | Production Upgrade |
|-----------|---------|-------------------|
| GGUF | Placeholder loop | llama.cpp Swift bindings |
| MLX | Placeholder loop | mlx-swift package |
| CoreML | Placeholder loop | MLModel.compileModel |
| Embeddings | Pseudo-embeddings | CoreML MiniLM model |
| LSP | JSON-RPC scaffold | Yams + real language servers |
| RAG Vector DB | In-memory | SQLite-VSS or CoreML |

---

*Project created for iOS 26.x sideload deployment on iPhone 14 through iPhone 17 Pro.*
