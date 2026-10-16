import Darwin
import Foundation
import os
import MLX
import MLXLMCommon
import Security
import SwiftUI
import Tokenizers
#if canImport(UIKit)
import UIKit
#endif

private struct NodeAPIError: Error {
    let status: Int
    let code: String
    let message: String
}

private struct NodeChatRequest: Decodable, Sendable {
    struct Message: Decodable, Sendable {
        let role: String
        let content: String
    }
    let model: String?
    let messages: [Message]
    let max_tokens: Int?
    let max_completion_tokens: Int?
    let temperature: Float?
    let seed: UInt64?
    let stream: Bool?
    struct StreamOptions: Decodable, Sendable { let include_usage: Bool? }
    let stream_options: StreamOptions?
    var includeUsage: Bool { stream_options?.include_usage ?? true }

    var tokenLimit: Int { max_tokens ?? max_completion_tokens ?? 256 }
    var samplingTemperature: Float { temperature ?? 0 }

    static func parse(_ body: Data) throws -> Self {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            throw NodeAPIError(status: 400, code: "invalid_json", message: "Expected a JSON object.")
        }
        let supported: Set<String> = ["model", "messages", "max_tokens", "max_completion_tokens", "temperature", "seed", "stream", "stream_options"]
        guard Set(object.keys).isSubset(of: supported) else {
            throw NodeAPIError(status: 400, code: "unsupported_parameter", message: "Unsupported request parameter.")
        }
        if let options = object["stream_options"] {
            guard let options = options as? [String: Any], Set(options.keys).isSubset(of: ["include_usage"]) else {
                throw NodeAPIError(status: 400, code: "invalid_stream_options", message: "stream_options only supports include_usage.")
            }
        }
        let request: Self
        do { request = try JSONDecoder().decode(Self.self, from: body) }
        catch { throw NodeAPIError(status: 400, code: "invalid_request", message: "Invalid request field types.") }
        guard request.max_tokens == nil || request.max_completion_tokens == nil,
            (1...512).contains(request.tokenLimit), request.samplingTemperature.isFinite,
            (0...2).contains(request.samplingTemperature) else {
            throw NodeAPIError(status: 400, code: "invalid_parameters", message: "Use one token-limit field (1...512) and temperature 0...2.")
        }
        guard (1...32).contains(request.messages.count), request.messages.last?.role == "user",
            request.messages.allSatisfy({ ["system", "user", "assistant"].contains($0.role) && !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
            request.messages.dropFirst().allSatisfy({ $0.role != "system" }),
            request.messages.reduce(0, { $0 + $1.content.utf8.count }) <= 32768 else {
            throw NodeAPIError(status: 400, code: "invalid_messages", message: "Use 1...32 text messages, system only first, ending with user; at most 32 KiB of content.")
        }
        return request
    }
}

@Observable
@MainActor
final class LLMNodeService {
    let models: ModelStore
    private(set) var switchingModel = false
    init(models: ModelStore) { self.models = models }
    private(set) var enabled = false
    var ready: Bool { enabled && listenerReady && modelLoaded && !switchingModel }
    private var listenerReady = false
    private var modelLoaded = false
    private(set) var busy = false
    private(set) var status = "服务未启动"
    private(set) var completedRequests = 0
    private(set) var cancelledRequests = 0
    private(set) var failedRequests = 0
    private(set) var lastRequest = ""
    var addresses: String { Self.lanAddresses().map { "http://\($0):8080" }.joined(separator: " · ") }

    @ObservationIgnored private var server: NodeHTTPServer?
    @ObservationIgnored private weak var evaluator: LLMEvaluator?
    @ObservationIgnored private var generation: Task<Void, Never>?
    @ObservationIgnored private var activeID: String?
    @ObservationIgnored private var cancelReason: String?
    @ObservationIgnored private var token = ""
    @ObservationIgnored private var wantsService = false
    @ObservationIgnored private var listenerID: UUID?
    @ObservationIgnored private var foregroundActive = true

