// `--diagnose` and `--compute`: what to ask of a Mac that hears speech and
// writes nothing (issue #2, macOS 27.0).
//
// The failure there is silent by construction: the recognizer runs, the VAD
// says speech, RTF is healthy, and every decode step picks the blank token.
// FluidAudio's load-time probe only rejects an encoder that returns all zeros,
// so an encoder returning NaN, or values the joint cannot read, passes it.
// Two OS 27 changes could produce that and they call for different fixes:
//
//   - the Neural Engine path itself (a compiler change, or the new limit on
//     background processes using it), which CPU-only compute would sidestep;
//   - BNNS kernels on the CPU reading past the end of their inputs, which
//     upstream measured turning finite Kokoro inputs into all-NaN output.
//
// So the report runs a spoken sample through each cached Nemotron model under
// each compute-unit choice, and probes the encoder alone for NaN, infinities
// and zeros, against the CPU's answer as the reference. Read-only: nothing is
// downloaded, and a model that is not on disk is named and skipped.

import AVFoundation
import CoreML
import FluidAudio
import Foundation

/// Compute units for the speech model, from `--compute`. Nil keeps
/// FluidAudio's own choice, which is the Neural Engine with the CPU.
var computeOverride: MLComputeUnits?

func computeUnits(named name: String) -> MLComputeUnits? {
    switch name.lowercased() {
    case "ane": return .cpuAndNeuralEngine
    case "cpu": return .cpuOnly
    case "gpu": return .cpuAndGPU
    case "all": return .all
    default: return nil
    }
}

func computeName(_ units: MLComputeUnits) -> String {
    switch units {
    case .cpuAndNeuralEngine: return "ane"
    case .cpuOnly: return "cpu"
    case .cpuAndGPU: return "gpu"
    case .all: return "all"
    @unknown default: return "unknown"
    }
}

/// The `--compute` choice as a configuration, or nil to leave FluidAudio's.
func computeConfiguration() -> MLModelConfiguration? {
    guard let units = computeOverride else { return nil }
    let configuration = MLModelConfiguration()
    configuration.computeUnits = units
    return configuration
}

enum Diagnose {
    static let sentence = "The quick brown fox jumps over the lazy dog. "
        + "This is a test of live subtitles on this Mac."

    /// Compute units tried, CPU first: its answer is the reference the others
    /// are compared against.
    static let order: [MLComputeUnits] = [.cpuOnly, .cpuAndNeuralEngine, .cpuAndGPU]

    struct Model {
        let name: String
        let directory: URL
        let encoder: URL
        let multilingual: Bool
    }

    struct Stats {
        var count = 0, zeros = 0, nans = 0, infinities = 0
        var maxAbs: Float = 0
        var scalars: [Float] = []

        var summary: String {
            "\(count) values, \(nans) NaN, \(infinities) inf, \(zeros) zero, max |x| "
                + String(format: "%.3g", maxAbs)
        }
    }

    struct Outcome {
        let units: MLComputeUnits
        var probe: String
        var transcript: String?
        var probeBroken = false
    }

