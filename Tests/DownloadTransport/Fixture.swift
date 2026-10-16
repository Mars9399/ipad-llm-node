import Foundation
@main struct Main {
    static func main() async {
        let args = CommandLine.arguments
        let download = ModelFileDownload(url: URL(string: args[1])!, partial: URL(fileURLWithPath: args[2]), expectedBytes: Int64(args[3])!) { bytes in
            print("bytes=\(bytes)")
        }
        let worker = Task { try await download.download() }
        if args.count > 4 {
            Task {
                try? await Task.sleep(for: .milliseconds(Int(args[4])!))
                worker.cancel()
            }
        }
        do { try await worker.value; print("complete") }
        catch { print("failed: \(error.localizedDescription)"); exit(1) }
    }
}
