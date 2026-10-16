import CryptoKit
import Foundation
import SwiftUI

private nonisolated struct InstalledModel: Codable {
    let modelID: String
    let revision: String
    let relativeSnapshot: String
    let verifiedAt: Date
}

nonisolated enum ModelStoreError: LocalizedError {
    case invalid(String)
    var errorDescription: String? {
        switch self { case .invalid(let message): message }
    }
}

@Observable @MainActor
final class ModelStore {
    let catalog = ModelCatalog.items
    private(set) var active: NodeModel
    private(set) var installedIDs = Set<String>()
    private(set) var downloadingID: String?
    private(set) var progress = 0.0
    private(set) var downloadedBytes: Int64 = 0
    private(set) var totalDownloadBytes: Int64 = 0
    @ObservationIgnored private var receivingBytes = false
    private(set) var phase = ""
    private(set) var message = ""
    private(set) var freeDiskBytes: Int64 = 0
    @ObservationIgnored private var downloadTask: Task<Void, Never>?
    @ObservationIgnored private var operationID: UUID?
    @ObservationIgnored private let root: URL

    init(root: URL? = nil) {
        self.root = root ?? URL.applicationSupportDirectory.appending(path: "NodeModels", directoryHint: .isDirectory)
        let selected = UserDefaults.standard.string(forKey: "node.activeModel")
        active = ModelCatalog.items.first { $0.id == selected } ?? ModelCatalog.defaultModel
        try? FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
        var url = self.root
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
        refresh()
        if !installedIDs.contains(active.id), let fallback = catalog.first(where: { installedIDs.contains($0.id) }) {
            active = fallback
        }
    }

    func model(_ id: String) -> NodeModel? { catalog.first { $0.id == id } }
    func selectForLoading(_ model: NodeModel) { active = model }
    func persistSelection() { UserDefaults.standard.set(active.id, forKey: "node.activeModel") }
    func report(_ text: String) { message = text }

    private func base(_ model: NodeModel) -> URL { root.appending(path: model.directoryKey, directoryHint: .isDirectory) }
    private func manifestURL(_ model: NodeModel) -> URL { base(model).appending(path: "installed.json") }

    func directory(for model: NodeModel) -> URL? {
        if model.id == ModelCatalog.defaultModel.id {
            let legacy = URL.documentsDirectory.appending(path: "model", directoryHint: .isDirectory)
            if (try? Self.validateLayout(at: legacy, model: model)) != nil { return legacy }
        }
        guard let data = try? Data(contentsOf: manifestURL(model)),
            let manifest = try? JSONDecoder().decode(InstalledModel.self, from: data),
            manifest.modelID == model.id, manifest.revision == model.revision,
            !manifest.relativeSnapshot.hasPrefix("/"), !manifest.relativeSnapshot.split(separator: "/").contains("..") else { return nil }
        let directory = base(model).appending(path: manifest.relativeSnapshot)
        guard (try? Self.validateLayout(at: directory, model: model)) != nil else { return nil }
        return directory
    }

