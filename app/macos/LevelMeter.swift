// Listens to one app for a moment and says what it heard.
//
// Core Audio's "running output" flag says a process holds an output stream
// open, not that anything is coming out of it: Chromium keeps the stream for
// ten seconds after a notification ding. The only way to tell a ding from a
// call is to listen, and this is the listener — a tap on just that app's
// processes, an aggregate device to run it, and a count of the ~10 ms blocks
// whose level cleared a floor. It keeps the audio too, handed back as 16 kHz
// mono once stopped, for whoever wants to know more than how loud it was: a
// music player clears the floor as surely as a call does, and the monitor
// asks the voice detector which of the two it heard. Built for one reading
// and torn down after it.

import AudioToolbox
import AVFoundation
import CoreAudio
import Foundation

final class LevelMeter {
    /// What a listen found: blocks that counted as sound, out of blocks heard,
    /// and the audio itself.
    struct Reading {
        let blocks: Int
        let loud: Int
        /// What was heard, 16 kHz mono, as the voice detector wants it. Empty
        /// when nothing came, or it could not be converted.
        let samples: [Float]
        /// Nil when the device never delivered a block, which is not silence but
        /// a device that did not run.
        var loudFraction: Double? { blocks > 0 ? Double(loud) / Double(blocks) : nil }
    }

    /// −55 dBFS: below anything that would be transcribed, above the tail of a
    /// fade and the rounding noise of a stream that is playing zeros.
    static let floor: Float = 0.0018
    /// The rate the voice detector listens at.
    static let voiceRate: Double = 16000

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    /// [0] blocks heard, [1] blocks above the floor, [2] floats recorded.
    /// Written on the realtime thread and read only once the device has been
    /// stopped, so neither side needs a lock.
    private let counters = UnsafeMutablePointer<Int64>.allocate(capacity: 3)
    /// The audio as the tap delivers it, up to `capacity` floats. The same
    /// arrangement: the realtime thread writes, and nothing reads until it
    /// has stopped.
    private var recording: UnsafeMutablePointer<Float>?
    private var capacity = 0
    /// What the tap delivers, read from the tap as SystemAudioTap does. 48 kHz
    /// stereo interleaved in every measurement so far, but the conversion
    /// depends on it, so it is read rather than assumed.
    private var format = TapFormat(sampleRate: 48000, channels: 2, isInterleaved: true)

