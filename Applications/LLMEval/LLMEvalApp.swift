// Copyright © 2024 Apple Inc.

import SwiftUI

@main
struct LLMEvalApp: App {
    @State private var models: ModelStore
    @State private var llm: LLMEvaluator
    @State private var node: LLMNodeService

    init() {
        let models = ModelStore()
        _models = State(initialValue: models)
        _llm = State(initialValue: LLMEvaluator(models: models))
        _node = State(initialValue: LLMNodeService(models: models))
    }
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView(llm: llm, node: node, models: models)
                .environment(DeviceStat())
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { models.cancelDownload(); node.pauseForBackground() }
            else if phase == .active { Task { await node.resume(evaluator: llm) } }
        }
    }
}
