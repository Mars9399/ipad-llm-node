import Foundation
import Network

/// A deliberately small HTTP/1.1 transport: one authenticated request per TCP connection.
nonisolated struct NodeHTTPRequest: Sendable {
    let method: String
    let path: String
    /// Header names are lowercased. Duplicate headers are rejected by the parser.
    let headers: [String: String]
    let body: Data
}

nonisolated enum NodeHTTPError: Error, Sendable {
    case disconnected
    case invalidResponseState
    case invalidEventData
    case writeTimedOut
    case tooManyPendingWrites
    case invalidConfiguration
}

/// Await every send to apply socket backpressure to the producer.
nonisolated struct NodeHTTPResponse: Sendable {
    fileprivate let connection: NodeHTTPConnection

    var isConnected: Bool {
        get async { await connection.isConnected() }
    }

    /// Sends a complete response and closes the connection.
    func sendJSON(status: Int = 200, data: Data) async throws {
        try Task.checkCancellation()
        try await connection.sendJSON(status: status, data: data)
    }

    func startSSE() async throws {
        try Task.checkCancellation()
        try await connection.startSSE()
    }

    /// `data` is a UTF-8 event payload, e.g. a JSON object or `[DONE]`, without SSE framing.
    func sendSSE(data: Data) async throws {
        try Task.checkCancellation()
        guard let text = String(data: data, encoding: .utf8) else {
            throw NodeHTTPError.invalidEventData
        }
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let frame = normalized.components(separatedBy: "\n")
            .map { "data: " + $0 }.joined(separator: "\n") + "\n\n"
        try await connection.sendSSE(data: Data(frame.utf8))
    }

    /// Closes an SSE response. Safe to call after a completed JSON response.
    func finish() async throws {
        try await connection.finish()
    }
}

nonisolated final class NodeHTTPServer: @unchecked Sendable {
    typealias Handler = @Sendable (NodeHTTPRequest, NodeHTTPResponse) async -> Void
    private let queue = DispatchQueue(label: "llm.node.http", qos: .userInitiated)
    private let queueKey = DispatchSpecificKey<Bool>()
    private let token: [UInt8]
    private let port: UInt16
    private let handler: Handler
    private let stateHandler: (@Sendable (String) -> Void)?
    // These properties are confined to queue.
    private var listener: NWListener?
    private var clients: [UUID: NodeHTTPConnection] = [:]

    init(
        token: String, port: UInt16 = 8080,
        stateHandler: (@Sendable (String) -> Void)? = nil,
        handler: @escaping Handler
    ) {
        self.token = Array(token.utf8)
        self.port = port
        self.stateHandler = stateHandler
        self.handler = handler
        queue.setSpecific(key: queueKey, value: true)
    }

    /// Listener readiness is asynchronous; stateHandler reports ready, waiting, failed or stopped.
    func start() throws {
        guard !token.isEmpty, token.count <= 4096, port != 0,
            !token.contains(where: { $0 <= 32 || $0 >= 127 })
        else { throw NodeHTTPError.invalidConfiguration }
        try performOnQueue {
            guard listener == nil else { return }
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            let listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)
            self.listener = listener
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                guard let self, self.listener === listener else { return }
                switch state {
                case .ready: self.stateHandler?("ready")
                case .waiting: self.stateHandler?("waiting")
                case .failed:
                    self.stateHandler?("failed")
                    self.stopOnQueue()
                case .cancelled: self.stateHandler?("stopped")
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { connection.cancel(); return }
                // Includes slow/incomplete HTTP requests, so they cannot exhaust app memory.
                guard self.clients.count < 8 else { connection.cancel(); return }
                let id = UUID()
                let client = NodeHTTPConnection(
                    connection: connection, queue: self.queue, token: self.token,
                    handler: self.handler,
                    onClose: { [weak self] in self?.clients.removeValue(forKey: id) })
                self.clients[id] = client
                client.start()
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        performOnQueue { stopOnQueue() }
    }

    private func performOnQueue<T>(_ operation: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: queueKey) == true { return try operation() }
        return try queue.sync(execute: operation)
    }

    private func stopOnQueue() {
        let oldListener = listener
        listener = nil
        oldListener?.cancel()
        let existing = Array(clients.values)
        existing.forEach { $0.close(error: NodeHTTPError.disconnected) }
        stateHandler?("stopped")
    }
}

