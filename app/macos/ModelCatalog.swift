// Known ASR models, and installing them on demand.
//
// Every entry here is a sherpa-onnx *streaming* transducer, driven through the
// same core code path — switching models is just pointing the engine at a
// different directory.
//
// Notably absent: NVIDIA Parakeet. See the note at the bottom of this file; it is
// a measurement result, not an oversight.

import CSubs
import AppKit
import CryptoKit

struct ModelSpec: Equatable {
    let id: String        // directory name under models/
    let name: String      // menu label
    let note: String      // measured characteristics, shown in the menu
    let url: String
    let sha256: String
    let sizeMB: Int
    /// Some releases ship int8 weights only; the core falls back either way, but
    /// this picks the preferred precision when both exist.
    let int8: Bool
}

enum ModelCatalog {
    /// Numbers are from this repo's own harness on the same LibriSpeech clips —
    /// see PLAN.md §8a. They are clean read speech and therefore optimistic; they
    /// are comparable to each other, which is the point of showing them.
    static let all: [ModelSpec] = [
        ModelSpec(
            id: "sherpa-onnx-streaming-zipformer-en-2023-06-26",
            name: "Zipformer EN",
            note: "489 ms p95 · RTF 0.25 · 0% WER",
            url: "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-streaming-zipformer-en-2023-06-26.tar.bz2",
            sha256: "639e25b578e9e997131402199419c13a941f8e4e198e2da1ce57dbf5cf401282",
            sizeMB: 310, int8: false),
        ModelSpec(
            id: "sherpa-onnx-streaming-zipformer-en-20M-2023-02-17",
            name: "Zipformer EN 20M",
            note: "416 ms p95 · RTF 0.19 · 9.1% WER · drops words",
            url: "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-streaming-zipformer-en-20M-2023-02-17.tar.bz2",
            sha256: "9c559283e8498d3fe95913c79ca1cb454bb26281ac2b102b41306c7d752765d9",
            sizeMB: 128, int8: false),
        ModelSpec(
            id: "sherpa-onnx-streaming-zipformer-fr-2023-04-14",
            name: "Zipformer FR (French)",
            note: "753 ms p95 · RTF 0.61 · 17% WER on Common Voice",
            url: "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-streaming-zipformer-fr-2023-04-14.tar.bz2",
            sha256: "77d4cbd61dcfa55fd2c14efc0ce5c6798be5931c05f35df5bab60c921950bb8c",
            sizeMB: 398, int8: false),
    ]

    static var modelsDirectory: URL {
        // models/ sits beside the repo root; the app bundle lives in build/.
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        return exe.deletingLastPathComponent()
            .appendingPathComponent("../../../../models").standardized
    }

    static func directory(for spec: ModelSpec) -> URL {
        modelsDirectory.appendingPathComponent(spec.id)
    }

    static func isInstalled(_ spec: ModelSpec) -> Bool {
        let dir = directory(for: spec)
        guard FileManager.default.fileExists(atPath: dir.path) else { return false }
        // A directory alone is not enough — an interrupted download leaves one
        // behind. Require the tokens file the recognizer actually needs.
        return FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("tokens.txt").path)
    }

    static func spec(withID id: String) -> ModelSpec? {
        all.first { $0.id == id }
    }
}

// MARK: - Installing

final class ModelInstaller: NSObject, URLSessionDownloadDelegate {
    private var session: URLSession!
    private var spec: ModelSpec?
    private var onProgress: ((String) -> Void)?
    private var onFinish: ((Result<ModelSpec, Error>) -> Void)?

    enum InstallError: LocalizedError {
        case checksumMismatch(expected: String, actual: String)
        case extractionFailed(Int32)

        var errorDescription: String? {
            switch self {
            case let .checksumMismatch(expected, actual):
                return "checksum mismatch (expected \(expected.prefix(12))…, got \(actual.prefix(12))…)"
            case let .extractionFailed(code):
                return "tar failed with status \(code)"
            }
        }
    }

    override init() {
        super.init()
        session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
    }

    var isBusy: Bool { spec != nil }

