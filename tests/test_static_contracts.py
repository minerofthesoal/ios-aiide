"""Static contract tests for the On-Device AI IDE prototype.

These tests intentionally avoid importing iOS frameworks so they can run on
Linux CI while still guarding the features the app advertises: renderable
SwiftUI entry points, Hugging Face model downloads, Metal-capable model
formats, and streaming inference engines.
"""

from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / "OnDeviceAIIDE"


def read(relative: str) -> str:
    return (ROOT / relative).read_text(encoding="utf-8")


class RenderContractTests(unittest.TestCase):
    def test_app_has_renderable_swiftui_entry_points(self) -> None:
        app = read("OnDeviceAIIDE/OnDeviceAIIDEApp.swift")
        content = read("OnDeviceAIIDE/ContentView.swift")

        self.assertIn("@main", app)
        self.assertRegex(app, r"struct\s+OnDeviceAIIDEApp\s*:\s*App")
        self.assertIn("WindowGroup", app)
        self.assertIn("ContentView()", app)

        for view in [
            "ContentView",
            "EditorWorkspaceView",
            "ModelBrowserView",
            "SettingsView",
            "EmptyEditorView",
            "StatusBar",
        ]:
            self.assertRegex(content, rf"struct\s+{view}\s*:\s*View")

        for tab_label in ["Editor", "Models", "AI Chat", "Git", "Settings"]:
            self.assertIn(f'Text("{tab_label}")', content)

    def test_primary_panels_and_editor_are_swiftui_views(self) -> None:
        expected_views = {
            "OnDeviceAIIDE/Views/Panels/ModelManagerPanel.swift": "ModelManagerPanel",
            "OnDeviceAIIDE/Views/Panels/ChatPanel.swift": "ChatPanel",
            "OnDeviceAIIDE/Views/Panels/GitPanel.swift": "GitPanel",
            "OnDeviceAIIDE/Views/Panels/FileBrowserPanel.swift": "FileBrowserPanel",
            "OnDeviceAIIDE/Views/Editor/CodeEditorView.swift": "CodeEditorView",
        }
        for path, view in expected_views.items():
            source = read(path)
            self.assertIn("import SwiftUI", source, path)
            self.assertRegex(source, rf"struct\s+{view}\s*:\s*View", path)


class ModelDownloadContractTests(unittest.TestCase):
    def test_huggingface_downloader_uses_secure_download_features(self) -> None:
        source = read("OnDeviceAIIDE/Services/ML/HuggingFaceDownloadManager.swift")

        self.assertIn("https://huggingface.co/api/models/", source)
        self.assertIn("https://huggingface.co/", source)
        self.assertIn("URLSession", source)
        self.assertIn("CryptoKit", source)
        self.assertIn("SHA256", source)
        self.assertIn('forHTTPHeaderField: "Range"', source)
        self.assertIn("maxConcurrentDownloads = 3", source)
        self.assertIn("maxRetryAttempts = 3", source)
        self.assertIn("verifyAvailableStorage", source)
        self.assertIn("verifyDownloadedModel", source)

    def test_model_manager_starts_download_and_tracks_progress(self) -> None:
        source = read("OnDeviceAIIDE/Views/Panels/ModelManagerPanel.swift")

        self.assertIn("HuggingFaceDownloadManager.shared.downloadModel", source)
        self.assertIn("ModelConfigurationStore.shared", source)
        self.assertIn("createModel", source)
        self.assertIn("updateDownloadProgress", source)
        self.assertIn("downloadStates", source)
        self.assertIn("state(for: taskID)", source)
        self.assertIn("ProgressView", source)


class MetalAndInferenceContractTests(unittest.TestCase):
    def test_all_local_model_formats_advertise_metal_acceleration(self) -> None:
        source = read("OnDeviceAIIDE/Models/ModelFormat.swift")

        for case in ["gguf", "mlx", "coreml"]:
            self.assertRegex(source, rf"case\s+\.{case}:\s*\n\s*return\s+true")
        self.assertIn("case metalOnly", source)
        self.assertIn("supportsMetalAcceleration", source)
        self.assertIn("usesNEON", source)

    def test_default_inference_parameters_enable_metal(self) -> None:
        source = read("OnDeviceAIIDE/Services/ML/ModelConfigurationStore.swift")

        default_block = re.search(r"static let `default` = InferenceParameters\((.*?)\n\s*\)", source, re.S)
        self.assertIsNotNone(default_block)
        self.assertIn("useMetal: true", default_block.group(1))
        self.assertIn("nGpuLayers", source)
        self.assertIn("accelerationPreference", source)

    def test_inference_engines_load_generate_tokenize_and_interrupt(self) -> None:
        source = read("OnDeviceAIIDE/Services/ML/InferenceEngineProtocol.swift")

        self.assertIn("protocol InferenceEngine", source)
        for engine in ["GGUFInferenceEngine", "MLXInferenceEngine", "CoreMLInferenceEngine", "RemoteInferenceEngine"]:
            self.assertRegex(source, rf"final\s+actor\s+{engine}\s*:\s*InferenceEngine")
        for method in ["load(model:", "generate(prompt:", "tokenize(_", "tokenCount(for text:", "interrupt()"]:
            self.assertIn(method, source)
        self.assertIn("AsyncStream<TokenOutput>", source)
        config = read("OnDeviceAIIDE/Services/ML/ModelConfigurationStore.swift")
        self.assertIn("useMetal", config)
        self.assertIn("nGpuLayers", source + config)


class RepositoryHygieneTests(unittest.TestCase):
    def test_ci_workflow_runs_contracts_and_swift_parse_smoke(self) -> None:
        workflow = read(".github/workflows/ci.yml")

        self.assertIn("python -m unittest discover", workflow)
        self.assertIn("macos-15", workflow)
        self.assertIn("xcodebuild -version", workflow)
        self.assertIn("swiftc -parse-as-library -parse", workflow)


    def test_release_workflow_builds_and_uploads_unsigned_ipa(self) -> None:
        workflow = read(".github/workflows/ios-release.yml")
        project = read("project.yml")

        self.assertIn("workflow_dispatch", workflow)
        self.assertIn("tags:", workflow)
        self.assertIn("brew install xcodegen", workflow)
        self.assertIn("xcodegen generate --spec project.yml", workflow)
        self.assertIn("xcodebuild archive", workflow)
        self.assertIn("CODE_SIGNING_ALLOWED=NO", workflow)
        self.assertIn("OnDeviceAIIDE.ipa", workflow)
        self.assertIn("actions/upload-artifact", workflow)
        self.assertIn("softprops/action-gh-release", workflow)

        self.assertIn("type: application", project)
        self.assertIn("platform: iOS", project)
        self.assertIn("PRODUCT_BUNDLE_IDENTIFIER", project)
        self.assertIn("GENERATE_INFOPLIST_FILE: YES", project)

    def test_all_swift_files_are_non_empty(self) -> None:
        swift_files = list(SRC.rglob("*.swift"))
        self.assertGreaterEqual(len(swift_files), 15)
        for path in swift_files:
            self.assertGreater(path.stat().st_size, 0, str(path.relative_to(ROOT)))


if __name__ == "__main__":
    unittest.main()
