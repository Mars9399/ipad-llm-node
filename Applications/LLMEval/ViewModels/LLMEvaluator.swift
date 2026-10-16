// Copyright © 2025 Apple Inc.

import Hub
import Darwin
#if canImport(UIKit)
import UIKit
#endif
import HuggingFace
import MLX
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import Metal
import SwiftUI
import Tokenizers

@Observable
@MainActor
class LLMEvaluator {

    var running = false

    var includeWeatherTool = false
    var enableThinking = false
    var maxTokens = 2048

    var prompt = ""
    var output = ""
    var modelInfo = ""

    // Download progress tracking
    var downloadProgress: Double?
    var totalSize: String?

    // Performance metrics
    var tokensPerSecond: Double = 0.0
    var timeToFirstToken: Double = 0.0
    var promptLength: Int = 0
    var totalTokens: Int = 0
    var totalTime: Double = 0.0

    // Track if generation was truncated due to hitting max tokens
    var wasTruncated: Bool = false

    // Timer for tracking TTFT in real-time
    private var ttftTimer: Timer?
    private var generationStartTime: TimeInterval = 0

    // Timer for tracking tokens/sec and total time in real-time
    private var generationTimer: Timer?
    private var firstTokenTime: TimeInterval = 0

    /// This controls which model loads.
    let models: ModelStore
    var modelConfiguration: ModelConfiguration { ModelConfiguration(id: models.active.id, revision: models.active.revision) }

    init(models: ModelStore) { self.models = models }

    func unloadModel() {
        precondition(!running && !isLoading)
        loadState = .idle
        Memory.clearCache()
        modelInfo = ""
        output = ""
    }

    /// Parameters controlling the generation output (max tokens and temperature).
    var generateParameters: GenerateParameters {
        GenerateParameters(maxTokens: maxTokens, temperature: 0.6)
    }

    /// A task responsible for handling the generation process.
    var generationTask: Task<Void, Error>?
    private var localGenerationWorker: Task<Void, Never>?

    /// Tool executor for function calling
    private let toolExecutor = ToolExecutor()

    enum LoadState {
        case idle
        case loading
        case loaded(ModelContainer)
    }

    var loadState = LoadState.idle

    var isLoading: Bool {
        if case .loading = loadState {
            return true
        }
        return false
    }

    /// Short model name extracted from the full model ID.
    private var modelName: String {
        modelConfiguration.name.components(separatedBy: "/").last ?? modelConfiguration.name
    }

    /// Load and return the model. Can be called multiple times; subsequent calls return the cached model.
    func load() async throws -> ModelContainer {
        while true {
            switch loadState {
            case .idle:
                return try await performLoad()

            case .loading:
                // Already loading, wait and retry
                try await Task.sleep(for: .milliseconds(100))

            case .loaded(let modelContainer):
                return modelContainer
            }
        }
    }

    private func performLoad() async throws -> ModelContainer {
        loadState = .loading
        modelInfo = "Downloading \(modelName)..."
        downloadProgress = 0.0

        Memory.cacheLimit = 20 * 1024 * 1024

        do {
            guard let modelDirectory = models.directory(for: models.active) else {
                throw ModelStoreError.invalid("请先打开模型管理，下载并加载一个模型。")
            }

            // Verify the download succeeded by checking for model files
            let fileManager = FileManager.default
            let directoryExists = fileManager.fileExists(atPath: modelDirectory.path)
            let contents =
                (try? fileManager.contentsOfDirectory(atPath: modelDirectory.path)) ?? []
            let hasSafetensors = contents.contains { $0.hasSuffix(".safetensors") }

            if !directoryExists || !hasSafetensors {
                throw NSError(
                    domain: "LLMEvaluator",
                    code: -1,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "Model download failed. Please check your network connection and try again."
                    ]
                )
            }

            modelInfo = "Loading \(modelName)..."
            downloadProgress = nil
            totalSize = nil

            let modelContainer = try await LLMModelFactory.shared.loadContainer(
                from: modelDirectory,
                using: #huggingFaceTokenizerLoader())

            let numParams = await modelContainer.perform { $0.model.numParameters() }

            self.prompt = PresetPrompts.all[0].prompt
            self.modelInfo = formatModelInfo(name: modelConfiguration.name, parameters: numParams)
            loadState = .loaded(modelContainer)
            return modelContainer

        } catch {
            resetLoadingState()
            throw error
        }
    }

