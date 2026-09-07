// Shows every state of the update window without a feed, and captures each.
//
//   swiftc -O -o build/update-window-harness \
//     tools/update-window-harness/main.swift app/macos/UpdateWindow.swift app/macos/Dialog.swift \
//     app/captions/ReleaseNotes.swift -framework AppKit
//   build/update-window-harness build/update-window-states
//
// In a directory of its own, named main.swift, because that is the one file
// name swiftc allows top-level code in when it is given several files.
//
// The window is the app's own file, compiled in as it is; ReleaseNotes comes
// along because UpdateWindow sets the notes with it, and outside the package
// there is no CaptionCore module to import it from. Each state is captured
// by window number into the directory given, one PNG per state, and the
// window is torn down after — it takes the keyboard while it is up, so the
// whole run is a few seconds. Not part of the build; PLAN.md §23.

import AppKit

setvbuf(stdout, nil, _IONBF, 0)
let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "build/update-window-states"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
if let icon = NSImage(contentsOfFile: "build/Subtitles.app/Contents/Resources/AppIcon.icns") {
    app.applicationIconImage = icon
}

let notes = ReleaseNotes(html: """
    <h2>1.5.0 · 2026-09-07</h2>
    <ul>
      <li>The app can update itself. <strong>Check for Updates…</strong> in the menu bar asks
      subtitles-live.com for a newer version and installs it in place — same location, same
      signature — so the audio permission survives an update the way it survives a rebuild.</li>
      <li>A check that finds something does not open a window over whatever you are doing: a
      red badge appears on the icon, the menu offers <strong>Update to …</strong>, and the
      window comes only when you choose it.</li>
      <li><code>--feed URL</code> points the check at another appcast, for trying an update
      against a local server.</li>
    </ul>
    """)

let none: () -> Void = {}
let window = UpdateWindow()
let states: [(String, UpdateWindow.State, NSAppearance.Name)] = [
    ("1-found", .found(version: "1.5.0", current: "1.4.3", size: "4.1 MB", notes: notes,
                       critical: false, install: none, later: none, skip: none), .aqua),
    ("2-downloading", .downloading(version: "1.5.0", cancel: none), .aqua),
    ("3-extracting", .extracting(version: "1.5.0"), .aqua),
    ("4-ready", .ready(version: "1.5.0", install: none, later: none), .aqua),
    ("5-installing", .installing(version: "1.5.0", retry: nil), .aqua),
    ("6-installing-stuck", .installing(version: "1.5.0", retry: none), .aqua),
    ("7-permission", .permission(allow: none, decline: none), .aqua),
    ("8-checking", .checking(cancel: none), .aqua),
    ("9-uptodate", .upToDate(version: "1.5.0", dismiss: none), .aqua),
    ("10-failed", .failed(title: "Couldn't update",
                          message: "subtitles-live.com did not answer. Nothing has changed; try again when you are online.",
                          retry: none, dismiss: none), .aqua),
    ("11-critical", .found(version: "1.5.1", current: "1.5.0", size: "4.1 MB", notes: notes,
                           critical: true, install: none, later: none, skip: nil), .aqua),
    ("12-found-dark", .found(version: "1.5.0", current: "1.4.3", size: "4.1 MB", notes: notes,
                             critical: false, install: none, later: none, skip: none), .darkAqua),
]

func capture(_ name: String) {
    guard let native = window.nativeWindow else { return }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    p.arguments = ["-x", "-o", "-l", String(native.windowNumber), "\(outDir)/\(name).png"]
    try? p.run()
    p.waitUntilExit()
    print("captured \(name)")
}

var index = 0
func step() {
    guard index < states.count else { app.terminate(nil); return }
    let (name, state, appearance) = states[index]
    window.show(state)
    window.nativeWindow?.appearance = NSAppearance(named: appearance)
    if name == "2-downloading" { window.progress(fraction: 0.44, detail: "1.8 MB of 4.1 MB") }
    if name == "3-extracting" { window.progress(fraction: 0.7, detail: nil) }
    window.nativeWindow?.displayIfNeeded()
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
        capture(name)
        index += 1
        step()
    }
}
DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: step)
// Never leave the window up: it holds the keyboard.
DispatchQueue.global().asyncAfter(deadline: .now() + 30) { exit(1) }
app.run()