    func install(_ spec: ModelSpec,
                 onProgress: @escaping (String) -> Void,
                 onFinish: @escaping (Result<ModelSpec, Error>) -> Void) {
        guard !isBusy, let url = URL(string: spec.url) else { return }
        self.spec = spec
        self.onProgress = onProgress
        self.onFinish = onFinish
        onProgress("Downloading \(spec.name)… 0%")
        session.downloadTask(with: url).resume()
    }

    private func finish(_ result: Result<ModelSpec, Error>) {
        let done = onFinish
        spec = nil
        onProgress = nil
        onFinish = nil
        DispatchQueue.main.async { done?(result) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard let spec, totalBytesExpectedToWrite > 0 else { return }
        let pct = Int(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite) * 100)
        let cb = onProgress
        DispatchQueue.main.async { cb?("Downloading \(spec.name)… \(pct)%") }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        guard let spec else { return }
        let cb = onProgress
        DispatchQueue.main.async { cb?("Verifying \(spec.name)…") }

        do {
            // Verify before extracting. A corrupted or substituted model would
            // otherwise change transcription quality with nothing to explain it.
            let data = try Data(contentsOf: location, options: .mappedIfSafe)
            let digest = SHA256Digest.hex(of: data)
            guard digest == spec.sha256 else {
                finish(.failure(InstallError.checksumMismatch(expected: spec.sha256,
                                                              actual: digest)))
                return
            }

            DispatchQueue.main.async { cb?("Extracting \(spec.name)…") }
            let modelsDir = ModelCatalog.modelsDirectory
            try FileManager.default.createDirectory(at: modelsDir,
                                                    withIntermediateDirectories: true)
            let archive = modelsDir.appendingPathComponent("\(spec.id).tar.bz2")
            try? FileManager.default.removeItem(at: archive)
            try FileManager.default.moveItem(at: location, to: archive)

            let tar = Process()
            tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            tar.arguments = ["xjf", archive.path, "-C", modelsDir.path]
            try tar.run()
            tar.waitUntilExit()
            try? FileManager.default.removeItem(at: archive)

            guard tar.terminationStatus == 0 else {
                finish(.failure(InstallError.extractionFailed(tar.terminationStatus)))
                return
            }
            finish(.success(spec))
        } catch {
            finish(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        if let error, isBusy { finish(.failure(error)) }
    }
}

enum SHA256Digest {
    static func hex(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Why Parakeet is not in the catalogue
//
// NVIDIA Parakeet TDT 0.6b is the obvious model to want here: it is strong, and
// unlike the Zipformers it emits punctuation and true casing itself, which would
// remove this project's sentence-casing hack and its lowercased proper nouns.
//
// sherpa-onnx does ship streaming exports of it
// (`sherpa-onnx-nemo-parakeet-unified-en-0.6b-int8-streaming-{240,560,1120}ms`),
// and the transcription quality is excellent — measured on the same LibriSpeech
// clip it produced "After early nightfall, the yellow lamps would light up here
// and there the squalid quarter of the brothels", punctuation included.
//
// But it is unusable on CPU. Measured with this repo's harness on an M-series
// machine:
//
//     Zipformer EN          RTF 0.10        (10x headroom)
//     Parakeet 240ms,  2 threads   RTF 14.7
//     Parakeet 240ms,  4 threads   RTF 10.8
//     Parakeet 240ms,  8 threads   RTF 31.8   (thread thrashing)
//
// Roughly 100x too slow. The model's own metadata explains it: the export is
// `buffered_streaming=1` with `left_feature_frames=560`, i.e. it re-encodes 5.6
// seconds of left context for every 80 ms chunk. That design assumes an
// accelerator, not a CPU.
//
// The right way to run Parakeet on a Mac is therefore the Apple Neural Engine,
// via CoreML — which is what FluidAudio (https://github.com/FluidInference/FluidAudio)
// exists to do, and what VoiceInk uses for the same reason. That is a different
// integration: a Swift Package Manager dependency and a second engine
// implementation living on the Swift side of the C ABI rather than in the Rust
// core. Tracked in PLAN.md rather than bodged in here.
//
// Note also that Spike 0A's "CoreML is slower" finding does NOT contradict this.
// That measured ONNX Runtime's CoreML execution provider running a *Zipformer* on
// 20 ms chunks, where per-inference overhead dominates. A model exported
// specifically for the ANE is a different proposition and needs its own
// measurement.