    private func updateDownloadProgress(_ progress: Progress) {
        modelInfo = "Downloading \(modelName) (\(Int(progress.fractionCompleted * 100))%)"
        downloadProgress = progress.fractionCompleted

        // Get file count info
        if progress.totalUnitCount > 0 && progress.totalUnitCount < 100 {
            totalSize = "File \(progress.completedUnitCount + 1) of \(progress.totalUnitCount)"
        } else if progress.totalUnitCount > 0 {
            totalSize =
                "\(formatBytes(progress.completedUnitCount)) of \(formatBytes(progress.totalUnitCount))"
        } else {
            totalSize = nil
        }
    }

    private func resetLoadingState() {
        loadState = .idle
        downloadProgress = nil
        totalSize = nil
    }

    private func formatModelInfo(name: String, parameters: Int) -> String {
        // Extract model name from full ID (e.g., "mlx-community/Qwen3-8B-4bit" -> "Qwen3-8B-4bit")
        let modelName = name.components(separatedBy: "/").last ?? name

        // Format parameter count (convert millions to billions if appropriate)
        let paramMillions = parameters / (1024 * 1024)
        let paramString: String
        if paramMillions >= 1000 {
            let paramBillions = Double(paramMillions) / 1000.0
            paramString = String(format: "%.1fB", paramBillions)
        } else {
            paramString = "\(paramMillions)M"
        }

        return "\(modelName) • \(paramString) parameters"
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    private func generate(prompt: String, toolResult: String? = nil) async {
        // Only clear output if this is a fresh generation (not a tool continuation)
        if toolResult == nil {
            self.output = ""
            // Reset metrics at start
            self.totalTokens = 0
            self.tokensPerSecond = 0.0
            self.promptLength = 0
            self.timeToFirstToken = 0.0
            self.totalTime = 0.0
            self.wasTruncated = false

            // Start the real-time TTFT timer
            generationStartTime = Date.timeIntervalSinceReferenceDate
            ttftTimer?.invalidate()
            ttftTimer = Timer.scheduledTimer(withTimeInterval: 0.01, repeats: true) {
                [weak self] _ in
                guard let self = self else { return }
                Task { @MainActor in
                    let elapsed = Date.timeIntervalSinceReferenceDate - self.generationStartTime
                    self.timeToFirstToken = elapsed * 1000  // Convert to ms
                }
            }
        }

        var chat: [Chat.Message] = [
            .system("You are a helpful assistant"),
            .user(prompt),
        ]

        if let toolResult {
            chat.append(.tool(toolResult))
        }

        let userInput = UserInput(
            chat: chat,
            tools: includeWeatherTool ? toolExecutor.allToolSchemas : nil,
            additionalContext: ["enable_thinking": enableThinking]
        )

        do {
            let modelContainer = try await load()

            // Capture parameters on MainActor before entering perform block
            let parameters = generateParameters

            // Seed random generator to ensure varied output each generation
            MLXRandom.seed(UInt64(Date.timeIntervalSinceReferenceDate * 1000))

            let lmInput = try await modelContainer.prepare(input: userInput)
            let promptTokenCount = lmInput.text.tokens.size
            let start = Date.timeIntervalSinceReferenceDate
            let (stream, worker) = try await modelContainer.perform(nonSendable: lmInput) { context, input in
                let iterator = try TokenIterator(input: input, model: context.model, cache: nil, parameters: parameters)
                return generateTask(promptTokenCount: input.text.tokens.size, modelConfiguration: context.configuration,
                    tokenizer: context.tokenizer, iterator: iterator)
            }
            localGenerationWorker = worker

            var iterator = stream.makeAsyncIterator()
            if let first = await iterator.next() {
                let firstTick = Date.timeIntervalSinceReferenceDate
                let promptTime = firstTick - start

                // Update TTFT and prompt length
                Task { @MainActor in
                    self.ttftTimer?.invalidate()
                    self.ttftTimer = nil
                    self.timeToFirstToken = promptTime * 1000  // Convert to ms
                    self.promptLength = promptTokenCount

                    // Start real-time generation metrics tracking
                    self.firstTokenTime = Date.timeIntervalSinceReferenceDate
                    self.generationTimer?.invalidate()
                    self.generationTimer = Timer.scheduledTimer(
                        withTimeInterval: 0.1, repeats: true
                    ) { [weak self] _ in
                        guard let self = self else { return }
                        Task { @MainActor in
                            let elapsed =
                                Date.timeIntervalSinceReferenceDate - self.firstTokenTime
                            self.totalTime = elapsed
                        }
                    }
                }

                var completionInfo: GenerateCompletionInfo?
                var pendingToolCall: ToolCall?

                // Check if first token is a tool call
                if let toolCall = first.toolCall {
                    pendingToolCall = toolCall
                } else if let chunk = first.chunk {
                    if !chunk.isEmpty {
                        Task { @MainActor [chunk] in
                            self.output += chunk
                        }
                    }
                }

                // Only continue iterating if we haven't hit a tool call
                if pendingToolCall == nil {
                    while let next = await iterator.next() {
                        if let info = next.info {
                            completionInfo = info
                            continue
                        }
                        // Check for tool calls
                        if let toolCall = next.toolCall {
                            pendingToolCall = toolCall
                            break
                        }

                        // Handle text chunks
                        if let chunk = next.chunk {
                            if !chunk.isEmpty {
                                Task { @MainActor [chunk] in
                                    self.output += chunk
                                }
                            }
                        }
                    }
                }
                await finishLocalWorker()
                let finalInfo = completionInfo

                Task { @MainActor in
                    self.generationTimer?.invalidate()
                    self.generationTimer = nil
                    self.tokensPerSecond = finalInfo?.tokensPerSecond ?? 0
                    self.totalTokens = finalInfo?.generationTokenCount ?? 0
                    self.totalTime = finalInfo?.generateTime ?? 0

                    // Check if generation was truncated due to max tokens
                    if self.totalTokens >= parameters.maxTokens ?? Int.max {
                        self.wasTruncated = true
                    }
                }

                // Handle tool call if one was made
                if let toolCall = pendingToolCall {
                    await self.executeToolAndContinue(
                        toolCall: toolCall, originalPrompt: prompt)
                }
            }

            await finishLocalWorker()
        } catch {
            await finishLocalWorker()
            ttftTimer?.invalidate()
            ttftTimer = nil
            generationTimer?.invalidate()
            generationTimer = nil
            output = "Failed: \(error)"
        }
    }

    private func finishLocalWorker() async {
        guard let worker = localGenerationWorker else { return }
        worker.cancel()
        await worker.value
        localGenerationWorker = nil
    }

    private func executeToolAndContinue(toolCall: ToolCall, originalPrompt: String) async {
        // Show tool execution in output
        self.output += "\n\n[Executing tool: \(toolCall.function.name)...]\n\n"

        let result: String
        do {
            result = try await toolExecutor.execute(toolCall)
        } catch {
            result = "Error executing tool: \(error.localizedDescription)"
        }

        // Continue generation with tool result
        await generate(prompt: originalPrompt, toolResult: result)
    }

    func generate() {
        guard !running else { return }

        let currentPrompt = prompt
        guard !currentPrompt.isEmpty else { return }

        running = true
        generationTask = Task {
            await generate(prompt: currentPrompt)
            prompt = ""
            running = false
            generationTask = nil
        }
    }

    func cancelGeneration() {
        localGenerationWorker?.cancel()
        generationTask?.cancel()
        ttftTimer?.invalidate()
        ttftTimer = nil
        generationTimer?.invalidate()
        generationTimer = nil
    }
}


extension LLMEvaluator {
    func runBenchmark(seconds: Double) async {
        guard !running else { return }
        running = true
        maxTokens = 256
        defer { running = false }
        #if canImport(UIKit)
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = false }
        #endif
        let benchmarkID = UUID().uuidString
        let destination = URL.documentsDirectory.appending(path: "benchmark.jsonl")
        let fixedPrompt = "Explain how a computer executes a program, covering memory, the CPU, operating systems, and storage. Give a detailed numbered explanation with examples."
        func record(_ value: [String: Any]) {
            var envelope = value
            envelope["session_id"] = benchmarkID
            envelope["recorded_at"] = ISO8601DateFormatter().string(from: Date())
            guard let data = try? JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys]),
                let line = String(data: data, encoding: .utf8) else { return }
            print("BENCH " + line)
            if !FileManager.default.fileExists(atPath: destination.path) {
                FileManager.default.createFile(atPath: destination.path, contents: nil)
            }
            if let handle = try? FileHandle(forWritingTo: destination) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: Data((line + "\n").utf8))
            }
        }
        do {
            let loadStart = ProcessInfo.processInfo.systemUptime
            let container = try await load()
            self.prompt = fixedPrompt
            record(["event": "loaded", "instrumentation_version": 2, "model": modelConfiguration.name,
                    "load_seconds": ProcessInfo.processInfo.systemUptime - loadStart,
                    "physical_memory_bytes": ProcessInfo.processInfo.physicalMemory,
                    "model_revision": models.active.revision,
                    "quantization_bits": models.active.bits, "quantization_group_size": models.active.groupSize,
                    "metal_device": MTLCreateSystemDefaultDevice()?.name ?? "unavailable",
                    "low_power_mode": ProcessInfo.processInfo.isLowPowerModeEnabled,
                    "os": ProcessInfo.processInfo.operatingSystemVersionString,
                    "date": ISO8601DateFormatter().string(from: Date())])
            let suiteStart = ProcessInfo.processInfo.systemUptime
            var run = 0
            repeat {
                MLXRandom.seed(42)
                let thermalStart = ProcessInfo.processInfo.thermalState.rawValue
                let requestStart = ProcessInfo.processInfo.systemUptime
                let (stream, task) = try await container.perform { context in
                    let input = try await context.processor.prepare(input: UserInput(
                        chat: [.system("You are a helpful assistant"), .user(fixedPrompt)],
                        additionalContext: ["enable_thinking": false]))
                    return try generateTokensTask(input: input,
                        parameters: GenerateParameters(maxTokens: 256, temperature: 0),
                        context: context)
                }
                var first: Double?
                var last: Double = requestStart
                var count = 0
                var generatedIDs = [Int]()
                var completion: GenerateCompletionInfo?
                for await event in stream {
                    switch event {
                    case .token(let tokenID):
                        generatedIDs.append(tokenID)
                        let tick = ProcessInfo.processInfo.systemUptime
                        if first == nil { first = tick }
                        last = tick
                        count += 1
                    case .info(let info): completion = info
                    }
                }
                await task.value
                guard let first, let completion else {
                    throw NSError(domain: "Benchmark", code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "No token or completion info received"])
                }
                var memory = mach_task_basic_info()
                var size = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
                let status = withUnsafeMutablePointer(to: &memory) { pointer in
                    pointer.withMemoryRebound(to: integer_t.self, capacity: Int(size)) {
                        task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &size)
                    }
                }
                var vmInfo = task_vm_info_data_t()
                var vmCount = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
                let vmStatus = withUnsafeMutablePointer(to: &vmInfo) { pointer in
                    pointer.withMemoryRebound(to: integer_t.self, capacity: Int(vmCount)) {
                        task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &vmCount)
                    }
                }
                let sampleText = await container.decode(tokenIds: Array(generatedIDs.prefix(96)))
                let speed = count > 1 && last > first ? Double(count - 1) / (last - first) : 0
                record(["event": "run", "run": run, "warmup": run == 0,
                    "elapsed_seconds": ProcessInfo.processInfo.systemUptime - suiteStart,
                    "model": modelConfiguration.name, "seed": 42, "temperature": 0,
                    "max_tokens": 256, "prompt": fixedPrompt,
                    "prompt_tokens": completion.promptTokenCount,
                    "generated_tokens": count,
                    "library_generated_tokens": completion.generationTokenCount,
                    "token_counts_match": count == completion.generationTokenCount,
                    "stop_reason": String(describing: completion.stopReason),
                    "ttft_ms": (first - requestStart) * 1000,
                    "decode_tokens_per_second": speed,
                    "library_tokens_per_second": completion.tokensPerSecond,
                    "request_seconds": ProcessInfo.processInfo.systemUptime - requestStart,
                    "mlx_active_bytes": Memory.activeMemory,
                    "mlx_peak_bytes": Memory.peakMemory,
                    "resident_bytes": status == KERN_SUCCESS ? memory.resident_size : 0,
                    "task_vm_info_status": vmStatus,
                    "phys_footprint_bytes": vmStatus == KERN_SUCCESS ? vmInfo.phys_footprint : 0,
                    "phys_footprint_peak_bytes": vmStatus == KERN_SUCCESS ? vmInfo.ledger_phys_footprint_peak : 0,
                    "sample_text": sampleText,
                    "thermal_start": thermalStart,
                    "thermal_end": ProcessInfo.processInfo.thermalState.rawValue])
                tokensPerSecond = speed
                timeToFirstToken = (first - requestStart) * 1000
                totalTokens = count
                promptLength = completion.promptTokenCount
                totalTime = ProcessInfo.processInfo.systemUptime - requestStart
                output = "Benchmark run \(run): \(speed) token/s. Results: benchmark.jsonl"
                run += 1
            } while run < 4 || ProcessInfo.processInfo.systemUptime - suiteStart < seconds
            record(["event": "complete", "runs": run,
                    "seconds": ProcessInfo.processInfo.systemUptime - suiteStart])
        } catch {
            output = "Benchmark failed: \(error)"
            record(["event": "error", "message": String(describing: error)])
        }
    }
}
