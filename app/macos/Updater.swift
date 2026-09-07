// In-app updates, through Sparkle (PLAN.md §23).
//
// Sparkle does the work: the daily check, the EdDSA and Developer ID checks on
// what it downloads, the swap in /Applications, the relaunch. This file is the
// part it leaves to the app — what a check looks like — and it answers that
// two ways. Sparkle's own windows are replaced by UpdateWindow, one window in
// the app's style that every state of an update passes through. And a check
// the app ran on its own decides whether to open that window at all:
//
//   - at launch, or once the Mac has been quiet a while: the window, because
//     nobody is mid-call then;
//   - while audio is playing: no window. A red 1 on the icon and "Update to
//     1.5.1…" at the top of the menu, and the window when that is chosen;
//   - a critical update: the window, whatever is playing. That is the fix
//     nobody should sit out, and it is the reason the updater exists.
//
// Sparkle calls this object the user driver; the protocol is the list of
// moments an update has, and each one here becomes an UpdateWindow state.
// Built without `SPUStandardUpdaterController` on purpose: the controller
// wraps Sparkle's standard driver, which is the thing being replaced, and it
// reports a failure to start as an alert, where a build run straight from
// `.build` with no Info.plist around it would greet every launch with one.

import AppKit
import CaptionCore
import Sparkle

final class Updater: NSObject, SPUUpdaterDelegate, SPUUserDriver {
    /// An appcast to use instead of the plist's, from `--feed`, for trying an
    /// update against a local server. Never a default: the plist is what ships,
    /// and a dev feed that leaked into it would ship too.
    var feedOverride: String?

    /// The version a check has found and not yet installed, or nil. The menu
    /// reads it; the icon badges on it. Survives a Later, and a relaunch: a
    /// version once seen stays a badge until it is installed or skipped.
    private(set) var pendingVersion: String? {
        didSet {
            guard pendingVersion != oldValue else { return }
            UserDefaults.standard.set(pendingVersion, forKey: Self.pendingKey)
            onPendingChange?()
        }
    }
    /// Fired on the main thread whenever `pendingVersion` changes, so the menu
    /// bar refreshes rather than polls.
    var onPendingChange: (() -> Void)?

    /// How long nothing has been playing, in seconds — or infinity while
    /// paused. Wired by main.swift. This, not the keyboard, is the idle signal:
    /// someone watching a film with captions on touches nothing for two hours,
    /// and that is exactly when a window must not appear.
    var quietFor: () -> TimeInterval = { 0 }
    /// Whether a window may open unasked right now: false while the welcome
    /// window is up, where a second dialog would be one too many.
    var mayInterrupt: () -> Bool = { true }

    /// True once the updater is up. False leaves the menu items hidden rather
    /// than offering a check that cannot run.
    private(set) var started = false

    private var updater: SPUUpdater?
    private let window = UpdateWindow()
    private let launchedAt = Date()

    /// A scheduled update held back from the window, waiting in the menu.
    private var held: (item: SUAppcastItem, reply: (SPUUserUpdateChoice) -> Void)?
    /// The update in progress, for the version in the window's headlines.
    private var current: SUAppcastItem?
    private var expectedBytes: UInt64 = 0
    private var receivedBytes: UInt64 = 0
    /// Bumped on every state, so a delayed follow-up can tell whether the
    /// state it was scheduled for is still the one showing.
    private var generation = 0

    private static let pendingKey = "updates.pending"
    /// Seconds after launch within which a found update is "at launch".
    private static let launchWindow: TimeInterval = 90
    /// Seconds of nothing playing after which the Mac counts as quiet.
    private static let quietThreshold: TimeInterval = 120

    /// Whether the app checks on its own, once a day. Sparkle persists the
    /// answer in the app's defaults.
    var automaticChecks: Bool {
        get { updater?.automaticallyChecksForUpdates ?? false }
        set { updater?.automaticallyChecksForUpdates = newValue }
    }

    func start() {
        let bundle = Bundle.main
        let updater = SPUUpdater(hostBundle: bundle, applicationBundle: bundle,
                                 userDriver: self, delegate: self)
        do {
            try updater.start()
            self.updater = updater
            started = true
        } catch {
            // No feed URL, no public key, no bundle: all of them mean this is not
            // a build that can be updated, and none of them is worth a dialog.
            FileHandle.standardError.write(
                "updater not started: \(error.localizedDescription)\n".data(using: .utf8)!)
            return
        }
        pendingVersion = UserDefaults.standard.string(forKey: Self.pendingKey)
        // A version seen last time and put off with Later comes back at the
        // next launch, not a day later: Sparkle's own schedule would wait out
        // the interval, and launch is the moment the window is welcome.
        if pendingVersion != nil, updater.automaticallyChecksForUpdates {
            updater.checkForUpdatesInBackground()
        }
    }

    /// The explicit check, from the menu. Also the way a held update is
    /// brought into the window: Sparkle sees the session still open and asks
    /// for it in focus.
    func checkForUpdates() {
        guard let updater else { return }
        NSApp.activate(ignoringOtherApps: true)
        updater.checkForUpdates()
    }

    // MARK: SPUUpdaterDelegate

    func feedURLString(for updater: SPUUpdater) -> String? { feedOverride }

    // MARK: SPUUserDriver — the question

    func show(_ request: SPUUpdatePermissionRequest,
              reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        generation += 1
        window.show(.permission(
            allow: { [weak self] in
                reply(SUUpdatePermissionResponse(automaticUpdateChecks: true, sendSystemProfile: false))
                self?.window.close()
            },
            decline: { [weak self] in
                reply(SUUpdatePermissionResponse(automaticUpdateChecks: false, sendSystemProfile: false))
                self?.window.close()
            }))
    }

