// Spike 0B diagnostic #2 — isolate why no audio flows.
//
// Enumerates audio processes (also directly useful for the per-app source
// picker in PLAN.md Phase 3), then tries several CATapDescription variants
// and reports which one actually delivers frames.

import Foundation
import CoreAudio
import AudioToolbox

func fourCC(_ v: OSStatus) -> String {
    let b = withUnsafeBytes(of: v.bigEndian) { Array($0) }
    return b.allSatisfy { $0 >= 32 && $0 < 127 }
        ? "'" + String(b.map { Character(UnicodeScalar($0)) }) + "'" : "\(v)"
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

func getU32(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector) -> UInt32? {
    var a = addr(sel)
    var v: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    guard AudioObjectGetPropertyData(obj, &a, 0, nil, &size, &v) == noErr else { return nil }
    return v
}

func defaultOutputUID() -> String? {
    var dev = AudioObjectID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    var a = addr(kAudioHardwarePropertyDefaultOutputDevice)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                     &a, 0, nil, &size, &dev) == noErr else { return nil }
    return getCFString(dev, kAudioDevicePropertyDeviceUID)
}

// ── enumerate audio processes ──

func audioProcesses() -> [AudioObjectID] {
    var a = addr(kAudioHardwarePropertyProcessObjectList)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject),
                                         &a, 0, nil, &size) == noErr else { return [] }
    var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                     &a, 0, nil, &size, &ids) == noErr else { return [] }
    return ids
}

print("══ audio processes ══")
var playing: [AudioObjectID] = []
for p in audioProcesses() {
    let pid = getU32(p, kAudioProcessPropertyPID).map { Int32(bitPattern: $0) } ?? -1
    let bundle = getCFString(p, kAudioProcessPropertyBundleID) ?? "-"
    let out = getU32(p, kAudioProcessPropertyIsRunningOutput) ?? 0
    let running = getU32(p, kAudioProcessPropertyIsRunning) ?? 0
    if out != 0 { playing.append(p) }
    let name = pid > 0
        ? (try? String(contentsOf: URL(fileURLWithPath: "/proc"))) ?? "" : ""
    _ = name
    print(String(format: "  obj=%-5u pid=%-7d running=%u output=%u  %@",
                 p, pid, running, out, bundle))
}
print("  → \(playing.count) process(es) currently outputting audio\n")

guard let outUID = defaultOutputUID() else { fatalError("no output device") }

// ── try a tap variant, return frames+peak observed ──

func tryTap(_ label: String, _ make: () -> CATapDescription) {
    print("══ \(label) ══")
    let desc = make()
    var tapID = AudioObjectID(kAudioObjectUnknown)
    let e = AudioHardwareCreateProcessTap(desc, &tapID)
    guard e == noErr else { print("  createTap -> \(fourCC(e))\n"); return }
    defer { AudioHardwareDestroyProcessTap(tapID) }

    var fmt = AudioStreamBasicDescription()
    var fs = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    var fa = addr(kAudioTapPropertyFormat)
    _ = AudioObjectGetPropertyData(tapID, &fa, 0, nil, &fs, &fmt)
    print("  tap ok: \(fmt.mSampleRate)Hz \(fmt.mChannelsPerFrame)ch  "
          + "private=\(desc.isPrivate) exclusive=\(desc.isExclusive) mute=\(desc.muteBehavior.rawValue)")

    let d: [String: Any] = [
        kAudioAggregateDeviceNameKey: "SubtitlesDiag2",
        kAudioAggregateDeviceUIDKey: UUID().uuidString,
        kAudioAggregateDeviceIsPrivateKey: true,
        kAudioAggregateDeviceIsStackedKey: false,
        kAudioAggregateDeviceTapAutoStartKey: true,
        kAudioAggregateDeviceMainSubDeviceKey: outUID,
        kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outUID]],
        kAudioAggregateDeviceTapListKey: [[
            kAudioSubTapDriftCompensationKey: true,
            kAudioSubTapUIDKey: desc.uuid.uuidString,
        ]],
    ]
    var agg = AudioObjectID(kAudioObjectUnknown)
    let ae = AudioHardwareCreateAggregateDevice(d as CFDictionary, &agg)
    guard ae == noErr else { print("  createAggregate -> \(fourCC(ae))\n"); return }
    defer { AudioHardwareDestroyAggregateDevice(agg) }

    let cb = UnsafeMutablePointer<UInt64>.allocate(capacity: 1)
    let pk = UnsafeMutablePointer<Float>.allocate(capacity: 1)
    cb.pointee = 0; pk.pointee = 0
    defer { cb.deallocate(); pk.deallocate() }

    var proc: AudioDeviceIOProcID?
    let pe = AudioDeviceCreateIOProcIDWithBlock(&proc, agg, nil) { _, input, _, _, _ in
        cb.pointee &+= 1
        let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        var peak: Float = 0
        for buf in abl {
            guard let m = buf.mData else { continue }
            let n = Int(buf.mDataByteSize) / MemoryLayout<Float>.size
            let s = m.assumingMemoryBound(to: Float.self)
            for i in 0..<n { peak = max(peak, abs(s[i])) }
        }
        if peak > pk.pointee { pk.pointee = peak }
    }
    guard pe == noErr, let proc = proc else { print("  IOProc -> \(fourCC(pe))\n"); return }

    let se = AudioDeviceStart(agg, proc)
    Thread.sleep(forTimeInterval: 2.5)
    let running = getU32(agg, kAudioDevicePropertyDeviceIsRunning) ?? 0
    AudioDeviceStop(agg, proc)
    AudioDeviceDestroyIOProcID(agg, proc)

    let verdict = cb.pointee > 0 ? (pk.pointee > 0 ? "✅ AUDIO" : "⚠️ callbacks but silent") : "❌ no callbacks"
    print("  start=\(fourCC(se)) running=\(running) callbacks=\(cb.pointee) peak=\(pk.pointee)  \(verdict)\n")
}

tryTap("A: global, all defaults") {
    CATapDescription(stereoGlobalTapButExcludeProcesses: [])
}

tryTap("B: global, unmuted only") {
    let d = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
    d.muteBehavior = .unmuted
    return d
}

tryTap("C: global, unmuted + private (no isExclusive override)") {
    let d = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
    d.muteBehavior = .unmuted
    d.isPrivate = true
    return d
}

tryTap("D: original — isPrivate + isExclusive=false") {
    let d = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
    d.muteBehavior = .unmuted
    d.isPrivate = true
    d.isExclusive = false
    return d
}

if let target = playing.first {
    tryTap("E: stereo mixdown of one playing process (obj=\(target))") {
        CATapDescription(stereoMixdownOfProcesses: [target])
    }
} else {
    print("══ E skipped — no process currently outputting audio ══")
}
