// Copyright © 2025 Apple Inc.

import MLX
import MLXLLM
import MLXLMCommon
import Metal
import SwiftUI
import Tokenizers

struct ContentView: View {
    @Environment(DeviceStat.self) private var deviceStat

    let llm: LLMEvaluator
    let node: LLMNodeService
    let models: ModelStore

    enum DisplayStyle: String, CaseIterable, Identifiable {
        case plain, markdown
        var id: Self { self }
    }

    @State private var selectedDisplayStyle = DisplayStyle.markdown
    @State private var showingModels = false
    @State private var showingPresetPrompts = false
    @State private var isPromptExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Button("模型管理", systemImage: "square.stack.3d.up") { showingModels = true }
                    .accessibilityIdentifier("modelManager.open")
                if models.downloadingID != nil {
                    ProgressView(value: models.progress).frame(maxWidth: 180)
                    Text(models.phase).font(.caption)
                }
                if node.switchingModel { ProgressView("正在安全切换模型") }
                Spacer()
            }.padding(.bottom, 8)
            NodeServiceBar(node: node, llm: llm)
            Divider().padding(.vertical, 6)
            // Header Section
            HeaderView(
                llm: llm,
                selectedDisplayStyle: $selectedDisplayStyle
            )
            .disabled(node.enabled || node.busy || node.switchingModel)

            Divider()
                .padding(.bottom, 12)

            // Output display
            OutputView(
                output: llm.output,
                displayStyle: selectedDisplayStyle,
                wasTruncated: llm.wasTruncated
            )

            // Prompt input section
            PromptInputView(
                llm: llm,
                isPromptExpanded: $isPromptExpanded,
                showingPresetPrompts: $showingPresetPrompts,
                onGenerate: generate,
                onCancel: cancel
            )
            .disabled(node.enabled || node.busy || node.switchingModel)

            // Performance Metrics Panel
            MetricsView(
                tokensPerSecond: llm.tokensPerSecond,
                timeToFirstToken: llm.timeToFirstToken,
                promptLength: llm.promptLength,
                totalTokens: llm.totalTokens,
                totalTime: llm.totalTime,
                memoryUsed: deviceStat.gpuUsage.activeMemory,
                cacheMemory: deviceStat.gpuUsage.cacheMemory,
                peakMemory: deviceStat.gpuUsage.peakMemory
            )
        }
        #if os(visionOS)
            .padding(40)
        #else
            .padding()
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task {
                        copyToClipboard(llm.output)
                    }
                } label: {
                    Label("Copy Output", systemImage: "doc.on.doc.fill")
                }
                .disabled(llm.output == "")
                .labelStyle(.titleAndIcon)
            }

        }
        .task {
                if let index = ProcessInfo.processInfo.arguments.firstIndex(of: "--benchmark-seconds"),
                    ProcessInfo.processInfo.arguments.count > index + 1,
                    let seconds = Double(ProcessInfo.processInfo.arguments[index + 1]) {
                    await llm.runBenchmark(seconds: seconds)
                    return
                }
                await node.start(evaluator: llm)
                if models.installedIDs.isEmpty || ProcessInfo.processInfo.arguments.contains("--show-models") { showingModels = true }
        }
        .sheet(isPresented: $showingModels) {
            ModelManagerView(models: models, llm: llm, node: node)
        }
        .sheet(isPresented: $showingPresetPrompts) {
            PresetPromptsSheet(isPresented: $showingPresetPrompts) { preset in
                llm.prompt = preset.prompt
                llm.includeWeatherTool = preset.enableTools
                llm.enableThinking = preset.enableThinking
            }
        }
        .overlay {
            if llm.isLoading {
                LoadingOverlayView(
                    modelInfo: llm.modelInfo,
                    downloadProgress: llm.downloadProgress,
                    progressDescription: llm.totalSize
                )
            }
        }
    }

    private func generate() {
        llm.generate()
    }

    private func cancel() {
        llm.cancelGeneration()
    }

    private func copyToClipboard(_ string: String) {
        #if os(macOS)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(string, forType: .string)
        #else
            UIPasteboard.general.string = string
        #endif
    }
}


private struct NodeServiceBar: View {
    let node: LLMNodeService
    let llm: LLMEvaluator

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Label(node.status, systemImage: node.ready ? "network" : "network.slash")
                    .font(.headline)
                Text("USB：Mac 127.0.0.1:18080 · 请保持本 App 在前台")
                    .font(.caption).foregroundStyle(.secondary)
                if !node.addresses.isEmpty {
                    Text("局域网：" + node.addresses).font(.caption).textSelection(.enabled)
                }
                if !node.lastRequest.isEmpty { Text(node.lastRequest).font(.caption) }
            }
            Spacer()
            if node.busy {
                Button("取消当前请求") { node.cancelCurrent() }
            }
            if node.enabled {
                Button("复制访问令牌") { node.copyCredential() }
                Button("停止服务") { node.stop() }
            } else {
                Button("启动服务") { Task { await node.start(evaluator: llm) } }
                    .disabled(llm.running || node.busy || node.switchingModel)
            }
        }.accessibilityElement(children: .contain)
    }
}