    func start(evaluator: LLMEvaluator) async {
        wantsService = true
        guard !enabled else { return }
        guard !evaluator.running, !busy else {
            status = "请等待当前生成结束后启动服务"
            return
        }
        self.evaluator = evaluator
        let listenerID = UUID()
        self.listenerID = listenerID
        do {
            token = try Self.loadCredential()
            let server = NodeHTTPServer(token: token, port: 8080, stateHandler: { [weak self] state in
                Task { @MainActor in
                    guard let self, self.listenerID == listenerID else { return }
                    switch state {
                    case "ready":
                        self.listenerReady = true
                        if self.modelLoaded { self.status = "可接收任务 · 已启用鉴权 · 端口 8080" }
                    case "failed", "stopped":
                        self.wantsService = false
                        self.stop(manual: false)
                        self.status = "网络监听失败；请重新启动服务"
                    default:
                        self.listenerReady = false
                        self.status = "正在等待网络"
                    }
                }
            }) { [weak self] request, response in
                guard let self else { return }
                await self.handle(request, response: response)
            }
            self.server = server
            try server.start()
            enabled = true
            status = "服务已启动 · 模型准备中"
            #if canImport(UIKit)
            UIApplication.shared.isIdleTimerDisabled = true
            #endif
            guard models.directory(for: models.active) != nil else {
                status = "请打开模型管理，下载并加载模型"
                return
            }
            _ = try await evaluator.load()
            guard enabled, self.listenerID == listenerID else { return }
            modelLoaded = true
            status = listenerReady ? "可接收任务 · 已启用鉴权 · 端口 8080" : "模型已准备；等待网络监听"
            event("service_ready", fields: ["port": 8080])
        } catch {
            guard self.listenerID == listenerID else { return }
            self.listenerID = nil
            server?.stop()
            server = nil
            enabled = false
            listenerReady = false
            modelLoaded = false
            status = "服务启动失败：\(error.localizedDescription)"
            #if canImport(UIKit)
            UIApplication.shared.isIdleTimerDisabled = false
            #endif
            event("service_error")
        }
    }

    func stop(manual: Bool = true) {
        if manual { wantsService = false }
        enabled = false
        listenerReady = false
        listenerID = nil
        cancelReason = "service_stopped"
        generation?.cancel()
        server?.stop()
        server = nil
        status = manual ? "服务已停止" : "后台已暂停；返回前台后恢复"
        #if canImport(UIKit)
        UIApplication.shared.isIdleTimerDisabled = false
        #endif
        event("service_stopped")
    }

    func pauseForBackground() {
        foregroundActive = false
        stop(manual: false)
    }

    func resume(evaluator: LLMEvaluator) async {
        foregroundActive = true
        if wantsService && !busy && !switchingModel { await start(evaluator: evaluator) }
    }

    func cancelCurrent() {
        cancelReason = "user_cancelled"
        generation?.cancel()
    }

    func copyCredential() {
        #if canImport(UIKit)
        UIPasteboard.general.string = token
        #elseif os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(token, forType: .string)
        #endif
    }

    func switchModel(to id: String, evaluator: LLMEvaluator) async {
        guard !switchingModel, models.downloadingID == nil,
            let target = models.model(id), models.directory(for: target) != nil else {
            models.report("请先完成下载，并等待当前模型操作结束。")
            return
        }
        switchingModel = true
        defer { switchingModel = false }
        let previous = models.active
        let restart = wantsService || enabled
        stop()
        evaluator.cancelGeneration()
        models.report("正在等待推理结束并释放旧模型…")
        while busy || evaluator.running || evaluator.isLoading {
            // Do not release a model while its Metal task is still draining.
            try? await Task.sleep(for: .milliseconds(100))
        }
        evaluator.unloadModel()
        modelLoaded = false
        models.selectForLoading(target)
        do {
            _ = try await evaluator.load()
            models.persistSelection()
            models.report("已加载 " + target.title)
        } catch {
            evaluator.unloadModel()
            models.selectForLoading(previous)
            do {
                _ = try await evaluator.load()
                models.report("新模型加载失败，已恢复上一模型：" + error.localizedDescription)
            } catch {
                models.report("模型加载失败，请下载或重新选择可用模型。")
            }
        }
        wantsService = restart
        if restart && foregroundActive { await start(evaluator: evaluator) }
    }