/// All mutable state lives on the server's serial queue, including Network callbacks.
nonisolated fileprivate final class NodeHTTPConnection: @unchecked Sendable {
    private static let maximumHeaderBytes = 16 * 1024
    private static let maximumBodyBytes = 64 * 1024
    private let connection: NWConnection
    private let queue: DispatchQueue
    private let token: [UInt8]
    private let handler: NodeHTTPServer.Handler
    private let onClose: @Sendable () -> Void
    private var input = Data()
    private var head: (method: String, path: String, headers: [String: String], length: Int)?
    private var requestComplete = false
    private var closed = false
    private var handlerTask: Task<Void, Never>?
    private var requestTimer: DispatchSourceTimer?
    private var writeTimer: DispatchSourceTimer?
    private enum Mode { case idle, json, sse, finished }
    private var mode: Mode = .idle
    private struct Write {
        let id = UUID()
        let data: Data?
        let final: Bool
        let complete: @Sendable (Result<Void, Error>) -> Void
    }
    private var writes: [Write] = []
    private var pendingBytes = 0

    init(
        connection: NWConnection, queue: DispatchQueue, token: [UInt8],
        handler: @escaping NodeHTTPServer.Handler, onClose: @escaping @Sendable () -> Void
    ) {
        self.connection = connection
        self.queue = queue
        self.token = token
        self.handler = handler
        self.onClose = onClose
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.requestTimer = self.timer(seconds: 15) { [weak self] in
                    self?.failRequest(status: 408, message: "request_timeout")
                }
                self.receive()
            case .failed(let error): self.close(error: error)
            case .cancelled: self.close(error: NodeHTTPError.disconnected)
            default: break
            }
        }
        connection.start(queue: queue)
    }

    private func timer(seconds: Double, action: @escaping @Sendable () -> Void) -> DispatchSourceTimer {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + seconds)
        timer.setEventHandler(handler: action)
        timer.resume()
        return timer
    }

    private func receive() {
        guard !closed else { return }
        // After dispatch, leave a read outstanding to notice a disconnect and cancel inference.
        connection.receive(minimumIncompleteLength: 1, maximumLength: requestComplete ? 1 : 16 * 1024) {
            [weak self] data, _, complete, error in
            guard let self, !self.closed else { return }
            if let error { self.close(error: error); return }
            if self.requestComplete {
                // Persistent connections and request pipelining are intentionally unsupported.
                if complete || !(data?.isEmpty ?? true) {
                    self.close(error: NodeHTTPError.disconnected)
                } else { self.receive() }
                return
            }
            if let data, !data.isEmpty {
                self.input.append(data)
                self.parseRequest()
            }
            guard !self.closed else { return }
            if complete {
                self.close(error: NodeHTTPError.disconnected)
            } else if !self.requestComplete || self.handlerTask != nil {
                self.receive()
            }
        }
    }

    private func parseRequest() {
        guard !requestComplete else { return }
        if head == nil {
            guard let end = input.range(of: Data([13, 10, 13, 10])) else {
                if input.count >= Self.maximumHeaderBytes {
                    failRequest(status: 431, message: "headers_too_large")
                }
                return
            }
            guard end.upperBound <= Self.maximumHeaderBytes else {
                failRequest(status: 431, message: "headers_too_large"); return
            }
            let bytes = input[..<end.lowerBound]
            guard bytes.allSatisfy({ $0 == 13 || $0 == 10 || $0 == 9 || (32...126).contains($0) }),
                let text = String(data: bytes, encoding: .ascii)
            else { failRequest(status: 400, message: "invalid_headers"); return }
            let lines = text.components(separatedBy: "\r\n")
            let requestLine = lines[0].components(separatedBy: " ")
            guard requestLine.count == 3, requestLine[2] == "HTTP/1.1",
                !requestLine[0].isEmpty, requestLine[0].utf8.allSatisfy(Self.isToken),
                requestLine[1].hasPrefix("/"), !requestLine[1].contains("#"),
                requestLine[1].utf8.allSatisfy({ (33...126).contains($0) })
            else { failRequest(status: 400, message: "invalid_request_line"); return }
            var headers: [String: String] = [:]
            for line in lines.dropFirst() {
                guard let colon = line.firstIndex(of: ":") else {
                    failRequest(status: 400, message: "invalid_header"); return
                }
                let name = String(line[..<colon]).lowercased()
                let value = String(line[line.index(after: colon)...])
                    .trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty, name.utf8.allSatisfy(Self.isToken), headers[name] == nil,
                    !value.contains("\r"), !value.contains("\n")
                else { failRequest(status: 400, message: "duplicate_or_invalid_header"); return }
                headers[name] = value
            }
            guard let host = headers["host"], !host.isEmpty else {
                failRequest(status: 400, message: "host_required"); return
            }
            guard headers["transfer-encoding"] == nil else {
                failRequest(status: 400, message: "transfer_encoding_unsupported"); return
            }
            guard headers["expect"] == nil else {
                failRequest(status: 417, message: "expectation_unsupported"); return
            }
            guard authorized(headers["authorization"]) else {
                failRequest(status: 401, message: "unauthorized"); return
            }
            let length: Int
            if let value = headers["content-length"] {
                guard !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) }),
                    let parsed = Int(value)
                else { failRequest(status: 400, message: "invalid_content_length"); return }
                length = parsed
            } else {
                if requestLine[0] == "POST" {
                    failRequest(status: 411, message: "content_length_required"); return
                }
                length = 0
            }
            guard length <= Self.maximumBodyBytes else {
                failRequest(status: 413, message: "body_too_large"); return
            }
            head = (requestLine[0], requestLine[1], headers, length)
            input.removeSubrange(..<end.upperBound)
        }
        guard let head else { return }
        guard input.count <= head.length else {
            failRequest(status: 400, message: "pipelining_unsupported"); return
        }
        guard input.count == head.length else { return }
        requestComplete = true
        requestTimer?.cancel()
        requestTimer = nil
        let request = NodeHTTPRequest(
            method: head.method, path: head.path, headers: head.headers, body: input)
        input = Data()
        let response = NodeHTTPResponse(connection: self)
        let handler = handler
        handlerTask = Task {
            await handler(request, response)
            if !Task.isCancelled { try? await response.finish() }
        }
    }

    private static func isToken(_ value: UInt8) -> Bool {
        (48...57).contains(value) || (65...90).contains(value) || (97...122).contains(value)
            || Array("!#$%&'*+-.^_`|~".utf8).contains(value)
    }

    private func authorized(_ header: String?) -> Bool {
        guard let header else { return false }
        let parts = header.split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0].lowercased() == "bearer" else { return false }
        let supplied = Array(parts[1].utf8)
        // Do not return early on a differing byte. Token length is not a secret.
        var difference = supplied.count ^ token.count
        for index in token.indices {
            difference |= Int(token[index] ^ (index < supplied.count ? supplied[index] : 0))
        }
        return difference == 0
    }

    private func failRequest(status: Int, message: String) {
        guard !closed, !requestComplete else { return }
        requestComplete = true
        requestTimer?.cancel()
        requestTimer = nil
        input = Data()
        mode = .json
        let body = Data("{\"error\":{\"message\":\"\(message)\",\"type\":\"transport_error\"}}".utf8)
        enqueue(data: Self.jsonResponse(status: status, data: body), final: true) { _ in }
    }

    func isConnected() async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: !self.closed) }
        }
    }

    func sendJSON(status: Int, data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                guard !self.closed else {
                    continuation.resume(throwing: NodeHTTPError.disconnected); return
                }
                guard self.mode == .idle else {
                    continuation.resume(throwing: NodeHTTPError.invalidResponseState); return
                }
                self.mode = .json
                self.enqueue(data: Self.jsonResponse(status: status, data: data), final: true) {
                    continuation.resume(with: $0)
                }
            }
        }
    }

    func startSSE() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                guard !self.closed else {
                    continuation.resume(throwing: NodeHTTPError.disconnected); return
                }
                guard self.mode == .idle else {
                    continuation.resume(throwing: NodeHTTPError.invalidResponseState); return
                }
                self.mode = .sse
                let header = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream; charset=utf-8\r\nCache-Control: no-cache\r\nConnection: close\r\nX-Content-Type-Options: nosniff\r\n\r\n"
                self.enqueue(data: Data(header.utf8), final: false) {
                    continuation.resume(with: $0)
                }
            }
        }
    }

    func sendSSE(data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                guard !self.closed else {
                    continuation.resume(throwing: NodeHTTPError.disconnected); return
                }
                guard self.mode == .sse else {
                    continuation.resume(throwing: NodeHTTPError.invalidResponseState); return
                }
                self.enqueue(data: data, final: false) { continuation.resume(with: $0) }
            }
        }
    }

    func finish() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                guard !self.closed, self.mode != .finished, self.mode != .json else {
                    continuation.resume(); return
                }
                let wasIdle = self.mode == .idle
                self.mode = .finished
                self.enqueue(
                    data: wasIdle ? Self.jsonResponse(status: 204, data: Data()) : nil, final: true
                ) { continuation.resume(with: $0) }
            }
        }
    }

    private static func jsonResponse(status: Int, data: Data) -> Data {
        let reasons = [200: "OK", 202: "Accepted", 204: "No Content", 400: "Bad Request", 401: "Unauthorized",
            404: "Not Found", 405: "Method Not Allowed", 408: "Request Timeout",
            409: "Conflict", 411: "Length Required", 413: "Payload Too Large",
            417: "Expectation Failed", 422: "Unprocessable Content", 429: "Too Many Requests",
            431: "Request Header Fields Too Large", 500: "Internal Server Error",
            503: "Service Unavailable"]
        let safeStatus = (100...599).contains(status) ? status : 500
        let challenge = safeStatus == 401 ? "WWW-Authenticate: Bearer\r\n" : ""
        var result = Data(("HTTP/1.1 \(safeStatus) \(reasons[safeStatus] ?? "Response")\r\n"
            + "Content-Type: application/json; charset=utf-8\r\nContent-Length: \(data.count)\r\n"
            + "Connection: close\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\n"
            + challenge + "\r\n").utf8)
        result.append(data)
        return result
    }

    private func enqueue(
        data: Data?, final: Bool, complete: @escaping @Sendable (Result<Void, Error>) -> Void
    ) {
        guard !closed else { complete(.failure(NodeHTTPError.disconnected)); return }
        guard writes.count < 8, pendingBytes + (data?.count ?? 0) <= 1024 * 1024 else {
            complete(.failure(NodeHTTPError.tooManyPendingWrites))
            close(error: NodeHTTPError.tooManyPendingWrites)
            return
        }
        pendingBytes += data?.count ?? 0
        writes.append(Write(data: data, final: final, complete: complete))
        if writes.count == 1 { writeNext() }
    }

    private func writeNext() {
        guard !closed, let write = writes.first else { return }
        writeTimer = timer(seconds: 15) { [weak self] in
            self?.close(error: NodeHTTPError.writeTimedOut)
        }
        connection.send(
            content: write.data,
            contentContext: write.final ? .finalMessage : .defaultMessage,
            isComplete: write.final,
            completion: .contentProcessed { [weak self] error in
                guard let self, !self.closed, self.writes.first?.id == write.id else { return }
                self.writeTimer?.cancel()
                self.writeTimer = nil
                if let error { self.close(error: error); return }
                self.writes.removeFirst()
                self.pendingBytes -= write.data?.count ?? 0
                write.complete(.success(()))
                if write.final {
                    self.close(error: nil)
                } else { self.writeNext() }
            })
    }

    func close(error: Error?) {
        guard !closed else { return }
        closed = true
        requestTimer?.cancel()
        requestTimer = nil
        writeTimer?.cancel()
        writeTimer = nil
        if error != nil { handlerTask?.cancel() }
        handlerTask = nil
        let waiting = writes
        writes.removeAll()
        pendingBytes = 0
        waiting.forEach { $0.complete(.failure(error ?? NodeHTTPError.disconnected)) }
        connection.cancel()
        onClose()
    }
}
