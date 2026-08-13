// Spike 0B — Core Audio process tap probe.
//
// Goal: confirm we can capture system audio on macOS 15.7 via a process tap
// (no virtual driver, no ScreenCaptureKit), and observe exactly which TCC
// permission prompt the user sees.
//
// Prints the tap's stream format, then a 10 Hz RMS/peak meter.
//
// Deliberately follows the realtime rule from PLAN.md §4: the IOProc does
// nothing but read samples and store two floats. No allocation, no locks,
// no printing. The meter is drawn from the main thread.

import Foundation
import CoreAudio
import AudioToolbox

// MARK: - Shared state (written by IOProc thread, read by main)
// Raw pointers rather than a class: no ARC traffic in the realtime callback.

let gRMS = UnsafeMutablePointer<Float>.allocate(capacity: 1)
let gPeak = UnsafeMutablePointer<Float>.allocate(capacity: 1)
let gFrames = UnsafeMutablePointer<UInt64>.allocate(capacity: 1)
let gCallbacks = UnsafeMutablePointer<UInt64>.allocate(capacity: 1)

// MARK: - Helpers

func check(_ status: OSStatus, _ what: String) throws {
    guard status == noErr else {
        let code = String(format: "%d", status)
        // Four-char codes are common in Core Audio; show both readings.
        var fourCC = ""
        let bytes = withUnsafeBytes(of: status.bigEndian) { Array($0) }
        if bytes.allSatisfy({ $0 >= 32 && $0 < 127 }) {
            fourCC = " ('" + String(bytes.map { Character(UnicodeScalar($0)) }) + "')"
        }
        throw NSError(domain: "tap_probe", code: Int(status),
                      userInfo: [NSLocalizedDescriptionKey: "\(what) failed: \(code)\(fourCC)"])
    }
}

func defaultOutputDeviceUID() throws -> String {
    var deviceID = AudioObjectID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    try check(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &addr, 0, nil, &size, &deviceID),
              "get default output device")

    var uid: Unmanaged<CFString>? = nil
    var uidSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    addr.mSelector = kAudioDevicePropertyDeviceUID
    try check(AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &uidSize, &uid),
              "get output device UID")
    guard let uid = uid?.takeRetainedValue() else {
        throw NSError(domain: "tap_probe", code: -1,
                      userInfo: [NSLocalizedDescriptionKey: "output device has no UID"])
    }
    return uid as String
}

func tapStreamFormat(_ tapID: AudioObjectID) throws -> AudioStreamBasicDescription {
    var asbd = AudioStreamBasicDescription()
    var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioTapPropertyFormat,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    try check(AudioObjectGetPropertyData(tapID, &addr, 0, nil, &size, &asbd),
              "get tap format")
    return asbd
}

// MARK: - Main