    func refresh() {
        installedIDs = Set(catalog.filter { directory(for: $0) != nil }.map(\.id))
        let attributes = try? FileManager.default.attributesOfFileSystem(forPath: root.path)
        freeDiskBytes = (attributes?[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
    }

    func startDownload(_ id: String) throws {
        guard downloadingID == nil else { throw ModelStoreError.invalid("已有下载任务，请先等待或取消。") }
        guard let model = model(id) else { throw ModelStoreError.invalid("请选择列表中的模型。") }
        if directory(for: model) != nil { message = "模型已安装，可直接加载。"; return }
        refresh()
        guard freeDiskBytes >= model.downloadBytes + 512 * 1024 * 1024 else {
            throw ModelStoreError.invalid("磁盘空间不足；请为模型及临时文件预留空间。")
        }
        let operation = UUID()
        operationID = operation
        downloadingID = model.id
        progress = 0
        downloadedBytes = 0
        totalDownloadBytes = model.downloadBytes
        phase = "正在连接模型源"
        message = "请保持 App 前台；下载并校验完成后才能加载。中断后可继续下载。"
        let modelRoot = base(model)
        downloadTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.operationID == operation {
                    self.receivingBytes = false
                    self.downloadingID = nil
                    self.downloadTask = nil
                    self.operationID = nil
                    self.refresh()
                }
            }
            do {
                try FileManager.default.createDirectory(at: modelRoot, withIntermediateDirectories: true)
                let directory = modelRoot.appending(path: "files", directoryHint: .isDirectory)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                self.receivingBytes = true
                var completedBytes: Int64 = 0
                self.record("download_started", model: model)
                for file in model.files {
                    try Task.checkCancellation()
                    let recovered = try await Task.detached(priority: .utility) {
                        try Self.prepareFile(file, model: model, root: modelRoot, directory: directory)
                    }.value
                    if recovered > 0 { self.record("download_prefix_recovered", model: model, bytes: recovered) }
                    let destination = directory.appending(path: file.name)
                    if Self.fileSize(destination) == file.bytes {
                        completedBytes += file.bytes
                        self.updateProgress(completedBytes)
                        continue
                    }
                    let partial = destination.appendingPathExtension("partial")
                    let beforeFile = completedBytes
                    self.updateProgress(beforeFile + Self.fileSize(partial))
                    for attempt in 1...3 {
                        let url = URL(string: "https://huggingface.co/" + model.id + "/resolve/" + model.revision + "/" + file.name + "?download=true&node_request=" + UUID().uuidString)!
                        let download = ModelFileDownload(url: url, partial: partial, expectedBytes: file.bytes) { [weak self] bytes in
                            Task { @MainActor in
                                guard let self, self.operationID == operation, self.receivingBytes else { return }
                                self.updateProgress(beforeFile + bytes)
                            }
                        }
                        do { try await download.download(); break }
                        catch {
                            let network = error as NSError
                            let transient = network.domain == NSURLErrorDomain && [-1001, -1003, -1004, -1005, -1009, -1200].contains(network.code)
                            guard !Task.isCancelled, transient, attempt < 3 else { throw error }
                            self.phase = "连接中断，已保留进度；正在重试 \(attempt)/2"
                            self.record("download_retry", model: model, bytes: Self.fileSize(partial))
                            try await Task.sleep(for: .seconds(attempt * 2))
                        }
                    }
                    try Task.checkCancellation()
                    try FileManager.default.moveItem(at: partial, to: destination)
                    completedBytes += file.bytes
                    self.updateProgress(completedBytes)
                }
                self.receivingBytes = false
                try Task.checkCancellation()
                self.phase = "正在校验文件完整性"
                let verification = Task.detached(priority: .utility) {
                    try Self.validateLayout(at: directory, model: model)
                    for file in model.files {
                        try Task.checkCancellation()
                        if let expected = file.sha256 {
                            guard try Self.sha256(directory.appending(path: file.name)) == expected else {
                                throw ModelStoreError.invalid("文件校验失败：\(file.name)。请删除下载后重新尝试。")
                            }
                        }
                        if let expected = file.gitBlobSHA1,
                            try Self.gitBlobHash(directory.appending(path: file.name)) != expected {
                            throw ModelStoreError.invalid("配置文件校验失败：\(file.name)。请删除下载后重新尝试。")
                        }
                    }
                }
                try await withTaskCancellationHandler {
                    try await verification.value
                } onCancel: { verification.cancel() }
                try Task.checkCancellation()
                let relative = "files"
                let manifest = InstalledModel(modelID: model.id, revision: model.revision,
                    relativeSnapshot: relative, verifiedAt: Date())
                try JSONEncoder().encode(manifest).write(to: self.manifestURL(model), options: .atomic)
                self.progress = 1
                self.refresh()
                guard self.installedIDs.contains(model.id) else { throw ModelStoreError.invalid("下载已完成，但安装清单未通过验证，请重试。") }
                self.phase = "已校验，可加载"
                self.record("download_verified", model: model)
                self.message = "\(model.title) 已校验，可点“加载”切换。"
            } catch {
                let cancelled = Task.isCancelled || error is CancellationError || (error as NSError).code == NSURLErrorCancelled
                self.phase = cancelled ? "下载已取消" : "下载失败"
                self.message = cancelled ? "下载未完成；点“继续下载”将复用已保存的进度，校验完成后才能加载。" : error.localizedDescription
                self.record(cancelled ? "download_paused" : "download_failed", model: model, bytes: self.downloadedBytes)
            }
        }
    }

