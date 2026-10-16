/// Tracks text already sent to a streaming client using UTF-8 bytes rather than
/// Swift Character counts. A token can extend a grapheme that was already sent.
nonisolated struct IncrementalTokenText: Sendable {
    enum DecodeError: Error, Equatable {
        case previouslyEmittedTextChanged
    }

    private(set) var text = ""
    private var emittedUTF8 = [UInt8]()

    init() {}

    /// Receives the cumulative decode of all generated tokens. Incomplete UTF-8
    /// sequences decode to a trailing replacement scalar and are held until the
    /// next token. A final call flushes even a genuine or truncated replacement.
    mutating func appendDecoded(_ decoded: String, final: Bool = false) throws -> String {
        let bytes = Array(decoded.utf8)
        guard bytes.starts(with: emittedUTF8) else {
            throw DecodeError.previouslyEmittedTextChanged
        }
        if !final, decoded.unicodeScalars.last?.value == 0xfffd {
            return ""
        }

        // Both the old and new strings end at scalar boundaries. The suffix is
        // therefore valid UTF-8, including combining marks and emoji joiners.
        let suffix = String(decoding: bytes.dropFirst(emittedUTF8.count), as: UTF8.self)
        emittedUTF8 = bytes
        text = decoded
        return suffix
    }
}
