// Core Audio process tap — the macOS half of the platform layer.
//
// Captures system audio output with no virtual driver and no ScreenCaptureKit,
// so the user sees the lighter audio-capture permission rather than the Screen
// Recording prompt. Validated in Spike 0B; see PLAN.md §8b.

import CSubs
import AppKit
import AudioToolbox
import CoreAudio
import Foundation

enum TapError: Error, CustomStringConvertible {
    case unsupportedOS
    case coreAudio(String, OSStatus)
    case noOutputDevice
    case notPrepared

    var description: String {
        switch self {
        case .unsupportedOS:
            return "process taps require macOS 14.2 or later"
        case .noOutputDevice:
            return "no default output device"
        case .notPrepared:
            return "start() called before prepare()"
        case let .coreAudio(what, status):
            let bytes = withUnsafeBytes(of: status.bigEndian) { Array($0) }
            let cc = bytes.allSatisfy { $0 >= 32 && $0 < 127 }
                ? " ('" + String(bytes.map { Character(UnicodeScalar($0)) }) + "')" : ""
            return "\(what) failed: \(status)\(cc)"
        }
    }
}

/// Audio format the tap delivers. Spike 0B measured 48 kHz / 2 ch / f32 packed,
/// 512 frames (~10.7 ms) per callback.
struct TapFormat: Equatable {
    let sampleRate: Double
    let channels: UInt32
    let isInterleaved: Bool
}

/// One selectable source: an application *family*, not a single process.
///
/// This distinction is the whole point. Browsers and Electron apps never play
/// audio from their main process — Chrome plays through
/// `com.google.Chrome.helper`, and tapping `com.google.Chrome` would capture
/// silence. A family groups the parent and every helper under its bundle prefix,
/// and the tap covers all of them at once.
struct AudioSourceEntry: Equatable {
    let id: String      // bundle prefix, or "pid:1234" for unbundled processes
    let name: String
    let isPlaying: Bool
    let pids: [pid_t]
}

/// What to listen to.
///
/// Identified by bundle-prefix, never by Core Audio object ID: object IDs are
/// recycled and short-lived, and a stale one fails tap creation with `'!obj'`
/// (hit in Spike 0B). IDs are re-resolved immediately before the tap is built.
enum AudioSource: Equatable {
    case allSystemAudio
    case app(id: String, name: String)

    var label: String {
        switch self {
        case .allSystemAudio: return "All system audio"
        case let .app(_, name): return name
        }
    }
}

final class SystemAudioTap {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var tapDescription: CATapDescription?
    private var aggID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private(set) var format = TapFormat(sampleRate: 48000, channels: 2, isInterleaved: true)
    private(set) var source: AudioSource = .allSystemAudio

    /// Called on Core Audio's realtime thread. Must not allocate, lock, or log.
    private let onAudio: (UnsafePointer<Float>, Int) -> Void

    init(onAudio: @escaping (UnsafePointer<Float>, Int) -> Void) {
        self.onAudio = onAudio
    }

    // MARK: - property helpers

