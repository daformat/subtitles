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
import CaptionCore

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
/// `com.google.Chrome.helper`, Safari through a WebKit service that is not
/// even named after it, and tapping the app itself would capture silence. A
/// family groups an app with every helper under its bundle prefix and every
/// process that answers to it (`RunningApps.family`), and the tap covers all
/// of them at once.
struct AudioSourceEntry: Equatable {
    let id: String      // the app's bundle id, or "pid:1234" for unbundled processes
    let name: String
    let isPlaying: Bool
    let pids: [pid_t]
}

/// What to listen to.
///
/// Identified by family id, never by Core Audio object ID: object IDs are
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

    /// The label in the app's language, for what a person reads: the name a
    /// box wears. `label` stays English, for the log and the defaults.
    var displayName: String {
        switch self {
        case .allSystemAudio: return L("All system audio")
        case .microphone: return L("Microphone", "The name the caption box wears when it is captioning the microphone")
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

    /// One process Core Audio knows about, and the family it belongs to.
    private struct AudioProcess {
        let objectID: AudioObjectID
        let pid: pid_t
        let family: (id: String, name: String)
        let isPlaying: Bool
    }

    /// Which app answers for a process, as the system sees it: the one a
    /// permission prompt names when a helper asks for the microphone, and
    /// the one Activity Monitor groups it under. Inherited from the process
    /// that started it, and set afresh by Launch Services for an app it
    /// opens, so a helper answers to its app and an app to itself.
    ///
    /// This is what puts Safari's name on Safari's audio. Safari plays
    /// through a WebKit service, com.apple.WebKit.GPU, that carries neither
    /// Safari's bundle id nor its name; and the same service plays for every
    /// WebKit app, one instance each, so by bundle id alone Safari, Mail and
    /// Raycast were one family, named after whichever instance came first.
    /// Firefox's plugin-container is the same story.
    ///
    /// Private, and looked up by name: libquarantine exports it and TCC is
    /// built on it, but no header declares it. Should it go, the lookup
    /// returns nil, the bundle-prefix rule still folds Chrome's helpers under
    /// Chrome, and Safari is back to its service's name.
    private static let responsiblePID: (@convention(c) (pid_t) -> pid_t)? = {
        guard let symbol = dlsym(dlopen(nil, RTLD_LAZY),
                                 "responsibility_get_pid_responsible_for_pid") else { return nil }
        return unsafeBitCast(symbol, to: (@convention(c) (pid_t) -> pid_t).self)
    }()

    /// The running applications, indexed once per enumeration: every one by
    /// pid, and the Dock-visible ones by bundle id for the prefix rule.
    private struct RunningApps {
        let byPID: [pid_t: NSRunningApplication]
        let regular: [String: NSRunningApplication]

        init() {
            var byPID: [pid_t: NSRunningApplication] = [:]
            var regular: [String: NSRunningApplication] = [:]
            for app in NSWorkspace.shared.runningApplications {
                byPID[app.processIdentifier] = app
                if app.activationPolicy == .regular, let bid = app.bundleIdentifier {
                    regular[bid] = app
                }
            }
            self.byPID = byPID
            self.regular = regular
        }

        /// The family a process belongs to, and what to call it. The name is
        /// the one the box shows for the family: an app's own, or the last
        /// piece of a bundle id for a daemon nobody has named.
        ///
        /// A Dock-visible app is its own family whoever launched it, and so
        /// is a helper under its bundle prefix: "com.google.Chrome.helper"
        /// folds into "com.google.Chrome" even when Chrome was started from
        /// a terminal and answers to it. Only `.regular` apps are prefix
        /// targets. Helpers are themselves running applications, with their
        /// own bundle id and localised name, so matching against every
        /// running app would just re-find the helper and group nothing.
        /// Then the app the process answers to; then the process itself.
        func family(pid: pid_t, bundle: String?) -> (id: String, name: String) {
            if let bundle {
                let parent = regular.keys
                    .filter { bundle == $0 || bundle.hasPrefix($0 + ".") }
                    .max(by: { $0.count < $1.count })
                if let parent { return (parent, name(of: regular[parent], or: parent)) }
            }
            if let responsible = SystemAudioTap.responsiblePID?(pid), responsible != pid,
               let app = byPID[responsible], let bid = app.bundleIdentifier {
                return (bid, name(of: app, or: bid))
            }
            if let bundle { return (bundle, name(of: byPID[pid], or: bundle)) }
            return ("pid:\(pid)", byPID[pid]?.localizedName ?? "pid \(pid)")
        }

        private func name(of app: NSRunningApplication?, or bundle: String) -> String {
            app?.localizedName ?? bundle.split(separator: ".").last.map(String.init) ?? bundle
        }
    }

    /// Every process Core Audio knows about, each with its family. Not
    /// ourselves: our own aggregate device registers as a process doing audio
    /// I/O, and counting it made the permission watchdog fire during ordinary
    /// silence. Nor anything answering to us, for the same reason.
    private static func processes() -> [AudioProcess] {
        let ownPID = getpid()
        let ownBundle = Bundle.main.bundleIdentifier
        let apps = RunningApps()
        var out: [AudioProcess] = []
        for id in processObjectIDs() {
            guard let pidRaw = uint32(id, kAudioProcessPropertyPID) else { continue }
            let pid = pid_t(bitPattern: pidRaw)
            if pid == ownPID { continue }
            var bundle = cfString(id, kAudioProcessPropertyBundleID)
            if bundle?.isEmpty == true { bundle = nil }
            let family = apps.family(pid: pid, bundle: bundle)
            if let ownBundle, bundle == ownBundle || family.id == ownBundle { continue }
            let playing = (uint32(id, kAudioProcessPropertyIsRunningOutput) ?? 0) != 0
            out.append(AudioProcess(objectID: id, pid: pid, family: family, isPlaying: playing))
        }
        return out
    }

    /// Selectable sources, grouped into application families.
    ///
    /// `kAudioProcessPropertyIsRunningOutput` is what makes this useful: it marks
    /// the handful of apps actually making noise right now, so the picker can put
    /// them first instead of showing 38 undifferentiated daemons.
    static func audioSources() -> [AudioSourceEntry] {
        var families: [String: (name: String, playing: Bool, pids: [pid_t])] = [:]
        for process in processes() {
            var entry = families[process.family.id] ?? (process.family.name, false, [])
            entry.playing = entry.playing || process.isPlaying
            entry.pids.append(process.pid)
            families[process.family.id] = entry
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

    /// Object IDs are recycled; resolve them only at the moment of use. The
    /// same attribution as the menu's, so picking Safari taps the WebKit
    /// service that plays for it.
    static func objectIDs(forFamily familyID: String) -> [AudioObjectID] {
        processes().filter { $0.family.id == familyID }.map(\.objectID)
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
                let bundle = Self.cfString(id, kAudioProcessPropertyBundleID) ?? "?"
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