    // MARK: SPUUserDriver — checking

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        generation += 1
        window.show(.checking(cancel: cancellation))
    }

    func showUpdateFound(with item: SUAppcastItem, state: SPUUserUpdateState,
                         reply: @escaping (SPUUserUpdateChoice) -> Void) {
        current = item
        pendingVersion = item.displayVersionString
        let atLaunch = Date().timeIntervalSince(launchedAt) < Self.launchWindow
        let quiet = quietFor() >= Self.quietThreshold
        let interrupt = state.userInitiated || item.isCriticalUpdate
            || ((atLaunch || quiet) && mayInterrupt())
        if interrupt {
            held = nil
            present(item, reply: reply)
        } else {
            held = (item, reply)
        }
    }

    /// Sparkle asking for the update it already found to be shown — the menu's
    /// "Update to X…" while a scheduled update is being held.
    func showUpdateInFocus() {
        if let held {
            self.held = nil
            present(held.item, reply: held.reply)
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func present(_ item: SUAppcastItem, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        generation += 1
        let installed = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
            as? String ?? "an older version"
        let size = item.contentLength > 0
            ? ByteCountFormatter.string(fromByteCount: Int64(item.contentLength), countStyle: .file)
            : nil
        let notes = item.itemDescription.map { ReleaseNotes(html: $0) }
        window.show(.found(
            version: item.displayVersionString, current: installed, size: size, notes: notes,
            critical: item.isCriticalUpdate,
            install: { [weak self] in
                // The badge comes down now rather than after the relaunch: the
                // relaunched app is the new version, and a badge on it would
                // be offering it to itself.
                self?.pendingVersion = nil
                reply(.install)
            },
            later: { reply(.dismiss) },
            skip: item.isCriticalUpdate ? nil : { [weak self] in
                self?.pendingVersion = nil
                reply(.skip)
            }))
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {
        // Notes are embedded in the appcast; a linked page is never fetched.
    }

    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {}

    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        generation += 1
        pendingVersion = nil
        let info = (error as NSError).userInfo
        let installed = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
            as? String ?? ""
        let onLatest = (info[SPUNoUpdateFoundReasonKey] as? Int)
            .map { $0 == SPUNoUpdateFoundReason.onLatestVersion.rawValue } ?? true
        let dismiss: () -> Void = { [weak self] in acknowledgement(); self?.window.close() }
        if onLatest {
            window.show(.upToDate(version: installed, dismiss: dismiss))
        } else {
            // Newer than what this Mac can run, most likely. Sparkle's text
            // says which.
            window.show(.failed(title: "No update for this Mac",
                                message: error.localizedDescription, retry: nil, dismiss: dismiss))
        }
    }

    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        generation += 1
        let nsError = error as NSError
        // A cancel is not a failure, and not worth a window saying so.
        if nsError.domain == SUSparkleErrorDomain,
           nsError.code == Int(SUError.installationCanceledError.rawValue) {
            acknowledgement()
            window.close()
            return
        }
        var message = error.localizedDescription
        if let suggestion = nsError.localizedRecoverySuggestion, !suggestion.isEmpty {
            message += " " + suggestion
        }
        window.show(.failed(
            title: "Couldn't update",
            message: message,
            retry: { [weak self] in
                acknowledgement()
                self?.window.close()
                self?.checkForUpdates()
            },
            dismiss: { [weak self] in acknowledgement(); self?.window.close() }))
    }

    // MARK: SPUUserDriver — downloading and unpacking

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        generation += 1
        expectedBytes = 0
        receivedBytes = 0
        window.show(.downloading(version: current?.displayVersionString ?? "the update",
                                 cancel: cancellation))
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        expectedBytes = expectedContentLength
        showDownloadProgress()
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        receivedBytes += length
        showDownloadProgress()
    }

    private func showDownloadProgress() {
        let got = ByteCountFormatter.string(fromByteCount: Int64(receivedBytes), countStyle: .file)
        guard expectedBytes > 0 else {
            window.progress(fraction: nil, detail: got)
            return
        }
        let total = ByteCountFormatter.string(fromByteCount: Int64(expectedBytes), countStyle: .file)
        window.progress(fraction: min(1, Double(receivedBytes) / Double(expectedBytes)),
                        detail: "\(got) of \(total)")
    }

    func showDownloadDidStartExtractingUpdate() {
        generation += 1
        window.show(.extracting(version: current?.displayVersionString ?? "the update"))
    }

    func showExtractionReceivedProgress(_ progress: Double) {
        window.progress(fraction: progress, detail: nil)
    }

    // MARK: SPUUserDriver — installing

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        generation += 1
        window.show(.ready(
            version: current?.displayVersionString ?? "the update",
            install: { reply(.install) },
            later: { reply(.dismiss) }))
    }

    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool,
                              retryTerminatingApplication: @escaping () -> Void) {
        generation += 1
        let version = current?.displayVersionString ?? "the update"
        window.show(.installing(version: version, retry: nil))
        guard !applicationTerminated else { return }
        // The app has been asked to quit. If it is still here in a few seconds,
        // something is holding it open, and the person gets a button to try
        // again rather than a bar that never fills.
        let expected = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, self.generation == expected else { return }
            self.window.show(.installing(version: version, retry: retryTerminatingApplication))
        }
    }

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        acknowledgement()
    }

    func dismissUpdateInstallation() {
        generation += 1
        held = nil
        current = nil
        window.close()
    }
}