    func cancelDownload() {
        guard downloadTask != nil else { return }
        phase = "正在取消下载"
        downloadTask?.cancel()
    }

    func delete(_ id: String) throws {
        guard downloadingID == nil else { throw ModelStoreError.invalid("请先结束下载。") }
        guard let model = model(id), model.id != active.id else {
            throw ModelStoreError.invalid("请先切换到其他模型，再删除此模型。")
        }
        let directory = base(model)
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
        refresh()
        message = "已删除此模型的下载与缓存；预装的 4B 文件会保留。"
    }

    func state() -> [String: Any] {
        ["active_model": active.id, "downloading_model": downloadingID as Any? ?? NSNull(),
         "progress": progress, "downloaded_bytes": downloadedBytes, "total_download_bytes": totalDownloadBytes, "phase": phase, "message": message,
         "data": catalog.map { model in
             ["id": model.id, "title": model.title, "revision": model.revision,
              "quantization_bits": model.bits, "quantization_group_size": model.groupSize,
              "download_bytes": model.downloadBytes, "installed": installedIDs.contains(model.id),
              "active": model.id == active.id, "saved_bytes": savedBytes(for: model)] as [String: Any]
         }]
    }

    func savedBytes(for model: NodeModel) -> Int64 {
        if directory(for: model) != nil { return model.downloadBytes }
        let modelRoot = base(model)
        let directory = modelRoot.appending(path: "files")
        let old = modelRoot.appending(path: "cache/models--" + model.id.replacingOccurrences(of: "/", with: "--") + "/snapshots/" + model.revision)
        return model.files.reduce(0) { total, file in
            let destination = directory.appending(path: file.name)
            return total + min(file.bytes, max(Self.fileSize(destination), max(Self.fileSize(destination.appendingPathExtension("partial")), Self.fileSize(old.appending(path: file.name)))))
        }
    }

    private func updateProgress(_ bytes: Int64) {
        downloadedBytes = min(totalDownloadBytes, max(0, bytes))
        progress = totalDownloadBytes > 0 ? Double(downloadedBytes) / Double(totalDownloadBytes) : 0
        // 100% bytes still requires hash verification before an installed model exists.
        phase = "正在下载 " + String(format: "%.1f%%", progress * 100)
    }