    private func manageModels(_ request: NodeHTTPRequest, response: NodeHTTPResponse) async {
        do {
            guard request.headers["content-type"]?.split(separator: ";").first?.trimmingCharacters(in: .whitespaces).lowercased() == "application/json",
                let object = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
                Set(object.keys).isSubset(of: ["model"]) else {
                throw ModelStoreError.invalid("Use a JSON object with only a model field.")
            }
            guard !switchingModel else {
                try await response.sendJSON(status: 409, data: Self.errorData(code: "model_operation_active", message: "A model switch is active."))
                return
            }
            if request.path.hasSuffix("/cancel") {
                models.cancelDownload()
            } else {
                guard let id = object["model"] as? String, let model = models.model(id) else {
                    throw ModelStoreError.invalid("Select a model from the node catalog.")
                }
                if request.path.hasSuffix("/download") { try models.startDownload(id) }
                else if request.path.hasSuffix("/delete") { try models.delete(id) }
                else {
                    guard models.downloadingID == nil, models.directory(for: model) != nil, let evaluator else {
                        throw ModelStoreError.invalid("Finish downloading the model before activation.")
                    }
                    try await response.sendJSON(status: 202, data: Self.json(["accepted": true, "model": id]))
                    Task { await self.switchModel(to: id, evaluator: evaluator) }
                    return
                }
            }
            try await response.sendJSON(status: 202, data: Self.json(["accepted": true]))
        } catch {
            try? await response.sendJSON(status: 400, data: Self.errorData(code: "invalid_model_operation", message: error.localizedDescription))
        }
    }

    private func handle(_ request: NodeHTTPRequest, response: NodeHTTPResponse) async {
        guard !Task.isCancelled else { return }
        switch (request.method, request.path) {
        case ("GET", "/health"):
            let body: [String: Any] = ["ready": ready && enabled, "busy": busy || (evaluator?.running ?? false),
                "model": models.active.id, "model_revision": models.active.revision,
                "thermal_state": ProcessInfo.processInfo.thermalState.rawValue,
                "memory_bytes": Memory.activeMemory, "memory": Self.memoryMetrics(),
                "completed_requests": completedRequests, "cancelled_requests": cancelledRequests,
                "failed_requests": failedRequests, "max_concurrent_generations": 1,
                "max_prompt_tokens": 2048, "max_completion_tokens": 512, "foreground_required": true]
            try? await response.sendJSON(status: 200, data: Self.json(body))
        case ("GET", "/v1/models"):
            try? await response.sendJSON(status: 200, data: Self.json(["object": "list", "data": [[
                "id": models.active.id, "object": "model", "created": 0, "owned_by": "local-ipad",
                "quantization_bits": models.active.bits, "quantization_group_size": models.active.groupSize,
                "model_revision": models.active.revision]]]))
        case ("GET", "/v1/node/models"):
            var state = models.state()
            state["switching_model"] = switchingModel
            try? await response.sendJSON(status: 200, data: Self.json(state))
        case ("POST", "/v1/node/models/download"), ("POST", "/v1/node/models/cancel"),
             ("POST", "/v1/node/models/activate"), ("POST", "/v1/node/models/delete"):
            await manageModels(request, response: response)
        case ("POST", "/v1/chat/completions"):
            await chat(request, response: response)
        default:
            try? await response.sendJSON(status: 404, data: Self.errorData(code: "not_found", message: "Unknown route or HTTP method."))
        }
    }

