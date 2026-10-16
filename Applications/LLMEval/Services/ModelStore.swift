import CryptoKit
import Foundation
import HuggingFace
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
        phase = "正在连接模型源"
        message = "下载期间请保持 App 前台；取消后可重试，已完成文件会复用。"
        let modelRoot = base(model)
        downloadTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.operationID == operation {
                    self.downloadingID = nil
                    self.downloadTask = nil
                    self.operationID = nil
                    self.refresh()
                }
            }
            do {
                try FileManager.default.createDirectory(at: modelRoot, withIntermediateDirectories: true)
                let configuration = URLSessionConfiguration.default
                configuration.timeoutIntervalForRequest = 60
                configuration.timeoutIntervalForResource = 24 * 60 * 60
                let session = URLSession(configuration: configuration)
                defer { session.invalidateAndCancel() }
                let cache = HubCache(cacheDirectory: modelRoot.appending(path: "cache"))
                let hub = HubClient(session: session, host: URL(string: "https://huggingface.co")!, cache: cache)
                guard let repo = Repo.ID(rawValue: model.id) else { throw ModelStoreError.invalid("模型标识无效。") }
                let snapshot = cache.snapshotsDirectory(repo: repo, kind: .model).appending(path: model.revision)
                // Some CDN responses do not update Foundation's nested Progress while
                // URLSession is receiving bytes. Combine task counters with cached files.
                let progressMonitor = Task { [weak self] in
                    while !Task.isCancelled {
                        let tasks = await session.allTasks
                        guard let self, self.operationID == operation else { return }
                        var received: Int64 = 0
                        for file in model.files {
                            let url = snapshot.appending(path: file.name).resolvingSymlinksInPath()
                            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
                            let cached = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
                            let inFlight = tasks.filter { $0.originalRequest?.url?.lastPathComponent == file.name }
                                .map(\.countOfBytesReceived).max() ?? 0
                            received += min(file.bytes, max(cached, inFlight))
                        }
                        let fraction = min(0.999, Double(received) / Double(model.downloadBytes))
                        self.progress = max(self.progress, fraction)
                        self.phase = "正在下载 \(Int(self.progress * 100))%"
                        do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
                    }
                }
                defer { progressMonitor.cancel() }
                let directory = try await hub.downloadSnapshot(of: repo, revision: model.revision,
                    matching: model.files.map(\.name), maxConcurrentDownloads: 2,
                    progressHandler: { [weak self] value in
                        guard let self, self.operationID == operation, !Task.isCancelled else { return }
                        let fraction = value.fractionCompleted
                        self.progress = max(self.progress, fraction.isFinite ? min(1, max(0, fraction)) : 0)
                        self.phase = "正在下载 \(Int(self.progress * 100))%"
                    })
                progressMonitor.cancel()
                await progressMonitor.value
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
                    }
                }
                try await withTaskCancellationHandler {
                    try await verification.value
                } onCancel: { verification.cancel() }
                try Task.checkCancellation()
                let relative = String(directory.path.dropFirst(modelRoot.path.count + 1))
                let manifest = InstalledModel(modelID: model.id, revision: model.revision,
                    relativeSnapshot: relative, verifiedAt: Date())
                try JSONEncoder().encode(manifest).write(to: self.manifestURL(model), options: .atomic)
                self.progress = 1
                self.phase = "下载完成"
                self.message = "\(model.title) 已校验，可点“加载”切换。"
            } catch {
                let cancelled = Task.isCancelled || error is CancellationError || (error as NSError).code == NSURLErrorCancelled
                self.phase = cancelled ? "下载已取消" : "下载失败"
                self.message = cancelled ? "可点下载重试；已完成文件会复用。" : error.localizedDescription
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
         "progress": progress, "phase": phase, "message": message,
         "data": catalog.map { model in
             ["id": model.id, "title": model.title, "revision": model.revision,
              "quantization_bits": model.bits, "quantization_group_size": model.groupSize,
              "download_bytes": model.downloadBytes, "installed": installedIDs.contains(model.id),
              "active": model.id == active.id] as [String: Any]
         }]
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
        while let data = try file.read(upToCount: 8 * 1024 * 1024), !data.isEmpty {
            try Task.checkCancellation()
            hash.update(data: data)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