    static func run() async {
        print("subtitles diagnostics")
        print("app      \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev build")")
        print("macOS    \(ProcessInfo.processInfo.operatingSystemVersionString)")
        print("chip     \(sysctl("machdep.cpu.brand_string") ?? "unknown")")
        print("models   \(ModelCache.directory.path)")

        let samples = speechSample()
        if let samples {
            print("sample   \(String(format: "%.1f", Double(samples.count) / 16000)) s of `say`: \"\(sentence)\"")
        } else {
            print("sample   none: `say` could not render one, so only the encoder probe runs")
        }

        let models = cachedModels()
        if models.isEmpty {
            print("\nNo Nemotron or Multilingual model is on disk. Run Subtitles once to download one, then try again.")
            return
        }

        var outcomes: [String: [Outcome]] = [:]
        for model in models {
            print("\n== \(model.name)")
            var reference: [Float]?
            var list: [Outcome] = []
            for units in order {
                var outcome = Outcome(units: units, probe: "")
                let label = computeName(units).padding(toLength: 4, withPad: " ", startingAt: 0)
                do {
                    let stats = try await probeEncoder(model, units: units)
                    var line = stats.summary
                    if let reference, reference.count == stats.scalars.count {
                        line += ", max diff from cpu " + String(format: "%.3g", maxDifference(reference, stats.scalars))
                    }
                    if units == .cpuOnly { reference = stats.scalars }
                    outcome.probe = line
                    outcome.probeBroken = stats.nans > 0 || stats.infinities > 0 || stats.zeros == stats.count
                } catch {
                    outcome.probe = "failed: \(error.localizedDescription)"
                    outcome.probeBroken = true
                }
                print("\(label) encoder     \(outcome.probe)")
                if let samples {
                    let started = Date()
                    do {
                        let text = try await transcribe(samples, with: model, units: units)
                        outcome.transcript = text
                        let seconds = String(format: "%.1f", Date().timeIntervalSince(started))
                        print("\(label) transcript  \(text.isEmpty ? "(empty)" : "\"\(text)\"")  [\(seconds) s]")
                    } catch {
                        print("\(label) transcript  failed: \(error.localizedDescription)")
                    }
                }
                list.append(outcome)
            }
            outcomes[model.name] = list
        }

        print("\n== verdict")
        for model in models {
            print("\(model.name): \(verdict(outcomes[model.name] ?? []))")
        }
        print("\nPlease paste everything above into the issue.")
    }

    static func verdict(_ outcomes: [Outcome]) -> String {
        let broken = outcomes.filter(\.probeBroken).map { computeName($0.units) }
        let probeNote = broken.isEmpty ? "" : " The encoder probe is broken on: \(broken.joined(separator: ", "))."
        guard outcomes.contains(where: { $0.transcript != nil }) else {
            return "no transcript to judge by." + probeNote
        }
        let working = outcomes.filter { !($0.transcript ?? "").isEmpty }
        guard let first = working.first else {
            return "no compute path transcribes, so the fault is shared by all of them." + probeNote
        }
        if working.contains(where: { $0.units == .cpuAndNeuralEngine }) {
            return "transcribes on \(working.map { computeName($0.units) }.joined(separator: ", "))." + probeNote
        }
        return "the Neural Engine path returns nothing while \(computeName(first.units)) works. "
            + "Running with --compute \(computeName(first.units)) should bring captions back." + probeNote
    }

    // MARK: - The models on disk

    static func cachedModels() -> [Model] {
        let root = ModelCache.directory
        let files = FileManager.default
        var found: [Model] = []
        let english = root.appendingPathComponent("nemotron-streaming/560ms")
        let englishEncoder = english.appendingPathComponent("encoder/encoder_int8.mlmodelc")
        if files.fileExists(atPath: englishEncoder.path) {
            found.append(Model(name: "Nemotron 560 ms", directory: english,
                               encoder: englishEncoder, multilingual: false))
        }
        for pack in ["latin", "multilingual"] {
            let dir = root.appendingPathComponent("nemotron-multilingual/\(pack)/560ms")
            let encoder = dir.appendingPathComponent("encoder.mlmodelc")
            if files.fileExists(atPath: encoder.path) {
                found.append(Model(name: "Multilingual 560 ms (\(pack))", directory: dir,
                                   encoder: encoder, multilingual: true))
                break
            }
        }
        return found
    }

    // MARK: - End to end

