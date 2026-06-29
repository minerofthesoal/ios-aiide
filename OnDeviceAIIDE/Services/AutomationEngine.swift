// MARK: - Automation Engine
// OnDeviceAIIDE/Services/AutomationEngine.swift
//
// Local automation engine for executing workflow steps defined in YAML/JSON.
// Supports: script execution, asset compilation, testing, and deployment.

import Foundation
import os.log

/// Executes automation workflows defined in YAML or JSON configuration files
actor AutomationEngine {
    
    static let shared = AutomationEngine()
    
    private let logger = Logger(subsystem: "com.ondeviceaiide", category: "AutomationEngine")
    
    /// Currently running workflow
    private(set) var currentWorkflow: Workflow?
    /// Execution history
    private(set) var executionHistory: [WorkflowRun] = []
    /// Whether a workflow is currently running
    private(set) var isRunning = false
    
    private init() {}
    
    // MARK: - Workflow Execution
    
    /// Parse and execute a workflow from a YAML string
    func executeWorkflow(yaml: String, in project: Project) async throws -> WorkflowRun {
        let workflow = try parseWorkflowYAML(yaml)
        return try await executeWorkflow(workflow, in: project)
    }
    
    /// Parse and execute a workflow from a JSON string
    func executeWorkflow(json: String, in project: Project) async throws -> WorkflowRun {
        let workflow = try parseWorkflowJSON(json)
        return try await executeWorkflow(workflow, in: project)
    }
    
    /// Execute a parsed workflow
    func executeWorkflow(_ workflow: Workflow, in project: Project) async throws -> WorkflowRun {
        guard !isRunning else {
            throw AutomationError.alreadyRunning
        }
        
        isRunning = true
        currentWorkflow = workflow
        
        let startTime = Date()
        var stepResults: [StepResult] = []
        var overallSuccess = true
        
        logger.info("Starting workflow '\(workflow.name)' with \(workflow.steps.count) steps")
        
        for (index, step) in workflow.steps.enumerated() {
            let stepStart = Date()
            
            do {
                let output = try await executeStep(step, in: project, context: stepResults)
                let duration = Date().timeIntervalSince(stepStart)
                
                let result = StepResult(
                    stepIndex: index,
                    stepName: step.name,
                    status: .success,
                    output: output,
                    duration: duration
                )
                stepResults.append(result)
                
                logger.info("Step \(index + 1)/\(workflow.steps.count) succeeded: \(step.name)")
                
            } catch {
                let duration = Date().timeIntervalSince(stepStart)
                let result = StepResult(
                    stepIndex: index,
                    stepName: step.name,
                    status: .failed(error.localizedDescription),
                    output: "",
                    duration: duration
                )
                stepResults.append(result)
                overallSuccess = false
                
                logger.error("Step \(index + 1)/\(workflow.steps.count) failed: \(step.name) - \(error.localizedDescription)")
                
                if !step.continueOnError {
                    break
                }
            }
        }
        
        let totalDuration = Date().timeIntervalSince(startTime)
        
        let run = WorkflowRun(
            workflow: workflow,
            projectName: project.name,
            startTime: startTime,
            duration: totalDuration,
            stepResults: stepResults,
            success: overallSuccess
        )
        
        executionHistory.append(run)
        isRunning = false
        currentWorkflow = nil
        
        logger.info("Workflow '\(workflow.name)' completed in \(String(format: "%.2f", totalDuration))s")
        
        return run
    }
    
    /// Cancel the currently running workflow
    func cancel() {
        isRunning = false
        currentWorkflow = nil
        logger.info("Workflow cancelled")
    }
    
    // MARK: - Step Execution
    
    private func executeStep(_ step: WorkflowStep, in project: Project, context: [StepResult]) async throws -> String {
        switch step.type {
        case .script:
            return try await executeScriptStep(step, in: project)
        case .build:
            return try await executeBuildStep(step, in: project)
        case .test:
            return try await executeTestStep(step, in: project)
        case .lint:
            return try await executeLintStep(step, in: project)
        case .deploy:
            return try await executeDeployStep(step, in: project)
        case .custom:
            return try await executeCustomStep(step, in: project)
        }
    }
    
    private func executeScriptStep(_ step: WorkflowStep, in project: Project) async throws -> String {
        guard let script = step.config["script"] else {
            throw AutomationError.missingConfiguration("script")
        }
        
        let result = try await FileSystemManager.shared.executeCommand(script, in: project)
        guard result.isSuccess else {
            throw AutomationError.scriptFailed(result.stderr)
        }
        return result.stdout
    }
    
    private func executeBuildStep(_ step: WorkflowStep, in project: Project) async throws -> String {
        let command = step.config["command"] ?? defaultBuildCommand(for: project)
        let result = try await FileSystemManager.shared.executeCommand(command, in: project)
        guard result.isSuccess else {
            throw AutomationError.buildFailed(result.stderr)
        }
        return "Build successful\n" + result.stdout
    }
    
    private func executeTestStep(_ step: WorkflowStep, in project: Project) async throws -> String {
        let command = step.config["command"] ?? defaultTestCommand(for: project)
        let result = try await FileSystemManager.shared.executeCommand(command, in: project)
        guard result.isSuccess else {
            throw AutomationError.testsFailed(result.stderr)
        }
        return "All tests passed\n" + result.stdout
    }
    
    private func executeLintStep(_ step: WorkflowStep, in project: Project) async throws -> String {
        let command = step.config["command"] ?? defaultLintCommand(for: project)
        let result = try await FileSystemManager.shared.executeCommand(command, in: project)
        return result.stdout.isEmpty ? "No issues found" : result.stdout
    }
    
    private func executeDeployStep(_ step: WorkflowStep, in project: Project) async throws -> String {
        // Deploy via share sheet or export
        let format = step.config["format"] ?? "zip"
        switch format {
        case "zip":
            let url = try await FileSystemManager.shared.exportAsZip(project: project)
            return "Exported to: \(url.lastPathComponent)"
        default:
            return "Deploy format '\(format)' not supported"
        }
    }
    
    private func executeCustomStep(_ step: WorkflowStep, in project: Project) async throws -> String {
        guard let command = step.config["command"] else {
            throw AutomationError.missingConfiguration("command")
        }
        let result = try await FileSystemManager.shared.executeCommand(command, in: project)
        return result.stdout + (result.stderr.isEmpty ? "" : "\n[stderr] \(result.stderr)")
    }
    
    // MARK: - Default Commands
    
    private func defaultBuildCommand(for project: Project) -> String {
        switch project.template {
        case .swift:
            return "swift build"
        case .python:
            return "python -m py_compile src/main.py"
        case .web:
            return "npm run build 2>/dev/null || echo 'No build script'"
        default:
            return "echo 'No build command configured'"
        }
    }
    
    private func defaultTestCommand(for project: Project) -> String {
        switch project.template {
        case .swift:
            return "swift test"
        case .python:
            return "python -m pytest tests/ -v 2>/dev/null || python -m unittest discover tests/"
        case .web:
            return "npm test 2>/dev/null || echo 'No test script'"
        default:
            return "echo 'No test command configured'"
        }
    }
    
    private func defaultLintCommand(for project: Project) -> String {
        switch project.template {
        case .swift:
            return "swiftlint lint --quiet 2>/dev/null || echo 'swiftlint not installed'"
        case .python:
            return "flake8 src/ 2>/dev/null || pylint src/ 2>/dev/null || echo 'No linter installed'"
        case .web:
            return "eslint src/ 2>/dev/null || echo 'eslint not installed'"
        default:
            return "echo 'No lint command configured'"
        }
    }
    
    // MARK: - Parsing
    
    private func parseWorkflowYAML(_ yaml: String) throws -> Workflow {
        // In production, use Yams library
        // Placeholder: Parse simple YAML-like format
        var name = "Workflow"
        var steps: [WorkflowStep] = []
        
        let lines = yaml.components(separatedBy: .newlines)
        var currentStep: WorkflowStep?
        
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            
            if trimmed.hasPrefix("name:") {
                name = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces)
            } else if trimmed.hasPrefix("- name:") {
                if let step = currentStep { steps.append(step) }
                let stepName = trimmed.dropFirst(7).trimmingCharacters(in: .whitespaces)
                currentStep = WorkflowStep(
                    name: stepName,
                    type: .script,
                    config: [:],
                    continueOnError: false
                )
            } else if trimmed.hasPrefix("run:") {
                let script = trimmed.dropFirst(4).trimmingCharacters(in: .whitespaces)
                currentStep?.type = .script
                currentStep?.config["script"] = script
            } else if trimmed.hasPrefix("continue-on-error:") {
                let val = trimmed.dropFirst(18).trimmingCharacters(in: .whitespaces)
                currentStep?.continueOnError = (val == "true")
            }
        }
        
        if let step = currentStep { steps.append(step) }
        
        return Workflow(name: name, steps: steps)
    }
    
    private func parseWorkflowJSON(_ json: String) throws -> Workflow {
        guard let data = json.data(using: .utf8) else {
            throw AutomationError.invalidJSON
        }
        return try JSONDecoder().decode(Workflow.self, from: data)
    }
    
    // MARK: - Templates
    
    /// Get default workflow template for a project type
    func workflowTemplate(for template: ProjectTemplate) -> String {
        switch template {
        case .swift:
            return """
            name: Swift CI
            on: [push]
            jobs:
              build:
                steps:
                  - name: Build
                    run: swift build
                  - name: Test
                    run: swift test
                  - name: Lint
                    run: swiftlint lint
            """
        case .python:
            return """
            name: Python CI
            on: [push]
            jobs:
              test:
                steps:
                  - name: Install Dependencies
                    run: pip install -r requirements.txt
                  - name: Run Tests
                    run: pytest -v
                  - name: Type Check
                    run: mypy src/
            """
        case .web:
            return """
            name: Web CI
            on: [push]
            jobs:
              build:
                steps:
                  - name: Install
                    run: npm install
                  - name: Build
                    run: npm run build
                  - name: Test
                    run: npm test
            """
        default:
            return """
            name: Default Workflow
            steps:
              - name: Echo
                run: echo 'Hello, On-Device AI IDE!'
            """
        }
    }
}

