import SwiftUI

struct ModelManagerView: View {
    let models: ModelStore
    let llm: LLMEvaluator
    let node: LLMNodeService
    @Environment(\.dismiss) private var dismiss
    @State private var deleting: NodeModel?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("选择模型，下载完成后点“加载”。内存中只保留一个模型；切换会取消当前生成。")
                    Text("请保持 App 前台。下载并校验完成后才能加载；取消或断线后可继续下载。")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("可用存储：" + ByteCountFormatter.string(fromByteCount: models.freeDiskBytes, countStyle: .file))
                    if !models.message.isEmpty { Text(models.message).textSelection(.enabled) }
                    if models.downloadingID != nil {
                        ProgressView(value: models.progress)
                        HStack {
                            Text(models.phase + " · " + ByteCountFormatter.string(fromByteCount: models.downloadedBytes, countStyle: .file) + " / " + ByteCountFormatter.string(fromByteCount: models.totalDownloadBytes, countStyle: .file))
                            Spacer()
                            Button("取消下载", role: .cancel) { models.cancelDownload() }
                                .accessibilityIdentifier("modelManager.cancel")
                        }
                    }
                    if node.switchingModel { ProgressView("正在释放旧模型并加载新模型…") }
                }
                Section("可用模型") {
                    ForEach(models.catalog) { model in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(model.title).font(.headline)
                                Spacer()
                                if model.id == models.active.id {
                                    Text("当前选择").font(.caption).foregroundStyle(.green)
                                }
                            }
                            Text(model.id).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                            Text(ByteCountFormatter.string(fromByteCount: model.downloadBytes, countStyle: .file)
                                + " · \(model.bits)bit · Apache-2.0")
                                .font(.caption)
                            if model.isLarge {
                                Text("更大模型需要更多运行内存；此版本尚未完成持续性能验证。")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            HStack {
                                let installed = models.installedIDs.contains(model.id)
                                if installed {
                                    Label("已校验", systemImage: "checkmark.circle")
                                } else {
                                    Button(models.savedBytes(for: model) > 0 ? "继续下载" : "下载") {
                                        do { try models.startDownload(model.id) }
                                        catch { models.report(error.localizedDescription) }
                                    }.accessibilityIdentifier("modelManager.download." + model.id)
                                }
                                Button(model.id == models.active.id ? "重新加载" : "加载") {
                                    Task { await node.switchModel(to: model.id, evaluator: llm) }
                                }
                                .disabled(!installed)
                                .accessibilityIdentifier("modelManager.activate." + model.id)
                                Spacer()
                                Button("删除下载", role: .destructive) { deleting = model }
                                    .disabled(model.id == models.active.id)
                            }.buttonStyle(.bordered)
                                .disabled(models.downloadingID != nil || node.switchingModel)
                            if !models.installedIDs.contains(model.id) {
                                Text(models.downloadingID == model.id ? "文件下载并校验完成后，“加载”会自动变为可用。" : "尚未下载完整，暂不能加载。")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }.padding(.vertical, 4)
                    }
                }
            }
            .navigationTitle("模型管理")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .onAppear { models.refresh() }
            .alert("删除模型下载？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), presenting: deleting) { model in
                Button("删除", role: .destructive) {
                    do { try models.delete(model.id) } catch { models.report(error.localizedDescription) }
                    deleting = nil
                }
                Button("取消", role: .cancel) { deleting = nil }
            } message: { model in Text("将删除 " + model.title + " 的下载文件与缓存。") }
        }.frame(minWidth: 520, minHeight: 500)
    }
}
