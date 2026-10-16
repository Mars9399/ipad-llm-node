import Foundation

nonisolated struct ModelFile: Codable, Sendable {
    let name: String
    let bytes: Int64
    let sha256: String?
}

nonisolated struct NodeModel: Codable, Identifiable, Sendable {
    let id: String
    let title: String
    let revision: String
    let bits: Int
    let groupSize: Int
    let hiddenSize: Int
    let files: [ModelFile]
    var downloadBytes: Int64 { files.reduce(0) { $0 + $1.bytes } }
    var directoryKey: String { id.replacingOccurrences(of: "/", with: "--") + "/" + revision }
    var isLarge: Bool { downloadBytes > 3_000_000_000 }
}

enum ModelCatalog {
    nonisolated static let items: [NodeModel] = [
        NodeModel(id: "mlx-community/Qwen3-4B-4bit", title: "Qwen3 4B · 默认推荐", revision: "4dcb3d101c2a062e5c1d4bb173588c54ea6c4d25", bits: 4, groupSize: 64, hiddenSize: 2560, files: [
            ModelFile(name: "added_tokens.json", bytes: 707, sha256: nil),
            ModelFile(name: "config.json", bytes: 937, sha256: nil),
            ModelFile(name: "model.safetensors", bytes: 2263022529, sha256: "e240c0bdc0ebb0681bf0da0f98d9719fd6ebe269a3633f81542c13e81345651d"),
            ModelFile(name: "model.safetensors.index.json", bytes: 63924, sha256: nil),
            ModelFile(name: "special_tokens_map.json", bytes: 613, sha256: nil),
            ModelFile(name: "tokenizer.json", bytes: 11422654, sha256: "aeb13307a71acd8fe81861d94ad54ab689df773318809eed3cbe794b4492dae4"),
            ModelFile(name: "tokenizer_config.json", bytes: 9706, sha256: nil),
            ModelFile(name: "vocab.json", bytes: 2776833, sha256: nil),
        ]),
        NodeModel(id: "Qwen/Qwen3-8B-MLX-4bit", title: "Qwen3 8B · 4bit · 待性能验证", revision: "383413e909f3bc5303ce195ebbdf0339c5a1a2a3", bits: 4, groupSize: 128, hiddenSize: 4096, files: [
            ModelFile(name: "config.json", bytes: 941, sha256: nil),
            ModelFile(name: "model.safetensors", bytes: 4351884216, sha256: "fcc83d7537bee76cc143be3e25f8954b816798f93528103db1cddb02977c5617"),
            ModelFile(name: "model.safetensors.index.json", bytes: 64065, sha256: nil),
            ModelFile(name: "tokenizer.json", bytes: 11422654, sha256: "aeb13307a71acd8fe81861d94ad54ab689df773318809eed3cbe794b4492dae4"),
            ModelFile(name: "tokenizer_config.json", bytes: 9690, sha256: nil),
            ModelFile(name: "vocab.json", bytes: 2776833, sha256: nil),
        ]),
        NodeModel(id: "mlx-community/Qwen3-8B-3bit", title: "Qwen3 8B · 3bit · 节省内存", revision: "619ded35b7d1d083ccafc367ea5ccdab1840b74d", bits: 3, groupSize: 64, hiddenSize: 4096, files: [
            ModelFile(name: "added_tokens.json", bytes: 707, sha256: nil),
            ModelFile(name: "config.json", bytes: 939, sha256: nil),
            ModelFile(name: "model.safetensors", bytes: 3584031644, sha256: "b9694bdb1f737223836235c0427b424ace11d566eeab0ac91ff8050143bd20a1"),
            ModelFile(name: "model.safetensors.index.json", bytes: 64065, sha256: nil),
            ModelFile(name: "special_tokens_map.json", bytes: 613, sha256: nil),
            ModelFile(name: "tokenizer.json", bytes: 11422654, sha256: "aeb13307a71acd8fe81861d94ad54ab689df773318809eed3cbe794b4492dae4"),
            ModelFile(name: "tokenizer_config.json", bytes: 9706, sha256: nil),
            ModelFile(name: "vocab.json", bytes: 2776833, sha256: nil),
        ]),
        NodeModel(id: "mlx-community/Qwen3-0.6B-4bit", title: "Qwen3 0.6B · 快速下载测试", revision: "73e3e38d981303bc594367cd910ea6eb48349da8", bits: 4, groupSize: 64, hiddenSize: 1024, files: [
            ModelFile(name: "added_tokens.json", bytes: 707, sha256: nil),
            ModelFile(name: "config.json", bytes: 937, sha256: nil),
            ModelFile(name: "model.safetensors", bytes: 335450584, sha256: "392e8d466d56100ada00eb82031fb854297fc9e389b7d303eba3af114e87bce2"),
            ModelFile(name: "model.safetensors.index.json", bytes: 49731, sha256: nil),
            ModelFile(name: "special_tokens_map.json", bytes: 613, sha256: nil),
            ModelFile(name: "tokenizer.json", bytes: 11422654, sha256: "aeb13307a71acd8fe81861d94ad54ab689df773318809eed3cbe794b4492dae4"),
            ModelFile(name: "tokenizer_config.json", bytes: 9706, sha256: nil),
            ModelFile(name: "vocab.json", bytes: 2776833, sha256: nil),
        ]),
    ]
    nonisolated static var defaultModel: NodeModel { items[0] }
}