func run() throws {
    gRMS.pointee = 0; gPeak.pointee = 0; gFrames.pointee = 0; gCallbacks.pointee = 0

    guard #available(macOS 14.2, *) else {
        throw NSError(domain: "tap_probe", code: -1,
                      userInfo: [NSLocalizedDescriptionKey: "process taps need macOS 14.2+"])
    }

    let outputUID = try defaultOutputDeviceUID()
    FileHandle.standardError.write("default output device: \(outputUID)\n".data(using: .utf8)!)

    // Global stereo tap: everything the system plays, excluding nothing.
    // .unmuted so the user still hears their audio while we listen.
    let tapDesc = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
    tapDesc.uuid = UUID()
    tapDesc.muteBehavior = .unmuted
    tapDesc.isPrivate = true
    // NOTE: do NOT set isExclusive here. The `...ButExcludeProcesses:` initializer
    // sets it to true, meaning "the process list is an exclusion list" — with an
    // empty list that's a global tap. Forcing it to false reinterprets the empty
    // list as an *inclusion* list of zero processes: the tap is created, the
    // aggregate reports 2 input channels, AudioDeviceStart returns noErr, and the
    // device then silently never runs. Verified against diag2 variants A–D.

    var tapID = AudioObjectID(kAudioObjectUnknown)
    try check(AudioHardwareCreateProcessTap(tapDesc, &tapID), "AudioHardwareCreateProcessTap")
    FileHandle.standardError.write("tap created: id=\(tapID) uid=\(tapDesc.uuid.uuidString)\n"
                                   .data(using: .utf8)!)
    defer { AudioHardwareDestroyProcessTap(tapID) }

    let asbd = try tapStreamFormat(tapID)
    print("""
    ── tap stream format ───────────────────────────
      sample rate : \(asbd.mSampleRate) Hz
      channels    : \(asbd.mChannelsPerFrame)
      bits/channel: \(asbd.mBitsPerChannel)
      format flags: 0x\(String(asbd.mFormatFlags, radix: 16))
      bytes/frame : \(asbd.mBytesPerFrame)
    ────────────────────────────────────────────────
    """)

    // Aggregate device wrapping the tap. Private so it never appears in
    // Sound preferences or other apps' device lists.
    let aggUID = UUID().uuidString
    let aggDesc: [String: Any] = [
        kAudioAggregateDeviceNameKey: "SubtitlesTapProbe",
        kAudioAggregateDeviceUIDKey: aggUID,
        kAudioAggregateDeviceMainSubDeviceKey: outputUID,
        kAudioAggregateDeviceIsPrivateKey: true,
        kAudioAggregateDeviceIsStackedKey: false,
        kAudioAggregateDeviceTapAutoStartKey: true,
        kAudioAggregateDeviceSubDeviceListKey: [
            [kAudioSubDeviceUIDKey: outputUID]
        ],
        kAudioAggregateDeviceTapListKey: [
            [
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: tapDesc.uuid.uuidString,
            ]
        ],
    ]

    var aggID = AudioObjectID(kAudioObjectUnknown)
    try check(AudioHardwareCreateAggregateDevice(aggDesc as CFDictionary, &aggID),
              "AudioHardwareCreateAggregateDevice")
    FileHandle.standardError.write("aggregate device created: id=\(aggID)\n".data(using: .utf8)!)
    defer { AudioHardwareDestroyAggregateDevice(aggID) }

    // ── Realtime callback. Copy/measure only. ──
    var procID: AudioDeviceIOProcID?
    let ioBlock: AudioDeviceIOBlock = { _, inInputData, _, _, _ in
        // UnsafeMutableAudioBufferListPointer walks the variable-length
        // AudioBufferList correctly; hand-rolling a pointer to .mBuffers only
        // ever sees the first buffer and escapes a local.
        let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))

        var sumSquares: Float = 0
        var peak: Float = 0
        var sampleCount: UInt64 = 0
        var channels: UInt32 = 1

        for buf in abl {
            guard let data = buf.mData else { continue }
            let n = Int(buf.mDataByteSize) / MemoryLayout<Float>.size
            let samples = data.assumingMemoryBound(to: Float.self)
            for i in 0..<n {
                let s = samples[i]
                sumSquares += s * s
                let a = abs(s)
                if a > peak { peak = a }
            }
            sampleCount += UInt64(n)
            channels = max(channels, buf.mNumberChannels)
        }

        gRMS.pointee = sampleCount > 0 ? (sumSquares / Float(sampleCount)).squareRoot() : 0
        gPeak.pointee = peak
        gFrames.pointee &+= sampleCount / UInt64(channels)
        gCallbacks.pointee &+= 1
        return
    }

    try check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggID, nil, ioBlock),
              "AudioDeviceCreateIOProcIDWithBlock")
    try check(AudioDeviceStart(aggID, procID), "AudioDeviceStart")
    defer {
        AudioDeviceStop(aggID, procID)
        if let procID = procID { AudioDeviceDestroyIOProcID(aggID, procID) }
    }

    print("\ncapturing — play some audio. ctrl-C to stop.\n")

    // ── Meter, drawn from the main thread at 10 Hz. ──
    let deadline = Date().addingTimeInterval(45)
    var lastFrames: UInt64 = 0
    while Date() < deadline {
        Thread.sleep(forTimeInterval: 0.1)
        let rms = gRMS.pointee
        let peak = gPeak.pointee
        let frames = gFrames.pointee
        let cbs = gCallbacks.pointee

        let db = rms > 0 ? 20 * log10(rms) : -120
        let barLen = max(0, min(40, Int((db + 60) / 60 * 40)))
        let bar = String(repeating: "█", count: barLen)
            + String(repeating: "·", count: 40 - barLen)

        let delta = frames - lastFrames
        lastFrames = frames
        let line = String(format: "\r%@ %6.1f dB  peak %.3f  %6llu fr/100ms  cb=%llu   ",
                          bar, db, peak, delta, cbs)
        FileHandle.standardError.write(line.data(using: .utf8)!)
    }

    print("\n\ndone. total frames: \(gFrames.pointee), callbacks: \(gCallbacks.pointee)")
    if gFrames.pointee == 0 {
        print("⚠️  no audio frames received — tap created but delivered nothing.")
    }
}

do {
    try run()
} catch {
    FileHandle.standardError.write("ERROR: \(error.localizedDescription)\n".data(using: .utf8)!)
    exit(1)
}
