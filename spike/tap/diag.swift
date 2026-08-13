// Spike 0B diagnostic — why does the IOProc never fire?
//
// Checks, in order:
//   1. the tap's real UID (vs the one we asked for)
//   2. the tap's stream format
//   3. the aggregate device's tap list, read back from the HAL
//   4. the aggregate device's INPUT stream configuration — if this is 0 channels,
//      the tap is not wired in and no IOProc will ever deliver anything
//   5. whether the device reports itself running after AudioDeviceStart

import Foundation
import CoreAudio
import AudioToolbox

func fourCC(_ v: OSStatus) -> String {
    let b = withUnsafeBytes(of: v.bigEndian) { Array($0) }
    return b.allSatisfy { $0 >= 32 && $0 < 127 }
        ? "'" + String(b.map { Character(UnicodeScalar($0)) }) + "'"
        : "\(v)"
}

func addr(_ sel: AudioObjectPropertySelector,
          _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal)
    -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: sel, mScope: scope,
                               mElement: kAudioObjectPropertyElementMain)
}

func getCFString(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector) -> String? {
    var a = addr(sel)
    var size = UInt32(MemoryLayout<CFString?>.size)
    var out: Unmanaged<CFString>?
    guard AudioObjectGetPropertyData(obj, &a, 0, nil, &size, &out) == noErr,
          let v = out?.takeRetainedValue() else { return nil }
    return v as String
}

func defaultOutputUID() -> String? {
    var dev = AudioObjectID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    var a = addr(kAudioHardwarePropertyDefaultOutputDevice)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                     &a, 0, nil, &size, &dev) == noErr else { return nil }
    return getCFString(dev, kAudioDevicePropertyDeviceUID)
}

/// Channel counts of each stream in a scope. Empty == no streams in that scope.
func streamConfig(_ dev: AudioObjectID, scope: AudioObjectPropertyScope) -> [UInt32] {
    var a = addr(kAudioDevicePropertyStreamConfiguration, scope)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(dev, &a, 0, nil, &size) == noErr, size > 0 else { return [] }
    let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size),
                                               alignment: MemoryLayout<AudioBufferList>.alignment)
    defer { raw.deallocate() }
    guard AudioObjectGetPropertyData(dev, &a, 0, nil, &size, raw) == noErr else { return [] }
    let abl = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
    return abl.map { $0.mNumberChannels }
}

func isRunning(_ dev: AudioObjectID) -> Bool? {
    var a = addr(kAudioDevicePropertyDeviceIsRunning)
    var v: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    guard AudioObjectGetPropertyData(dev, &a, 0, nil, &size, &v) == noErr else { return nil }
    return v != 0
}

// ── build a tap + aggregate, then interrogate both ──

guard let outUID = defaultOutputUID() else { fatalError("no default output device") }
print("default output UID: \(outUID)")

let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
desc.uuid = UUID()
desc.muteBehavior = .unmuted
desc.isPrivate = true
desc.isExclusive = false

var tapID = AudioObjectID(kAudioObjectUnknown)
let tapErr = AudioHardwareCreateProcessTap(desc, &tapID)
print("\n[1] AudioHardwareCreateProcessTap -> \(fourCC(tapErr)), tapID=\(tapID)")
print("    requested UID: \(desc.uuid.uuidString)")
print("    actual   UID: \(getCFString(tapID, kAudioTapPropertyUID) ?? "<none>")")

var fmt = AudioStreamBasicDescription()
var fmtSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
var fmtAddr = addr(kAudioTapPropertyFormat)
let fmtErr = AudioObjectGetPropertyData(tapID, &fmtAddr, 0, nil, &fmtSize, &fmt)
print("\n[2] tap format -> \(fourCC(fmtErr))")
print("    \(fmt.mSampleRate) Hz, \(fmt.mChannelsPerFrame) ch, \(fmt.mBitsPerChannel) bit, "
      + "flags=0x\(String(fmt.mFormatFlags, radix: 16)), bytesPerFrame=\(fmt.mBytesPerFrame)")