    static func transcribe(_ samples: [Float], with model: Model, units: MLComputeUnits) async throws -> String {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = units
        let chunk = 16000 * 560 / 1000
        if model.multilingual {
            let manager = StreamingNemotronMultilingualAsrManager(configuration: configuration)
            try await manager.loadModels(from: model.directory)
            for start in stride(from: 0, to: samples.count, by: chunk) {
                _ = try await manager.process(samples: Array(samples[start..<min(start + chunk, samples.count)]))
            }
            let text = try await manager.finish()
            await manager.cleanup()
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let manager = StreamingNemotronAsrManager(configuration: configuration, requestedChunkSize: .ms560)
        try await manager.loadModels(from: model.directory)
        for start in stride(from: 0, to: samples.count, by: chunk) {
            guard let buffer = pcmBuffer(Array(samples[start..<min(start + chunk, samples.count)])) else { continue }
            _ = try await manager.process(audioBuffer: buffer)
        }
        let text = try await manager.finish()
        await manager.cleanup()
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func pcmBuffer(_ samples: [Float]) -> AVAudioPCMBuffer? {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000,
                                         channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData else { return nil }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { channel[0].update(from: $0.baseAddress!, count: samples.count) }
        return buffer
    }

    /// The sentence spoken by an English system voice, as 16 kHz mono floats.
    /// An English voice by name first: the default voice follows the system
    /// language, and the English model would make little of Dutch.
    static func speechSample() -> [Float]? {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("subtitles-diagnose-\(getpid()).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        for voice in ["Samantha", nil] as [String?] {
            let say = Process()
            say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
            say.arguments = (voice.map { ["-v", $0] } ?? [])
                + ["-o", url.path, "--data-format=LEF32@16000", sentence]
            say.standardError = FileHandle.nullDevice
            do { try say.run() } catch { continue }
            say.waitUntilExit()
            guard say.terminationStatus == 0,
                  let file = try? AVAudioFile(forReading: url),
                  let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                                frameCapacity: AVAudioFrameCount(file.length)),
                  (try? file.read(into: buffer)) != nil,
                  let channel = buffer.floatChannelData,
                  file.processingFormat.sampleRate == 16000 else { continue }
            return Array(UnsafeBufferPointer(start: channel[0], count: Int(buffer.frameLength)))
        }
        return nil
    }

    // MARK: - The encoder alone

    /// One encoder prediction on a fixed ramp, the same input FluidAudio's own
    /// load-time probe uses, with every other input zero but `cache_len`,
    /// seeded with 1 as upstream does.
    static func probeEncoder(_ model: Model, units: MLComputeUnits) async throws -> Stats {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = units
        let encoder = try await MLModel.load(contentsOf: model.encoder, configuration: configuration)
        let inputs = encoder.modelDescription.inputDescriptionsByName
        guard let melShape = inputs["mel"]?.multiArrayConstraint?.shape.map(\.intValue),
              let melFrames = melShape.last else {
            throw ASRError.processingFailed("the encoder has no `mel` input")
        }
        var features: [String: MLFeatureValue] = [:]
        for (name, description) in inputs {
            guard let constraint = description.multiArrayConstraint else { continue }
            let array = try MLMultiArray(shape: constraint.shape, dataType: constraint.dataType)
            let count = array.count
            for i in 0..<count {
                let value: Double
                switch name {
                case "mel": value = Double(i % 17) * 0.01 + 0.1
                case "mel_length": value = Double(melFrames)
                case "cache_len": value = 1
                default: value = 0
                }
                array[i] = NSNumber(value: value)
            }
            features[name] = MLFeatureValue(multiArray: array)
        }
        let output = try await encoder.prediction(from: MLDictionaryFeatureProvider(dictionary: features))
        guard let encoded = output.featureValue(for: "encoded")?.multiArrayValue else {
            throw ASRError.processingFailed("the encoder returned no `encoded` output")
        }
        return stats(MLShapedArray<Float>(converting: encoded).scalars)
    }

    static func stats(_ scalars: [Float]) -> Stats {
        var s = Stats()
        s.count = scalars.count
        s.scalars = scalars
        for x in scalars {
            if x.isNaN { s.nans += 1 } else if x.isInfinite { s.infinities += 1 } else {
                if x == 0 { s.zeros += 1 }
                s.maxAbs = max(s.maxAbs, abs(x))
            }
        }
        return s
    }

    static func maxDifference(_ a: [Float], _ b: [Float]) -> Float {
        var worst: Float = 0
        for (x, y) in zip(a, b) {
            guard x.isFinite, y.isFinite else { return .nan }
            worst = max(worst, abs(x - y))
        }
        return worst
    }

    static func sysctl(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &bytes, &size, nil, 0) == 0 else { return nil }
        return String(cString: bytes)
    }
}
