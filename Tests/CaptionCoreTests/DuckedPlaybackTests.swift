// The original played back under the voice: every channel of the tap where
// the output wants it, and the level ramping rather than jumping.

import CoreAudio
import XCTest
@testable import CaptionCore

final class DuckedPlaybackTests: XCTestCase {
    /// Interleaved stereo, left 0.5 and right -0.5 on every frame.
    private func withTap(frames: Int, _ body: (AudioBuffer) -> Void) {
        var samples = [Float](repeating: 0, count: frames * 2)
        for f in 0..<frames { samples[f * 2] = 0.5; samples[f * 2 + 1] = -0.5 }
        samples.withUnsafeMutableBytes { raw in
            body(AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(raw.count), mData: raw.baseAddress))
        }
    }

    /// An output list of `layout.count` buffers, `layout[i]` channels each,
    /// filled with a marker so untouched samples show.
    private func withOutput(frames: Int, layout: [Int],
                            _ body: (UnsafeMutableAudioBufferListPointer) -> Void) -> [[Float]] {
        let list = AudioBufferList.allocate(maximumBuffers: layout.count)
        defer { free(list.unsafeMutablePointer) }
        var pointers: [UnsafeMutablePointer<Float>] = []
        for (i, channels) in layout.enumerated() {
            let p = UnsafeMutablePointer<Float>.allocate(capacity: frames * channels)
            p.initialize(repeating: 9, count: frames * channels)
            pointers.append(p)
            list[i] = AudioBuffer(mNumberChannels: UInt32(channels),
                                  mDataByteSize: UInt32(frames * channels * 4), mData: p)
        }
        body(list)
        return layout.enumerated().map { i, channels in
            defer { pointers[i].deallocate() }
            return Array(UnsafeBufferPointer(start: pointers[i], count: frames * channels))
        }
    }

    func testInterleavedStereoAtFullLevel() {
        let duck = DuckGain()
        var out: [[Float]] = []
        withTap(frames: 4) { tap in
            out = withOutput(frames: 4, layout: [2]) { list in
                DuckedPlayback.play(tap, into: list, duck: duck, down: 0.1, up: 0.1)
            }
        }
        XCTAssertEqual(out[0], [0.5, -0.5, 0.5, -0.5, 0.5, -0.5, 0.5, -0.5])
    }

    func testBufferPerChannelAndExtraChannelsLeftAlone() {
        let duck = DuckGain()
        var out: [[Float]] = []
        withTap(frames: 2) { tap in
            out = withOutput(frames: 2, layout: [1, 1, 1]) { list in
                DuckedPlayback.play(tap, into: list, duck: duck, down: 0.1, up: 0.1)
            }
        }
        XCTAssertEqual(out[0], [0.5, 0.5])
        XCTAssertEqual(out[1], [-0.5, -0.5])
        XCTAssertEqual(out[2], [9, 9])
    }

    func testMonoOutputGetsTheMix() {
        let duck = DuckGain()
        var out: [[Float]] = []
        withTap(frames: 2) { tap in
            out = withOutput(frames: 2, layout: [1]) { list in
                DuckedPlayback.play(tap, into: list, duck: duck, down: 0.1, up: 0.1)
            }
        }
        XCTAssertEqual(out[0], [0, 0])
    }

    func testRampsDownThenHoldsAndCarriesOver() {
        let duck = DuckGain()
        duck.target = 0.25
        var out: [[Float]] = []
        withTap(frames: 10) { tap in
            out = withOutput(frames: 10, layout: [2]) { list in
                DuckedPlayback.play(tap, into: list, duck: duck, down: 0.25, up: 0.1)
            }
        }
        let left = stride(from: 0, to: 20, by: 2).map { out[0][$0] }
        XCTAssertEqual(left[0], 0.5 * 0.75, accuracy: 1e-6)
        XCTAssertEqual(left[1], 0.5 * 0.5, accuracy: 1e-6)
        XCTAssertEqual(left[2], 0.5 * 0.25, accuracy: 1e-6)
        XCTAssertEqual(left[9], 0.5 * 0.25, accuracy: 1e-6)
        // Right ramps the same way, from the same start.
        XCTAssertEqual(out[0][1], -0.5 * 0.75, accuracy: 1e-6)
        XCTAssertEqual(duck.current, 0.25, accuracy: 1e-6)

        // Back up, slower, from where it was left.
        duck.target = 1
        withTap(frames: 2) { tap in
            out = withOutput(frames: 2, layout: [2]) { list in
                DuckedPlayback.play(tap, into: list, duck: duck, down: 0.25, up: 0.1)
            }
        }
        XCTAssertEqual(out[0][0], 0.5 * 0.35, accuracy: 1e-6)
        XCTAssertEqual(duck.current, 0.45, accuracy: 1e-6)
    }
}
