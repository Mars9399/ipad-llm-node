import Foundation

nonisolated struct ModelFile: Codable, Sendable {
    let name: String
    let bytes: Int64
    let sha256: String?
    let prefixSHA256: String?
    let gitBlobSHA1: String?

    init(name: String, bytes: Int64, sha256: String?, prefixSHA256: String? = nil, gitBlobSHA1: String? = nil) {
        self.name = name; self.bytes = bytes; self.sha256 = sha256; self.prefixSHA256 = prefixSHA256; self.gitBlobSHA1 = gitBlobSHA1
    }
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
            ModelFile(name: "added_tokens.json", bytes: 707, sha256: nil, gitBlobSHA1: "b54f9135e44c1e81047e8d05cb027af8bc039eed"),
            ModelFile(name: "config.json", bytes: 937, sha256: nil, gitBlobSHA1: "032ad326a0daaaeeec00f2a585262acf5f692861"),
            ModelFile(name: "model.safetensors", bytes: 2263022529, sha256: "e240c0bdc0ebb0681bf0da0f98d9719fd6ebe269a3633f81542c13e81345651d", prefixSHA256: "a30751c35281a14b96c37a7088a8bc5ae2088be53585fa4fc6ec5be6bd93f970"),
            ModelFile(name: "model.safetensors.index.json", bytes: 63924, sha256: nil, gitBlobSHA1: "07e230a328dd17a09d96ee045d49b27596656aff"),
            ModelFile(name: "special_tokens_map.json", bytes: 613, sha256: nil, gitBlobSHA1: "ac23c0aaa2434523c494330aeb79c58395378103"),
            ModelFile(name: "tokenizer.json", bytes: 11422654, sha256: "aeb13307a71acd8fe81861d94ad54ab689df773318809eed3cbe794b4492dae4"),
            ModelFile(name: "tokenizer_config.json", bytes: 9706, sha256: nil, gitBlobSHA1: "7345216a0785dc7086e8c245b2a9d3896ce2b756"),
            ModelFile(name: "vocab.json", bytes: 2776833, sha256: nil, gitBlobSHA1: "4783fe10ac3adce15ac8f358ef5462739852c569"),
        ]),
        NodeModel(id: "Qwen/Qwen3-8B-MLX-4bit", title: "Qwen3 8B · 4bit · 待性能验证", revision: "383413e909f3bc5303ce195ebbdf0339c5a1a2a3", bits: 4, groupSize: 128, hiddenSize: 4096, files: [
            ModelFile(name: "config.json", bytes: 941, sha256: nil, gitBlobSHA1: "13572901ea3bd2b5899f92b84dadfd80398b980f"),
            ModelFile(name: "model.safetensors", bytes: 4351884216, sha256: "fcc83d7537bee76cc143be3e25f8954b816798f93528103db1cddb02977c5617", prefixSHA256: "a0a804eff4773dc09fca92c61afaa45adf0612b0f7ab1bd0a8d6591fdc7c1e78"),
            ModelFile(name: "model.safetensors.index.json", bytes: 64065, sha256: nil, gitBlobSHA1: "ba1986ef66ac0e017d7b044fd8732a4a888f4e91"),
            ModelFile(name: "tokenizer.json", bytes: 11422654, sha256: "aeb13307a71acd8fe81861d94ad54ab689df773318809eed3cbe794b4492dae4"),
            ModelFile(name: "tokenizer_config.json", bytes: 9690, sha256: nil, gitBlobSHA1: "131252626f88d8285427aeeea5ed744d4dd8480c"),
            ModelFile(name: "vocab.json", bytes: 2776833, sha256: nil, gitBlobSHA1: "4783fe10ac3adce15ac8f358ef5462739852c569"),
        ]),
        NodeModel(id: "mlx-community/Qwen3-8B-3bit", title: "Qwen3 8B · 3bit · 节省内存", revision: "619ded35b7d1d083ccafc367ea5ccdab1840b74d", bits: 3, groupSize: 64, hiddenSize: 4096, files: [
            ModelFile(name: "added_tokens.json", bytes: 707, sha256: nil, gitBlobSHA1: "b54f9135e44c1e81047e8d05cb027af8bc039eed"),
            ModelFile(name: "config.json", bytes: 939, sha256: nil, gitBlobSHA1: "cf5cea411b6080b89ac0d37918f7fda6ed85ed04"),
            ModelFile(name: "model.safetensors", bytes: 3584031644, sha256: "b9694bdb1f737223836235c0427b424ace11d566eeab0ac91ff8050143bd20a1", prefixSHA256: "db0f2e70dd49da54ab7baabfdada3aa64700b8304ad46a73abf1adf271a195ca"),
            ModelFile(name: "model.safetensors.index.json", bytes: 64065, sha256: nil, gitBlobSHA1: "01bae3b53a5c5d19ec5657dd1a7a2efe8482e94c"),
            ModelFile(name: "special_tokens_map.json", bytes: 613, sha256: nil, gitBlobSHA1: "ac23c0aaa2434523c494330aeb79c58395378103"),
            ModelFile(name: "tokenizer.json", bytes: 11422654, sha256: "aeb13307a71acd8fe81861d94ad54ab689df773318809eed3cbe794b4492dae4"),
            ModelFile(name: "tokenizer_config.json", bytes: 9706, sha256: nil, gitBlobSHA1: "7345216a0785dc7086e8c245b2a9d3896ce2b756"),
            ModelFile(name: "vocab.json", bytes: 2776833, sha256: nil, gitBlobSHA1: "4783fe10ac3adce15ac8f358ef5462739852c569"),
        ]),
        NodeModel(id: "mlx-community/Qwen3-0.6B-4bit", title: "Qwen3 0.6B · 快速下载测试", revision: "73e3e38d981303bc594367cd910ea6eb48349da8", bits: 4, groupSize: 64, hiddenSize: 1024, files: [
            ModelFile(name: "added_tokens.json", bytes: 707, sha256: nil, gitBlobSHA1: "b54f9135e44c1e81047e8d05cb027af8bc039eed"),
            ModelFile(name: "config.json", bytes: 937, sha256: nil, gitBlobSHA1: "6c974b02334f2f5f68de4cb2796ee4fe80bfc712"),
            ModelFile(name: "model.safetensors", bytes: 335450584, sha256: "392e8d466d56100ada00eb82031fb854297fc9e389b7d303eba3af114e87bce2", prefixSHA256: "36fb9ab7dcac7d2fc6fefe1f4723f40dbaad5b0acc2db53be51def1c883f31c6"),
            ModelFile(name: "model.safetensors.index.json", bytes: 49731, sha256: nil, gitBlobSHA1: "e743a6a7d2ba4fd21b2256d739117cbf31345297"),
            ModelFile(name: "special_tokens_map.json", bytes: 613, sha256: nil, gitBlobSHA1: "ac23c0aaa2434523c494330aeb79c58395378103"),
            ModelFile(name: "tokenizer.json", bytes: 11422654, sha256: "aeb13307a71acd8fe81861d94ad54ab689df773318809eed3cbe794b4492dae4"),
            ModelFile(name: "tokenizer_config.json", bytes: 9706, sha256: nil, gitBlobSHA1: "7345216a0785dc7086e8c245b2a9d3896ce2b756"),
            ModelFile(name: "vocab.json", bytes: 2776833, sha256: nil, gitBlobSHA1: "4783fe10ac3adce15ac8f358ef5462739852c569"),
        ]),
    ]
    nonisolated static var defaultModel: NodeModel { items[0] }
}
