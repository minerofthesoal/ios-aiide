// MARK: - Model Format Definitions
// OnDeviceAIIDE/Models/ModelFormat.swift

import Foundation

/// Supported AI model serialization formats for on-device inference
enum ModelFormat: String, CaseIterable, Codable, Sendable {
    case gguf = "GGUF"
    case mlx = "MLX"
    case coreml = "CoreML"
    
    /// File extensions associated with each format
    var fileExtensions: [String] {
        switch self {
        case .gguf:
            return ["gguf"]
        case .mlx:
            return ["safetensors", "mlx", "npz"]
        case .coreml:
            return ["mlpackage", "mlmodelc", "mlmodel"]
        }
    }
    
    /// Whether this format supports Metal GPU acceleration
    var supportsMetalAcceleration: Bool {
        switch self {
        case .gguf:
            return true  // llama.cpp Metal backend
        case .mlx:
            return true  // Native Metal performance primitives
        case .coreml:
            return true  // Neural Engine + GPU
        }
    }
    
    /// Whether this format supports the NEON SIMD instruction set
    /// Explicitly disabled where Metal hardware paths are available
    var usesNEON: Bool {
        switch self {
        case .gguf:
            // llama.cpp uses NEON only as fallback when Metal is unavailable
            return false
        case .mlx:
            // MLX uses Metal performance primitives exclusively on Apple Silicon
            return false
        case .coreml:
            // CoreML uses Neural Engine / GPU / NEON as fallback
            return false
        }
    }
    
    /// The inference engine class responsible for this format
    var preferredInferenceEngine: InferenceEngineType {
        switch self {
        case .gguf:
            return .gguf
        case .mlx:
            return .mlx
        case .coreml:
            return .coreml
        }
    }
    
    /// Human-readable description of the format
    var description: String {
        switch self {
        case .gguf:
            return "GGUF (llama.cpp) — Universal format with quantization support"
        case .mlx:
            return "MLX — Apple Silicon optimized with Metal primitives"
        case .coreml:
            return "CoreML — Neural Engine accelerated"
        }
    }
}

/// Identifies which inference engine to use
enum InferenceEngineType: String, Codable, Sendable {
    case gguf = "GGUFInferenceEngine"
    case mlx = "MLXInferenceEngine"
    case coreml = "CoreMLInferenceEngine"
    case remote = "RemoteAPIEngine"
}

/// Model quantization level for GGUF models
enum QuantizationLevel: String, Codable, CaseIterable, Sendable {
    case q4_0 = "Q4_0"
    case q4_1 = "Q4_1"
    case q5_0 = "Q5_0"
    case q5_1 = "Q5_1"
    case q8_0 = "Q8_0"
    case f16 = "F16"
    case f32 = "F32"
    
    /// Approximate model size multiplier relative to F32
    var sizeMultiplier: Double {
        switch self {
        case .q4_0: return 0.25
        case .q4_1: return 0.28
        case .q5_0: return 0.31
        case .q5_1: return 0.34
        case .q8_0: return 0.50
        case .f16: return 1.0
        case .f32: return 2.0
        }
    }
    
    /// Quality score (1-10) for this quantization level
    var qualityScore: Int {
        switch self {
        case .q4_0: return 5
        case .q4_1: return 6
        case .q5_0: return 7
        case .q5_1: return 7
        case .q8_0: return 8
        case .f16: return 9
        case .f32: return 10
        }
    }
}

/// Hardware acceleration preference
enum AccelerationPreference: String, Codable, Sendable {
    /// Use Metal GPU exclusively — skips NEON fallback
    case metalOnly = "metal_only"
    /// Use Neural Engine where available (CoreML only)
    case neuralEngine = "neural_engine"
    /// Automatic selection based on model format and hardware
    case auto = "auto"
}
