import Foundation

nonisolated enum ModelDownloadError: LocalizedError {
    case invalidResponse(String)
    var errorDescription: String? {
        switch self { case .invalidResponse(let text): text }
    }
}

/// Writes bounded URLSession data chunks directly to a persistent partial file.
/// Cancellation and transport errors keep the prefix for a subsequent Range request.
nonisolated final class ModelFileDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let url: URL
    private let partial: URL
    private let expectedBytes: Int64
    private let progress: @Sendable (Int64) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var task: URLSessionDataTask?
    private var cancelled = false
    private var session: URLSession!
    // Accessed only before resume or on the serial delegate queue.
    private var file: FileHandle?
    private var offset: Int64 = 0
    private var received: Int64 = 0
    private var responseAccepted = false
    private var failure: Error?
    private var lastProgress = 0.0

    init(url: URL, partial: URL, expectedBytes: Int64,
         progress: @escaping @Sendable (Int64) -> Void) {
        self.url = url; self.partial = partial; self.expectedBytes = expectedBytes; self.progress = progress
        super.init()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 24 * 60 * 60
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
    }

    func download() async throws {
        defer {
            try? file?.close()
            session.invalidateAndCancel()
        }
        if !FileManager.default.fileExists(atPath: partial.path) {
            guard FileManager.default.createFile(atPath: partial.path, contents: nil) else {
                throw ModelDownloadError.invalidResponse("无法创建下载文件。")
            }
        }
        file = try FileHandle(forWritingTo: partial)
        offset = Int64(try file!.seekToEnd())
        guard offset <= expectedBytes else { throw ModelDownloadError.invalidResponse("下载文件大小异常，请删除该下载后重试。") }
        received = offset
        progress(received)
        if offset == expectedBytes { return }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.lock()
                if cancelled {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                self.continuation = continuation
                var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
                request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
                if offset > 0 { request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range") }
                let task = session.dataTask(with: request)
                self.task = task
                lock.unlock()
                task.resume()
            }
        } onCancel: { self.cancel() }
    }

    private func cancel() {
        lock.lock()
        cancelled = true
        let task = task
        lock.unlock()
        task?.cancel()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        do {
            guard let response = response as? HTTPURLResponse else {
                throw ModelDownloadError.invalidResponse("模型源返回了无效响应。")
            }
            if response.statusCode == 206 {
                guard let header = response.value(forHTTPHeaderField: "Content-Range"),
                    let range = Self.parseContentRange(header), range.start == offset,
                    range.total == expectedBytes, range.end >= range.start, range.end < range.total else {
                    throw ModelDownloadError.invalidResponse("模型源的续传范围不匹配，已保留原有下载文件。")
                }
            } else if response.statusCode == 200 {
                if response.expectedContentLength >= 0 && response.expectedContentLength != expectedBytes {
                    throw ModelDownloadError.invalidResponse("模型源返回的文件大小与固定版本不符。")
                }
                if offset > 0 {
                    // A server may ignore Range; never append a full response to a prefix.
                    try file?.truncate(atOffset: 0)
                    try file?.seek(toOffset: 0)
                    offset = 0
                    received = 0
                    progress(0)
                }
            } else {
                throw ModelDownloadError.invalidResponse("模型下载返回 HTTP \(response.statusCode)，已保留下载进度，可重试。")
            }
            responseAccepted = true
            completionHandler(.allow)
        } catch {
            failure = error
            completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard responseAccepted, failure == nil else { return }
        do {
            guard received + Int64(data.count) <= expectedBytes else {
                throw ModelDownloadError.invalidResponse("模型源发送的数据超出预期，已停止下载。")
            }
            try file?.write(contentsOf: data)
            received += Int64(data.count)
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastProgress >= 0.1 || received == expectedBytes {
                lastProgress = now
                progress(received)
            }
        } catch {
            failure = error
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        var resultError = failure ?? error
        if resultError == nil && (!responseAccepted || received != expectedBytes) {
            resultError = ModelDownloadError.invalidResponse("下载未完成，已保留进度；重试将继续下载。")
        }
        do { try file?.synchronize() } catch { if resultError == nil { resultError = error } }
        lock.lock()
        let continuation = continuation
        self.continuation = nil
        let wasCancelled = cancelled
        lock.unlock()
        if wasCancelled { continuation?.resume(throwing: CancellationError()) }
        else if let resultError { continuation?.resume(throwing: resultError) }
        else { continuation?.resume() }
    }

    private static func parseContentRange(_ header: String) -> (start: Int64, end: Int64, total: Int64)? {
        let pieces = header.split(separator: " ")
        guard pieces.count == 2, pieces[0].lowercased() == "bytes" else { return nil }
        let range = pieces[1].split(separator: "/")
        guard range.count == 2, let total = Int64(range[1]) else { return nil }
        let bounds = range[0].split(separator: "-")
        guard bounds.count == 2, let start = Int64(bounds[0]), let end = Int64(bounds[1]) else { return nil }
        return (start, end, total)
    }
}