    private func record(_ name: String, model: NodeModel, bytes: Int64? = nil) {
        let row: [String: Any] = ["event": name, "model": model.id, "date": ISO8601DateFormatter().string(from: Date()), "bytes": bytes ?? downloadedBytes]
        guard let data = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]) else { return }
        let url = URL.documentsDirectory.appending(path: "model-events.jsonl")
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        guard let file = try? FileHandle(forWritingTo: url) else { return }
        defer { try? file.close() }
        _ = try? file.seekToEnd()
        try? file.write(contentsOf: data + Data([10]))
    }

    private nonisolated static func fileSize(_ url: URL) -> Int64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.resolvingSymlinksInPath().path)
        return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    }

    private nonisolated static func prefixHash(_ url: URL) throws -> String {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let data = try file.read(upToCount: 65536) ?? Data()
        guard data.count == 65536 else { return "" }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private nonisolated static func gitBlobHash(_ url: URL) throws -> String {
        guard fileSize(url) <= 16 * 1024 * 1024 else { return "" }
        let data = try Data(contentsOf: url)
        var hash = Insecure.SHA1()
        hash.update(data: Data("blob \(data.count)\0".utf8))
        hash.update(data: data)
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private nonisolated static func prepareFile(_ file: ModelFile, model: NodeModel, root: URL, directory: URL) throws -> Int64 {
        let manager = FileManager.default
        let destination = directory.appending(path: file.name)
        if fileSize(destination) == file.bytes { return 0 }
        if manager.fileExists(atPath: destination.path) { try manager.removeItem(at: destination) }
        let sharedFile = ModelCatalog.defaultModel.files.contains {
            $0.name == file.name && ((file.sha256 != nil && $0.sha256 == file.sha256)
                || (file.gitBlobSHA1 != nil && $0.gitBlobSHA1 == file.gitBlobSHA1))
        }
        if sharedFile {
            let legacy = URL.documentsDirectory.appending(path: "model/" + file.name)
            if fileSize(legacy) == file.bytes {
                try manager.copyItem(at: legacy, to: destination)
                return 0
            }
        }
        let old = root.appending(path: "cache/models--" + model.id.replacingOccurrences(of: "/", with: "--") + "/snapshots/" + model.revision + "/" + file.name).resolvingSymlinksInPath()
        if fileSize(old) == file.bytes {
            do { try manager.linkItem(at: old, to: destination) }
            catch { try manager.copyItem(at: old, to: destination) }
            return 0
        }
        let partial = destination.appendingPathExtension("partial")
        if fileSize(partial) > file.bytes { try manager.removeItem(at: partial) }
        let candidates = (try? manager.contentsOfDirectory(at: URL.temporaryDirectory, includingPropertiesForKeys: nil)) ?? []
        if let expected = file.gitBlobSHA1 {
            for candidate in candidates where candidate.lastPathComponent.hasPrefix("CFNetworkDownload_") && candidate.pathExtension == "tmp" {
                try Task.checkCancellation()
                if fileSize(candidate) == file.bytes, (try? gitBlobHash(candidate)) == expected {
                    try manager.moveItem(at: candidate, to: destination)
                    return file.bytes
                }
            }
        }
        guard let prefix = file.prefixSHA256 else { return 0 }
        if fileSize(partial) >= 65536, try prefixHash(partial) != prefix { try manager.removeItem(at: partial) }
        var best: URL?
        var bestSize = fileSize(partial)
        for candidate in candidates where candidate.lastPathComponent.hasPrefix("CFNetworkDownload_") && candidate.pathExtension == "tmp" {
            try Task.checkCancellation()
            let size = fileSize(candidate)
            if size > bestSize, size <= file.bytes, size >= 65536, (try? prefixHash(candidate)) == prefix {
                best = candidate; bestSize = size
            }
        }
        guard let best else { return 0 }
        if manager.fileExists(atPath: partial.path) { try manager.removeItem(at: partial) }
        try manager.moveItem(at: best, to: partial)
        return bestSize
    }

    private nonisolated static func validateLayout(at directory: URL, model: NodeModel) throws {
        for file in model.files {
            let attributes = try FileManager.default.attributesOfItem(atPath: directory.appending(path: file.name).resolvingSymlinksInPath().path)
            guard (attributes[.size] as? NSNumber)?.int64Value == file.bytes else {
                throw ModelStoreError.invalid("模型文件不完整：\(file.name)")
            }
        }
        let config = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appending(path: "config.json"))) as? [String: Any]
        let quantization = config?["quantization"] as? [String: Any]
        guard config?["model_type"] as? String == "qwen3", config?["hidden_size"] as? Int == model.hiddenSize,
            quantization?["bits"] as? Int == model.bits, quantization?["group_size"] as? Int == model.groupSize else {
            throw ModelStoreError.invalid("模型架构或量化配置与目录清单不一致。")
        }
    }

    private nonisolated static func sha256(_ url: URL) throws -> String {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var hash = SHA256()
        while try autoreleasepool(invoking: {
            try Task.checkCancellation()
            guard let data = try file.read(upToCount: 8 * 1024 * 1024), !data.isEmpty else { return false }
            hash.update(data: data)
            return true
        }) {}
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