// MARK: - Data Models

/// A workflow definition
struct Workflow: Codable, Sendable {
    let name: String
    var steps: [WorkflowStep]
}

/// A single workflow step
struct WorkflowStep: Codable, Sendable {
    let name: String
    var type: StepType
    var config: [String: String]
    var continueOnError: Bool
}

enum StepType: String, Codable, Sendable {
    case script
    case build
    case test
    case lint
    case deploy
    case custom
}

/// Result of executing a workflow
struct WorkflowRun: Identifiable, Sendable {
    let id = UUID()
    let workflow: Workflow
    let projectName: String
    let startTime: Date
    let duration: TimeInterval
    let stepResults: [StepResult]
    let success: Bool
    
    var formattedDuration: String {
        if duration < 60 {
            return String(format: "%.1fs", duration)
        } else {
            let mins = Int(duration) / 60
            let secs = Int(duration) % 60
            return "\(mins)m \(secs)s"
        }
    }
}

/// Result of a single step execution
struct StepResult: Sendable {
    let stepIndex: Int
    let stepName: String
    let status: StepStatus
    let output: String
    let duration: TimeInterval
    
    enum StepStatus: Sendable {
        case success
        case skipped
        case failed(String)
        
        var isSuccess: Bool {
            if case .success = self { return true }
            return false
        }
    }
}

// MARK: - Errors

enum AutomationError: Error, Sendable {
    case alreadyRunning
    case missingConfiguration(String)
    case scriptFailed(String)
    case buildFailed(String)
    case testsFailed(String)
    case deployFailed(String)
    case invalidYAML(String)
    case invalidJSON
    
    var localizedDescription: String {
        switch self {
        case .alreadyRunning: return "A workflow is already running"
        case .missingConfiguration(let key): return "Missing configuration: \(key)"
        case .scriptFailed(let msg): return "Script failed: \(msg)"
        case .buildFailed(let msg): return "Build failed: \(msg)"
        case .testsFailed(let msg): return "Tests failed: \(msg)"
        case .deployFailed(let msg): return "Deploy failed: \(msg)"
        case .invalidYAML(let msg): return "Invalid YAML: \(msg)"
        case .invalidJSON: return "Invalid JSON workflow definition"
        }
    }
}
