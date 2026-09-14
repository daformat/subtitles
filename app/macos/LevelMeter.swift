// Listens to one app for a moment and says whether it is making sound.
//
// Core Audio's "running output" flag says a process holds an output stream
// open, not that anything is coming out of it: Chromium keeps the stream for
// ten seconds after a notification ding. The only way to tell a ding from a
// call is to listen, and this is the listener — a tap on just that app's
// processes, an aggregate device to run it, and a count of the ~10 ms blocks
// whose level cleared a floor. Built for one reading and torn down after it.

import AudioToolbox
import CoreAudio
import Foundation

final class LevelMeter {
    /// What a listen found: blocks that counted as sound, out of blocks heard.
    struct Reading {
        let blocks: Int
        let loud: Int
        /// Nil when the device never delivered a block, which is not silence but
        /// a device that did not run.
        var loudFraction: Double? { blocks > 0 ? Double(loud) / Double(blocks) : nil }
    }

    /// −55 dBFS: below anything that would be transcribed, above the tail of a
    /// fade and the rounding noise of a stream that is playing zeros.
    static let floor: Float = 0.0018

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    /// [0] blocks heard, [1] blocks above the floor. Written on the realtime
    /// thread and read only once the device has been stopped, so neither side
    /// needs a lock.
    private let counters = UnsafeMutablePointer<Int64>.allocate(capacity: 2)

    /// Starts listening to a family, as SystemAudioTap names them.
    init(family: String) throws {
        counters.initialize(repeating: 0, count: 2)
        let objectIDs = SystemAudioTap.objectIDs(forFamily: family)
        guard !objectIDs.isEmpty else { throw TapError.noProcesses(family) }

        let desc = CATapDescription(stereoMixdownOfProcesses: objectIDs)
        desc.uuid = UUID()
        desc.muteBehavior = .unmuted
        desc.isPrivate = true
        var err = AudioHardwareCreateProcessTap(desc, &tapID)
        guard err == noErr else { throw TapError.coreAudio("AudioHardwareCreateProcessTap (meter)", err) }

        do {
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
            let floor = Self.floor
            err = AudioDeviceCreateIOProcIDWithBlock(&procID, aggID, nil) { _, input, _, _, _ in
                let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
                for buffer in abl {
                    guard let data = buffer.mData else { continue }
                    let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
                    guard count > 0 else { continue }
                    let samples = data.assumingMemoryBound(to: Float.self)
                    var sumSquares: Float = 0
                    for i in 0..<count { sumSquares += samples[i] * samples[i] }
                    counters[0] += 1
                    if (sumSquares / Float(count)).squareRoot() > floor { counters[1] += 1 }
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
        return Reading(blocks: Int(counters[0]), loud: Int(counters[1]))
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
    }
}