// Try two aggregate shapes: with an output sub-device, and tap-only.
for (label, includeSubDevice) in [("with output sub-device", true), ("tap-only", false)] {
    print("\n══ aggregate variant: \(label) ══")
    var d: [String: Any] = [
        kAudioAggregateDeviceNameKey: "SubtitlesDiag",
        kAudioAggregateDeviceUIDKey: UUID().uuidString,
        kAudioAggregateDeviceIsPrivateKey: true,
        kAudioAggregateDeviceIsStackedKey: false,
        kAudioAggregateDeviceTapAutoStartKey: true,
        kAudioAggregateDeviceTapListKey: [[
            kAudioSubTapDriftCompensationKey: true,
            kAudioSubTapUIDKey: desc.uuid.uuidString,
        ]],
    ]
    if includeSubDevice {
        d[kAudioAggregateDeviceMainSubDeviceKey] = outUID
        d[kAudioAggregateDeviceSubDeviceListKey] = [[kAudioSubDeviceUIDKey: outUID]]
    } else {
        d[kAudioAggregateDeviceSubDeviceListKey] = [[String: Any]]()
    }

    var agg = AudioObjectID(kAudioObjectUnknown)
    let aggErr = AudioHardwareCreateAggregateDevice(d as CFDictionary, &agg)
    print("[3] create aggregate -> \(fourCC(aggErr)), aggID=\(agg)")
    guard aggErr == noErr else { continue }
    defer { AudioHardwareDestroyAggregateDevice(agg) }

    var tapListAddr = addr(kAudioAggregateDevicePropertyTapList)
    var tapList: CFArray? = nil
    var tlSize = UInt32(MemoryLayout<CFArray?>.size)
    let tlErr = AudioObjectGetPropertyData(agg, &tapListAddr, 0, nil, &tlSize, &tapList)
    print("[4] aggregate tap list -> \(fourCC(tlErr)): \((tapList as? [Any]) ?? [])")

    let inCfg = streamConfig(agg, scope: kAudioObjectPropertyScopeInput)
    let outCfg = streamConfig(agg, scope: kAudioObjectPropertyScopeOutput)
    print("[5] aggregate streams — input: \(inCfg) ch, output: \(outCfg) ch")
    if inCfg.isEmpty || inCfg.allSatisfy({ $0 == 0 }) {
        print("    ⚠️  NO INPUT CHANNELS — tap is not wired in; IOProc can never deliver.")
    }

    // Start IO briefly and count callbacks.
    let counter = UnsafeMutablePointer<UInt64>.allocate(capacity: 1)
    let sampleSum = UnsafeMutablePointer<Float>.allocate(capacity: 1)
    counter.pointee = 0; sampleSum.pointee = 0
    defer { counter.deallocate(); sampleSum.deallocate() }

    var proc: AudioDeviceIOProcID?
    let procErr = AudioDeviceCreateIOProcIDWithBlock(&proc, agg, nil) { _, input, _, _, _ in
        counter.pointee &+= 1
        let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        var peak: Float = 0
        for buf in abl {
            guard let m = buf.mData else { continue }
            let n = Int(buf.mDataByteSize) / MemoryLayout<Float>.size
            let p = m.assumingMemoryBound(to: Float.self)
            for i in 0..<n { peak = max(peak, abs(p[i])) }
        }
        sampleSum.pointee = max(sampleSum.pointee, peak)
    }
    print("[6] create IOProc -> \(fourCC(procErr))")
    guard procErr == noErr, let proc = proc else { continue }

    let startErr = AudioDeviceStart(agg, proc)
    print("[7] AudioDeviceStart -> \(fourCC(startErr)), isRunning=\(isRunning(agg).map(String.init) ?? "?")")

    Thread.sleep(forTimeInterval: 2.0)
    print("[8] after 2s: callbacks=\(counter.pointee), peak=\(sampleSum.pointee)")

    AudioDeviceStop(agg, proc)
    AudioDeviceDestroyIOProcID(agg, proc)
}

AudioHardwareDestroyProcessTap(tapID)
print("\ndone.")
