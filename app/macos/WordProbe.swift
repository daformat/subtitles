// A second ear for the playing-app monitor: what an app is saying, on its own.
//
// The captions come from one recognizer fed the mix of everything playing,
// and nothing in that stream says which app a word came from. When the
// monitor has listened to an app and heard a voice, this transcribes that
// listen by itself, so its words can be held against the ones on screen: the
// same words, and the box is that app's; other words, a song's lyrics under a
// call, and it is not. A manager of its own over the engine's shared models
// (`SharedNemotronMultilingualModels`), so it costs its per-stream state and
// not a second copy of the models, and an actor of its own, so a clip in here
// never holds up the live stream. Multilingual only: the other variants have
// no shared load path in FluidAudio, and a second copy of their models is not
// worth the memory for a name.

import FluidAudio
import Foundation

actor WordProbe {
    private let manager: StreamingNemotronMultilingualAsrManager
    private let onStatus: @Sendable (String) -> Void

    init(manager: StreamingNemotronMultilingualAsrManager,
         onStatus: @escaping @Sendable (String) -> Void) {
        self.manager = manager
        self.onStatus = onStatus
    }

    /// One chunk of silence through, so the ANE programs are resident before
    /// the first real chunk, the live manager's included: loading a manager
    /// on its own does this, and the shared load leaves it to a consumer.
    func warmUp() async {
        let silence = [Float](repeating: 0, count: FluidVariant.multilingual.chunkSamples)
        _ = try? await manager.process(samples: silence)
        await manager.reset()
    }

    /// The words in a clip, 16 kHz mono, as the recognizer hears them from a
    /// cold start. Nil when it fails. The multilingual checkpoint's language
    /// tag is dropped wherever it lands, as the engine drops it.
    func words(in samples: [Float]) async -> [String]? {
        await manager.reset()
        defer { Task { await manager.reset() } }
        do {
            _ = try await manager.process(samples: samples)
            let text = try await manager.finish()
            return text.split(whereSeparator: { $0.isWhitespace })
                .map(String.init)
                .filter { !($0.hasPrefix("<") && $0.hasSuffix(">")) }
        } catch {
            onStatus("word probe: \(error.localizedDescription)")
            return nil
        }
    }

    func cleanup() async {
        await manager.cleanup()
    }
}