    private static func address(_ selector: AudioObjectPropertySelector,
                                _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal)
        -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    private static func cfString(_ obj: AudioObjectID,
                                 _ selector: AudioObjectPropertySelector) -> String? {
        var addr = address(selector)
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var value: Unmanaged<CFString>?
        guard AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, &value) == noErr,
              let s = value?.takeRetainedValue() else { return nil }
        return s as String
    }

    private static func uint32(_ obj: AudioObjectID,
                               _ selector: AudioObjectPropertySelector) -> UInt32? {
        var addr = address(selector)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, &value) == noErr else {
            return nil
        }
        return value
    }

    private static func defaultOutputUID() throws -> String {
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var addr = address(kAudioHardwarePropertyDefaultOutputDevice)
        let err = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                             &addr, 0, nil, &size, &device)
        guard err == noErr else { throw TapError.coreAudio("get default output device", err) }
        guard let uid = cfString(device, kAudioDevicePropertyDeviceUID) else {
            throw TapError.noOutputDevice
        }
        return uid
    }

    // MARK: - process enumeration

    private static func processObjectIDs() -> [AudioObjectID] {
        var addr = address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject),
                                             &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0,
                                  count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    /// Selectable sources, grouped into application families.
    ///
    /// `kAudioProcessPropertyIsRunningOutput` is what makes this useful: it marks
    /// the handful of apps actually making noise right now, so the picker can put
    /// them first instead of showing 38 undifferentiated daemons.
    static func audioSources() -> [AudioSourceEntry] {
        let ownPID = getpid()
        let ownBundle = Bundle.main.bundleIdentifier

        // Fold helper processes under the app they belong to.
        //
        // Only `.regular` (Dock-visible) apps are grouping targets. Helpers are
        // themselves running applications — "Google Chrome Helper" has its own
        // bundle id and localised name — so matching against every running app
        // just re-finds the helper and groups nothing.
        var appNames: [String: String] = [:]
        var helperNames: [String: String] = [:]
        for app in NSWorkspace.shared.runningApplications {
            guard let bid = app.bundleIdentifier, let name = app.localizedName else { continue }
            if app.activationPolicy == .regular {
                appNames[bid] = name
            } else {
                helperNames[bid] = name
            }
        }

        var families: [String: (name: String, playing: Bool, pids: [pid_t])] = [:]

        for id in processObjectIDs() {
            guard let pidRaw = uint32(id, kAudioProcessPropertyPID) else { continue }
            let pid = pid_t(bitPattern: pidRaw)
            // Exclude ourselves: our own aggregate device registers as a process
            // doing audio I/O, and counting it made the permission watchdog fire
            // during ordinary silence.
            if pid == ownPID { continue }

            var bundle = cfString(id, kAudioProcessPropertyBundleID)
            if bundle?.isEmpty == true { bundle = nil }
            if let bundle, let ownBundle, bundle == ownBundle { continue }

            let playing = (uint32(id, kAudioProcessPropertyIsRunningOutput) ?? 0) != 0

            // Longest running-app bundle id that prefixes this one wins:
            // "com.google.Chrome.helper" folds into "com.google.Chrome".
            var familyID: String
            var familyName: String
            if let bundle {
                let parent = appNames.keys
                    .filter { bundle == $0 || bundle.hasPrefix($0 + ".") }
                    .max(by: { $0.count < $1.count })
                if let parent {
                    familyID = parent
                    familyName = appNames[parent] ?? parent
                } else {
                    // Background-only process with no visible parent: keep it as
                    // its own entry, named as helpfully as we can manage.
                    familyID = bundle
                    familyName = helperNames[bundle]
                        ?? bundle.split(separator: ".").last.map(String.init)
                        ?? bundle
                }
            } else {
                familyID = "pid:\(pid)"
                familyName = NSRunningApplication(processIdentifier: pid)?.localizedName
                    ?? "pid \(pid)"
            }

            var entry = families[familyID] ?? (familyName, false, [])
            entry.playing = entry.playing || playing
            entry.pids.append(pid)
            families[familyID] = entry
        }

        return families
            .map { AudioSourceEntry(id: $0.key, name: $0.value.name,
                                    isPlaying: $0.value.playing, pids: $0.value.pids) }
            .sorted {
                $0.isPlaying == $1.isPlaying ? $0.name.lowercased() < $1.name.lowercased()
                                             : $0.isPlaying
            }
    }

    /// Names of families currently playing. Used by the permission watchdog to
    /// tell "nobody is playing" apart from "we are being fed zeros" (0B Finding 1).
    static func processesOutputtingAudio() -> [String] {
        audioSources().filter(\.isPlaying).map(\.name)
    }

    /// Object IDs are recycled; resolve them only at the moment of use.
    private static func objectIDs(forFamily familyID: String) -> [AudioObjectID] {
        var out: [AudioObjectID] = []
        for id in processObjectIDs() {
            if familyID.hasPrefix("pid:") {
                if let raw = uint32(id, kAudioProcessPropertyPID),
                   "pid:\(pid_t(bitPattern: raw))" == familyID {
                    out.append(id)
                }
            } else if let bundle = cfString(id, kAudioProcessPropertyBundleID),
                      bundle == familyID || bundle.hasPrefix(familyID + ".") {
                out.append(id)
            }
        }
        return out
    }

    // MARK: - lifecycle

    /// Creates the tap and reads its stream format, without starting IO.
    ///
    /// Split from `start()` so the caller can build the core with the real format
    /// and get the worker running *before* audio begins flowing. Starting capture
    /// first means a model load's worth of audio piles into the ring and the first
    /// seconds of speech are lost behind it.
    @discardableResult
    func prepare(source: AudioSource = .allSystemAudio) throws -> TapFormat {
        guard #available(macOS 14.2, *) else { throw TapError.unsupportedOS }

        let desc: CATapDescription
        switch source {
        case .allSystemAudio:
            // Do NOT set isExclusive here. The `...ButExcludeProcesses:`
            // initializer sets it true, meaning "the list is an exclusion list" —
            // an empty list therefore means tap everything. Forcing it false
            // reinterprets the empty list as an *inclusion* list of zero
            // processes: the tap builds, the aggregate reports 2 input channels,
            // AudioDeviceStart returns noErr, and the device then silently never
            // runs. Cost hours in Spike 0B.
            desc = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
            self.source = .allSystemAudio
        case let .app(familyID, name):
            let objectIDs = Self.objectIDs(forFamily: familyID)
            guard !objectIDs.isEmpty else {
                // The app quit between picking it and starting. Fall back rather
                // than capturing nothing at all.
                FileHandle.standardError.write(
                    "source \"\(name)\" is gone; falling back to all system audio\n"
                        .data(using: .utf8)!)
                return try prepare(source: .allSystemAudio)
            }
            // Every process in the family at once — the parent alone is usually
            // silent for browsers and Electron apps.
            desc = CATapDescription(stereoMixdownOfProcesses: objectIDs)
            self.source = source
        }

        desc.uuid = UUID()
        desc.muteBehavior = .unmuted // the user still hears their audio
        desc.isPrivate = true
        tapDescription = desc

        let err = AudioHardwareCreateProcessTap(desc, &tapID)
        guard err == noErr else { throw TapError.coreAudio("AudioHardwareCreateProcessTap", err) }

        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var fmtAddr = Self.address(kAudioTapPropertyFormat)
        let ferr = AudioObjectGetPropertyData(tapID, &fmtAddr, 0, nil, &size, &asbd)
        guard ferr == noErr else { throw TapError.coreAudio("get tap format", ferr) }
        format = TapFormat(
            sampleRate: asbd.mSampleRate,
            channels: asbd.mChannelsPerFrame,
            isInterleaved: (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) == 0)
        return format
    }

    /// Builds the aggregate device and starts IO. `prepare()` must have run first.
    func start() throws {
        guard let desc = tapDescription else { throw TapError.notPrepared }
        let outputUID = try Self.defaultOutputUID()
        var err: OSStatus = noErr

        // Private aggregate device so it never shows up in Sound settings.
        let aggDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Subtitles Capture",
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
            throw TapError.coreAudio("AudioHardwareCreateAggregateDevice", err)
        }

        // Realtime callback: hand samples straight to the core and return.
        let sink = onAudio
        err = AudioDeviceCreateIOProcIDWithBlock(&procID, aggID, nil) { _, input, _, _, _ in
            let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            for buffer in abl {
                guard let data = buffer.mData else { continue }
                let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
                if count > 0 {
                    sink(data.assumingMemoryBound(to: Float.self), count)
                }
            }
        }
        guard err == noErr else {
            throw TapError.coreAudio("AudioDeviceCreateIOProcIDWithBlock", err)
        }

        err = AudioDeviceStart(aggID, procID)
        guard err == noErr else { throw TapError.coreAudio("AudioDeviceStart", err) }
    }

    /// Tear down and re-create the tap against a different source.
    ///
    /// Returns false if the new source produces a different stream format — the
    /// core's resampler is configured once at startup from the initial format, so
    /// a change would need the engine rebuilt. In practice every process tap
    /// reports 48 kHz stereo, so this is a guard rather than a code path.
    @discardableResult
    func switchTo(source: AudioSource) throws -> Bool {
        let previous = format
        stop()
        let newFormat = try prepare(source: source)
        try start()
        return newFormat == previous
    }

    func stop() {
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
        tapDescription = nil
    }

    deinit { stop() }
}