    private func chat(_ http: NodeHTTPRequest, response: NodeHTTPResponse) async {
        var streamingStarted = false
        var acquired = false
        var requestID = ""
        defer {
            if acquired {
                generation = nil
                activeID = nil
                busy = false
                evaluator?.running = false
                if enabled { status = "可接收任务 · 已启用鉴权 · 端口 8080" }
                else if wantsService, foregroundActive, !switchingModel, let evaluator {
                    Task { await self.start(evaluator: evaluator) }
                }
            }
        }
        do {
            guard http.headers["content-type"]?.split(separator: ";").first?.trimmingCharacters(in: .whitespaces).lowercased() == "application/json" else {
                throw NodeAPIError(status: 415, code: "unsupported_media_type", message: "Use Content-Type: application/json.")
            }
            let request = try NodeChatRequest.parse(http.body)
            guard enabled, ready, let evaluator else {
                throw NodeAPIError(status: 503, code: "not_ready", message: "Model unavailable; keep the iPad app in foreground.")
            }
            let model = models.active
            guard request.model == nil || request.model == model.id else {
                throw NodeAPIError(status: 400, code: "model_not_found", message: "This node currently serves " + model.id)
            }
            guard !busy, !evaluator.running else {
                throw NodeAPIError(status: 429, code: "node_busy", message: "A generation is active. Retry after it completes.")
            }
            try Task.checkCancellation()
            busy = true
            evaluator.running = true
            acquired = true
            cancelReason = nil
            requestID = "chatcmpl-" + UUID().uuidString.lowercased()
            activeID = requestID
            status = "正在处理 Mac 请求"
            event("request_started", fields: ["id": requestID, "stream": request.stream ?? false])
            let start = ProcessInfo.processInfo.systemUptime
            let container = try await evaluator.load()
            MLXRandom.seed(request.seed ?? UInt64.random(in: 0...UInt64.max))
            let (promptCount, prepareSeconds, stream, generationTask) = try await container.perform { context in
                let messages = request.messages.map { message -> Chat.Message in
                    switch message.role {
                    case "system": return .system(message.content)
                    case "assistant": return .assistant(message.content)
                    default: return .user(message.content)
                    }
                }
                let input = try await context.processor.prepare(input: UserInput(chat: messages,
                    additionalContext: ["enable_thinking": false]))
                let count = input.text.tokens.size
                guard count <= 2048 else {
                    throw NodeAPIError(status: 400, code: "context_length_exceeded", message: "Prompt exceeds the node's 2048-token limit.")
                }
                let prepareSeconds = ProcessInfo.processInfo.systemUptime - start
                let (stream, task) = try generateTokensTask(input: input,
                    parameters: GenerateParameters(maxTokens: request.tokenLimit, temperature: request.samplingTemperature), context: context)
                return (count, prepareSeconds, stream, task)
            }
            generation = generationTask
            let id = requestID
            let deadline = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(120)) } catch { return }
                guard let self, self.activeID == id else { return }
                self.cancelReason = "request_timeout"
                generationTask.cancel()
            }
            defer { deadline.cancel() }
            let created = Int(Date().timeIntervalSince1970)
            var generatedIDs = [Int]()
            var first: Double?
            var last = start
            var completion: GenerateCompletionInfo?
            var incrementalText = IncrementalTokenText()
            var text = ""
            try await withTaskCancellationHandler {
                do {
                    try Task.checkCancellation()
                    if request.stream == true {
                        try await response.startSSE()
                        streamingStarted = true
                        try await response.sendSSE(data: Self.json(Self.chunk(id: id, created: created, model: model.id, delta: ["role": "assistant"])))
                    }
                    for await item in stream {
                        try Task.checkCancellation()
                        if cancelReason != nil { throw CancellationError() }
                        switch item {
                        case .token(let tokenID):
                            let tick = ProcessInfo.processInfo.systemUptime
                            if first == nil { first = tick }
                            last = tick
                            generatedIDs.append(tokenID)
                            let decoded = await container.decode(tokenIds: generatedIDs)
                            let piece = try incrementalText.appendDecoded(decoded)
                            if !piece.isEmpty {
                                text += piece
                                if request.stream == true {
                                    try await response.sendSSE(data: Self.json(Self.chunk(id: id, created: created, model: model.id, delta: ["content": piece])))
                                }
                            }
                        case .info(let info): completion = info
                        }
                    }
                    await generationTask.value
                    try Task.checkCancellation()
                    if cancelReason != nil { throw CancellationError() }
                } catch {
                    generationTask.cancel()
                    await generationTask.value
                    throw error
                }
            } onCancel: { generationTask.cancel() }
            guard let completion, generatedIDs.count == completion.generationTokenCount else {
                throw NodeAPIError(status: 500, code: "incomplete_generation", message: "Generation did not produce matching completion metadata.")
            }
            let finish: String
            if generatedIDs.count >= request.tokenLimit { finish = "length" }
            else {
                switch completion.stopReason {
                case .stop: finish = "stop"
                default: throw NodeAPIError(status: 500, code: "incomplete_generation", message: "Generation ended unexpectedly.")
                }
            }
            let decoded = await container.decode(tokenIds: generatedIDs)
            let suffix = try incrementalText.appendDecoded(decoded, final: true)
            text += suffix
            if request.stream == true, !suffix.isEmpty {
                try await response.sendSSE(data: Self.json(Self.chunk(id: id, created: created, model: model.id, delta: ["content": suffix])))
            }
            let usage = ["prompt_tokens": promptCount, "completion_tokens": generatedIDs.count, "total_tokens": promptCount + generatedIDs.count]
            var metrics = Self.memoryMetrics()
            metrics["prepare_ms"] = prepareSeconds * 1000
            metrics["time_to_first_token_ms"] = first.map { ($0 - start) * 1000 } as Any? ?? NSNull()
            metrics["generation_tokens"] = generatedIDs.count
            metrics["decode_tokens_per_second"] = generatedIDs.count > 1 && last > (first ?? last) ? Double(generatedIDs.count - 1) / (last - (first ?? last)) : 0
            metrics["request_seconds"] = ProcessInfo.processInfo.systemUptime - start
            metrics["library_tokens_per_second"] = completion.tokensPerSecond.isFinite ? completion.tokensPerSecond as Any : NSNull()
            metrics["library_stop_reason"] = String(describing: completion.stopReason)
            metrics["token_counts_match"] = true
            metrics["thermal_state"] = ProcessInfo.processInfo.thermalState.rawValue
            metrics["model_revision"] = model.revision
            if request.stream == true {
                var end = Self.chunk(id: id, created: created, model: model.id, delta: [:], finish: finish)
                end["device_metrics"] = metrics
                try await response.sendSSE(data: Self.json(end))
                if request.includeUsage {
                    try await response.sendSSE(data: Self.json(["id": id, "object": "chat.completion.chunk", "created": created,
                        "model": model.id, "choices": [], "usage": usage, "device_metrics": metrics]))
                }
                try await response.sendSSE(data: Data("[DONE]".utf8))
                try await response.finish()
            } else {
                try await response.sendJSON(status: 200, data: Self.json(["id": id, "object": "chat.completion", "created": created,
                    "model": model.id, "choices": [["index": 0, "message": ["role": "assistant", "content": text], "finish_reason": finish]],
                    "usage": usage, "device_metrics": metrics]))
            }
            completedRequests += 1
            lastRequest = "已完成 \(generatedIDs.count) token"
            evaluator.output = text
            evaluator.promptLength = promptCount
            evaluator.totalTokens = generatedIDs.count
            evaluator.timeToFirstToken = first.map { ($0 - start) * 1000 } ?? 0
            evaluator.tokensPerSecond = metrics["decode_tokens_per_second"] as? Double ?? 0
            evaluator.totalTime = ProcessInfo.processInfo.systemUptime - start
            event("request_completed", fields: ["id": id, "tokens": generatedIDs.count])
        } catch {
            let apiError: NodeAPIError
            if error is CancellationError || Task.isCancelled {
                if acquired { cancelledRequests += 1 }
                apiError = NodeAPIError(status: cancelReason == "request_timeout" ? 504 : 503,
                    code: cancelReason ?? "request_cancelled", message: "Generation cancelled; retry when the node is ready.")
                if acquired { event("request_cancelled", fields: ["id": requestID]) }
            } else if let known = error as? NodeAPIError { apiError = known }
            else { apiError = NodeAPIError(status: 500, code: "generation_failed", message: "Local inference failed.") }
            if acquired && !(error is CancellationError) && !Task.isCancelled { failedRequests += 1 }
            if streamingStarted {
                try? await response.sendSSE(data: Self.errorData(code: apiError.code, message: apiError.message))
                try? await response.finish()
            } else {
                try? await response.sendJSON(status: apiError.status, data: Self.errorData(code: apiError.code, message: apiError.message))
            }
        }
    }

    private nonisolated static func chunk(id: String, created: Int, model: String, delta: [String: String], finish: String? = nil) -> [String: Any] {
        ["id": id, "object": "chat.completion.chunk", "created": created, "model": model,
         "choices": [["index": 0, "delta": delta, "finish_reason": finish as Any? ?? NSNull()]]]
    }

    private nonisolated static func json(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private nonisolated static func errorData(code: String, message: String) -> Data {
        (try? json(["error": ["message": message, "type": "invalid_request_error", "code": code]])) ?? Data()
    }

    private nonisolated static func memoryMetrics() -> [String: Any] {
        var vm = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &vm) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return ["physical_memory_bytes": ProcessInfo.processInfo.physicalMemory,
            "process_available_bytes": os_proc_available_memory(),
            "mlx_active_bytes": Memory.activeMemory, "mlx_peak_bytes": Memory.peakMemory,
            "phys_footprint_bytes": result == KERN_SUCCESS ? vm.phys_footprint : 0,
            "phys_footprint_peak_bytes": result == KERN_SUCCESS ? vm.ledger_phys_footprint_peak : 0]
    }

    private static func loadCredential() throws -> String {
        let url = URL.documentsDirectory.appending(path: "server-token.txt")
        if let value = try? String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
            value.count >= 32, value.count <= 128, value.utf8.allSatisfy({ (45...122).contains($0) && $0 != 92 }) {
            return value
        }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw NodeAPIError(status: 500, code: "credential_generation_failed", message: "Cannot create service credential.")
        }
        let value = bytes.map { String(format: "%02x", $0) }.joined()
        try Data(value.utf8).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return value
    }

    private func event(_ name: String, fields: [String: Any] = [:]) {
        var record = fields
        record["event"] = name
        record["date"] = ISO8601DateFormatter().string(from: Date())
        guard let data = try? Self.json(record) else { return }
        print("NODE " + String(decoding: data, as: UTF8.self))
        let url = URL.documentsDirectory.appending(path: "api-events.jsonl")
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        guard let file = try? FileHandle(forWritingTo: url) else { return }
        defer { try? file.close() }
        _ = try? file.seekToEnd()
        try? file.write(contentsOf: data + Data([10]))
    }

    private nonisolated static func lanAddresses() -> [String] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { return [] }
        defer { freeifaddrs(list) }
        var addresses = [String]()
        var item = list
        while let current = item {
            defer { item = current.pointee.ifa_next }
            guard let address = current.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                String(cString: current.pointee.ifa_name).hasPrefix("en") else { continue }
            let value = UnsafeRawPointer(address).assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr
            var mutable = value
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            if inet_ntop(AF_INET, &mutable, &buffer, socklen_t(buffer.count)) != nil {
                addresses.append(String(cString: buffer))
            }
        }
        return addresses
    }
}