    /// Starts listening to a family, as SystemAudioTap names them, keeping up
    /// to `seconds` of what it hears.
    init(family: String, seconds: TimeInterval) throws {
        counters.initialize(repeating: 0, count: 3)
        do {
            let objectIDs = SystemAudioTap.objectIDs(forFamily: family)
            guard !objectIDs.isEmpty else { throw TapError.noProcesses(family) }

            let desc = CATapDescription(stereoMixdownOfProcesses: objectIDs)
            desc.uuid = UUID()
            desc.muteBehavior = .unmuted
            desc.isPrivate = true
            var err = AudioHardwareCreateProcessTap(desc, &tapID)
            guard err == noErr else { throw TapError.coreAudio("AudioHardwareCreateProcessTap (meter)", err) }

            var asbd = AudioStreamBasicDescription()
            var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            var fmtAddr = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat,
                                                     mScope: kAudioObjectPropertyScopeGlobal,
                                                     mElement: kAudioObjectPropertyElementMain)
            err = AudioObjectGetPropertyData(tapID, &fmtAddr, 0, nil, &size, &asbd)
            guard err == noErr else { throw TapError.coreAudio("get tap format (meter)", err) }
            format = TapFormat(
                sampleRate: asbd.mSampleRate,
                channels: asbd.mChannelsPerFrame,
                isInterleaved: (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) == 0)
            // Room for the listen and a little over: a block that does not
            // fit is dropped, not the listen.
            capacity = Int((seconds + 0.5) * format.sampleRate) * max(1, Int(format.channels))
            let recording = UnsafeMutablePointer<Float>.allocate(capacity: capacity)
            self.recording = recording

            let outputUID = try SystemAudioTap.defaultOutputUID()
            let aggDescription: [String: Any] = [
                kAudioAggregateDeviceNameKey: "Subtitles Meter",
                kAudioAggregateDeviceUIDKey: UUID().uuidString,
                kAudioAggregateDeviceMainSubDeviceKey: outputUID,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: false,
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
                kAudioAggregateDeviceTapListKey: [[
                    kAudioSubTapDriftCompensationKey: true,
                    kAudioSubTapUIDKey: desc.uuid.uuidString,
                ]],
            ]
            err = AudioHardwareCreateAggregateDevice(aggDescription as CFDictionary, &aggID)
            guard err == noErr else {
                throw TapError.coreAudio("AudioHardwareCreateAggregateDevice (meter)", err)
            }

            let counters = self.counters
            let capacity = self.capacity
            let interleaved = format.isInterleaved
            let floor = Self.floor
            err = AudioDeviceCreateIOProcIDWithBlock(&procID, aggID, nil) { _, input, _, _, _ in
                let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
                for (index, buffer) in abl.enumerated() {
                    guard let data = buffer.mData else { continue }
                    let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
                    guard count > 0 else { continue }
                    let samples = data.assumingMemoryBound(to: Float.self)
                    var sumSquares: Float = 0
                    for i in 0..<count { sumSquares += samples[i] * samples[i] }
                    counters[0] += 1
                    if (sumSquares / Float(count)).squareRoot() > floor { counters[1] += 1 }
                    // Kept as delivered: the one buffer of an interleaved
                    // stream, or the first channel's of a planar one.
                    guard interleaved || index == 0 else { continue }
                    let written = Int(counters[2])
                    let room = min(count, capacity - written)
                    guard room > 0 else { continue }
                    (recording + written).update(from: samples, count: room)
                    counters[2] += Int64(room)
                }
            }
            guard err == noErr else {
                throw TapError.coreAudio("AudioDeviceCreateIOProcIDWithBlock (meter)", err)
            }
            err = AudioDeviceStart(aggID, procID)
            guard err == noErr else { throw TapError.coreAudio("AudioDeviceStart (meter)", err) }
        } catch {
            tearDown()
            throw error
        }
    }

    /// Stops listening and reports what was heard. Once only.
    func stop() -> Reading {
        tearDown()
        let heard = recording.map { Self.voiceSamples($0, count: Int(counters[2]), format: format) } ?? []
        return Reading(blocks: Int(counters[0]), loud: Int(counters[1]), samples: heard)
    }

    /// What was recorded, as the detector wants it: the channels averaged
    /// into one, then the rate converted.
    private static func voiceSamples(_ recorded: UnsafeMutablePointer<Float>, count: Int,
                                     format: TapFormat) -> [Float] {
        guard count > 0 else { return [] }
        let channels = format.isInterleaved ? max(1, Int(format.channels)) : 1
        let frames = count / channels
        var mono = [Float](repeating: 0, count: frames)
        if channels == 1 {
            mono.withUnsafeMutableBufferPointer { $0.baseAddress!.update(from: recorded, count: frames) }
        } else {
            let gain = 1 / Float(channels)
            for frame in 0..<frames {
                var sum: Float = 0
                for channel in 0..<channels { sum += recorded[frame * channels + channel] }
                mono[frame] = sum * gain
            }
        }
        return resample(mono, from: format.sampleRate, to: voiceRate) ?? []
    }

    /// AVAudioConverter's rate conversion, mono to mono, or nil when it
    /// refuses the formats.
    private static func resample(_ mono: [Float], from rate: Double, to target: Double) -> [Float]? {
        guard rate != target else { return mono }
        guard !mono.isEmpty,
              let from = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate,
                                       channels: 1, interleaved: false),
              let to = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: target,
                                     channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: from, to: to),
              let input = AVAudioPCMBuffer(pcmFormat: from, frameCapacity: AVAudioFrameCount(mono.count)),
              let output = AVAudioPCMBuffer(
                  pcmFormat: to,
                  frameCapacity: AVAudioFrameCount((Double(mono.count) * target / rate).rounded(.up)) + 64)
        else { return nil }
        input.frameLength = AVAudioFrameCount(mono.count)
        mono.withUnsafeBufferPointer {
            input.floatChannelData![0].update(from: $0.baseAddress!, count: mono.count)
        }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, outStatus in
            if supplied {
                outStatus.pointee = .endOfStream
                return nil
            }
            supplied = true
            outStatus.pointee = .haveData
            return input
        }
        guard status != .error, let data = output.floatChannelData else { return nil }
        return Array(UnsafeBufferPointer(start: data[0], count: Int(output.frameLength)))
    }

    /// IO, then the aggregate, then the tap — that order is required.
    private func tearDown() {
        if let procID {
            AudioDeviceStop(aggID, procID)
            AudioDeviceDestroyIOProcID(aggID, procID)
            self.procID = nil
        }
        if aggID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggID)
            aggID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    deinit {
        tearDown()
        counters.deallocate()
        recording?.deallocate()
    }
}
