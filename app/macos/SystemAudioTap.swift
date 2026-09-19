// Core Audio process tap — the macOS half of the platform layer.
//
// Captures system audio output with no virtual driver and no ScreenCaptureKit,
// so the user sees the lighter audio-capture permission rather than the Screen
// Recording prompt. Validated in Spike 0B; see PLAN.md §8b.
//
// The same object also reads the microphone — the default input device, taken
// directly with an IOProc and no tap — so the rest of the app has one capture
// to prepare, start and stop whichever the source is.

import CSubs
import AppKit
import AudioToolbox
import CoreAudio
import Foundation

enum TapError: Error, CustomStringConvertible {
    case unsupportedOS
    case coreAudio(String, OSStatus)
    case noOutputDevice
    case noInputDevice
    case inputFormat(String)
    case notPrepared
    case noProcesses(String)

    var description: String {
        switch self {
        case .unsupportedOS:
            return "process taps require macOS 14.2 or later"
        case .noOutputDevice:
            return "no default output device"
        case .noInputDevice:
            return "no input device"
        case let .inputFormat(what):
            return "unusable input format: \(what)"
        case .notPrepared:
            return "start() called before prepare()"
        case let .noProcesses(family):
            return "no processes to tap for \(family)"
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
    /// The default input device — whatever Sound settings has as the input.
    case microphone
    case app(id: String, name: String)

    /// The id the microphone goes by where a source is a string: the persisted
    /// source, and the app a box belongs to. No bundle id looks like this, and
    /// a copy of the app from before the microphone reads it as an app that has
    /// gone and falls back to all system audio.
    static let microphoneID = "microphone"

    var label: String {
        switch self {
        case .allSystemAudio: return "All system audio"
        case .microphone: return "Microphone"
        case let .app(_, name): return name
        }
    }
}

final class SystemAudioTap {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var tapDescription: CATapDescription?
    private var aggID = AudioObjectID(kAudioObjectUnknown)
    /// The microphone's device, which stands in for the tap and the aggregate.
    private var inputDevice = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    /// The device the IOProc is on — the aggregate for a tap, the input device
    /// for the microphone. Teardown has to address the same one.
    private var procHost = AudioObjectID(kAudioObjectUnknown)
    private(set) var format = TapFormat(sampleRate: 48000, channels: 2, isInterleaved: true)
    private(set) var source: AudioSource = .allSystemAudio

    /// Called on Core Audio's realtime thread. Must not allocate, lock, or log.
    private let onAudio: (UnsafePointer<Float>, Int) -> Void

    /// Called on the main queue when Sound settings' input changes, or the
    /// current one goes — AirPods connecting, a USB microphone unplugged —
    /// while the microphone is the source. Not followed from in here: the new
    /// device's format may differ, and that is the caller's to handle.
    var onDefaultInputChanged: (() -> Void)?

    init(onAudio: @escaping (UnsafePointer<Float>, Int) -> Void) {
        self.onAudio = onAudio
        var addr = Self.address(kAudioHardwarePropertyDefaultInputDevice)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, .main) {
            [weak self] _, _ in
            guard let self, self.source == .microphone else { return }
            self.onDefaultInputChanged?()
        }
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

    static func defaultOutputUID() throws -> String {
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

    // MARK: - microphone

    static func defaultInputDevice() throws -> AudioObjectID {
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var addr = address(kAudioHardwarePropertyDefaultInputDevice)
        let err = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                             &addr, 0, nil, &size, &device)
        guard err == noErr else { throw TapError.coreAudio("get default input device", err) }
        guard device != kAudioObjectUnknown else { throw TapError.noInputDevice }
        return device
    }

    /// The default input's name as Sound settings shows it, or nil with no
    /// input at all. Needs no grant: it is a property read, not IO.
    static func defaultInputName() -> String? {
        guard let device = try? defaultInputDevice() else { return nil }
        return cfString(device, kAudioObjectPropertyName)
    }

    /// What the device's IOProc will deliver: the virtual format of its first
    /// input stream. Read from the stream itself rather than the device's
    /// stream-format property, which is deprecated and reads the same stream.
    private static func inputFormat(of device: AudioObjectID) throws -> TapFormat {
        var streamsAddr = address(kAudioDevicePropertyStreams, kAudioDevicePropertyScopeInput)
        var size: UInt32 = 0
        var err = AudioObjectGetPropertyDataSize(device, &streamsAddr, 0, nil, &size)
        guard err == noErr else { throw TapError.coreAudio("get input streams", err) }
        var streams = [AudioObjectID](repeating: 0,
                                      count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard !streams.isEmpty else { throw TapError.noInputDevice }
        err = AudioObjectGetPropertyData(device, &streamsAddr, 0, nil, &size, &streams)
        guard err == noErr else { throw TapError.coreAudio("get input streams", err) }

        var asbd = AudioStreamBasicDescription()
        var asbdSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var fmtAddr = address(kAudioStreamPropertyVirtualFormat)
        err = AudioObjectGetPropertyData(streams[0], &fmtAddr, 0, nil, &asbdSize, &asbd)
        guard err == noErr else { throw TapError.coreAudio("get input stream format", err) }
        // The HAL hands clients Float32 whatever the hardware speaks, so this is
        // a guard rather than a code path: the sink reads the buffers as floats.
        guard asbd.mFormatID == kAudioFormatLinearPCM,
              asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              asbd.mBitsPerChannel == 32, asbd.mChannelsPerFrame > 0 else {
            throw TapError.inputFormat(
                "id \(asbd.mFormatID), \(asbd.mBitsPerChannel)-bit, flags \(asbd.mFormatFlags)")
        }
        return TapFormat(
            sampleRate: asbd.mSampleRate,
            channels: asbd.mChannelsPerFrame,
            isInterleaved: (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) == 0)
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
    static func objectIDs(forFamily familyID: String) -> [AudioObjectID] {
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

        // Idempotent, and that is load-bearing. Overwriting `tapID` without
        // tearing the old one down orphans it — and if it had already been
        // started, its aggregate and IOProc keep delivering that source's audio
        // into the same sink forever, unreachable by any later `stop()`. Startup
        // does exactly that, which is why switching source appeared to do nothing:
        // the leaked device kept feeding whatever was selected at launch.
        stop()

        let desc: CATapDescription
        switch source {
        case .microphone:
            // No tap and no aggregate: the input device is read as it is, and
            // its own format is what the sink gets. A microphone is usually
            // mono and not always 48 kHz, which is why the caller compares what
            // this returns with what the core was built for.
            let device = try Self.defaultInputDevice()
            format = try Self.inputFormat(of: device)
            inputDevice = device
            self.source = .microphone
            FileHandle.standardError.write(
                ("microphone → \(Self.cfString(device, kAudioObjectPropertyName) ?? "?") "
                    + "\(Int(format.sampleRate)) Hz, \(format.channels) ch\n").data(using: .utf8)!)
            return format
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

            // What actually got tapped. A scoping bug is invisible otherwise: the
            // tap builds and runs either way, and the only symptom is hearing the
            // wrong app.
            let detail = objectIDs.map { id -> String in
                let pid = Self.uint32(id, kAudioProcessPropertyPID).map { pid_t(bitPattern: $0) }
                let bundle = Self.cfString(id, kAudioProcessPropertyBundleID) ?? "—"
                let live = (Self.uint32(id, kAudioProcessPropertyIsRunningOutput) ?? 0) != 0
                return "obj \(id) pid \(pid.map(String.init) ?? "?") \(bundle)\(live ? " ●" : "")"
            }
            FileHandle.standardError.write(
                ("tap → \(name) [\(familyID)] exclusive=\(desc.isExclusive) "
                    + "processes=\(desc.processes.count): \(detail.joined(separator: ", "))\n")
                    .data(using: .utf8)!)
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

    /// Starts IO. `prepare()` must have run first.
    ///
    /// A tap needs an aggregate device built for its IOProc to run on; the
    /// microphone's IOProc runs on the input device itself.
    func start() throws {
        // Already running. Stacking a second IOProc on one device leaks the
        // first the same way `prepare()` describes.
        guard procID == nil else { return }
        if inputDevice != kAudioObjectUnknown {
            try installIOProc(on: inputDevice, allBuffers: false)
            return
        }
        guard let desc = tapDescription else { throw TapError.notPrepared }
        guard aggID == kAudioObjectUnknown else { return }
        let outputUID = try Self.defaultOutputUID()

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
        let err = AudioHardwareCreateAggregateDevice(aggDescription as CFDictionary, &aggID)
        guard err == noErr else {
            throw TapError.coreAudio("AudioHardwareCreateAggregateDevice", err)
        }
        try installIOProc(on: aggID, allBuffers: true)
    }

    /// The realtime callback on `device`: hand samples straight to the core and
    /// return. Every buffer for the aggregate, whose input is the tap's stream;
    /// the first only for a microphone, since an interface that splits its
    /// inputs into streams would otherwise feed each of them to the sink in
    /// turn as though they were one.
    private func installIOProc(on device: AudioObjectID, allBuffers: Bool) throws {
        let sink = onAudio
        var err = AudioDeviceCreateIOProcIDWithBlock(&procID, device, nil) { _, input, _, _, _ in
            let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            for buffer in abl.prefix(allBuffers ? abl.count : 1) {
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
        procHost = device

        err = AudioDeviceStart(device, procID)
        guard err == noErr else { throw TapError.coreAudio("AudioDeviceStart", err) }
    }

    /// Take `source` as the one to bring up next, tearing the current one down
    /// now. Nothing is built here: `resumeCapture` in main.swift does that, so
    /// a switch made while paused waits for the resume the way a variant switch
    /// does — and so the new format can be compared with the core's before a
    /// sample arrives. Replaces a `switchTo` that prepared and started in one
    /// go and could only report a format change after the fact.
    func select(_ source: AudioSource) {
        stop()
        self.source = source
    }

    /// Tear down IO, then the aggregate, then the tap — that order is required.
    ///
    /// Returns false if any step failed. Every status used to be discarded, which
    /// is exactly what makes a source switch unreliable: a surviving IOProc keeps
    /// delivering the *previous* app's audio into the same sink, and the only
    /// symptom is still hearing the app you just switched away from. Worse,
    /// `procID` was cleared regardless, so no later `stop()` could reach it.
    @discardableResult
    func stop() -> Bool {
        var ok = true
        func check(_ what: String, _ status: OSStatus) -> Bool {
            guard status != noErr else { return true }
            ok = false
            FileHandle.standardError.write(
                "tap teardown: \(what) failed (\(status))\n".data(using: .utf8)!)
            return false
        }

        if let procID {
            _ = check("AudioDeviceStop", AudioDeviceStop(procHost, procID))
            // Only forget the IOProc once it is genuinely gone — which it also
            // is when its device is: a microphone unplugged takes its IOProcs
            // with it, and keeping the ID would refuse every later start as
            // already running.
            let destroyed = AudioDeviceDestroyIOProcID(procHost, procID)
            let deviceGone = destroyed == kAudioHardwareBadDeviceError
                || destroyed == kAudioHardwareBadObjectError
            if check("AudioDeviceDestroyIOProcID", destroyed) || deviceGone {
                self.procID = nil
                procHost = AudioObjectID(kAudioObjectUnknown)
            }
        }
        if aggID != kAudioObjectUnknown,
           check("AudioHardwareDestroyAggregateDevice", AudioHardwareDestroyAggregateDevice(aggID)) {
            aggID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown,
           check("AudioHardwareDestroyProcessTap", AudioHardwareDestroyProcessTap(tapID)) {
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
        inputDevice = AudioObjectID(kAudioObjectUnknown)
        tapDescription = nil
        return ok
    }

    deinit { stop() }
}
