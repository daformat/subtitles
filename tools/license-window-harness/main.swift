// Shows every state of the licence window without Gumroad, and captures each.
//
//   swiftc -O -o build/license-window-harness \
//     tools/license-window-harness/main.swift app/macos/LicenseWindow.swift \
//     app/macos/Dialog.swift app/license/*.swift -framework AppKit
//   build/license-window-harness build/license-window-states
//
// The sibling of tools/update-window-harness, and built the same way: the
// window is the app's own file, compiled in as it is, with LicenseCore's
// sources alongside because outside the package there is no module to
// import them from. One PNG per state into the directory given, and the
// window torn down after — it takes the keyboard while it is up. Not part of
// the build; PLAN.md §24.

import AppKit

setvbuf(stdout, nil, _IONBF, 0)
let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "build/license-window-states"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
if let icon = NSImage(contentsOfFile: "build/Subtitles.app/Contents/Resources/AppIcon.icns") {
    app.applicationIconImage = icon
}

let none: () -> Void = {}
let key = "E7086052-3FEE43A0-97D4295D-6500E239"
let until = Date().addingTimeInterval(72 * 3600)
func form(_ entitlement: Entitlement, key: String = "", outcome: LicenseWindow.Outcome = .none)
    -> LicenseWindow.State {
    .enter(entitlement: entitlement, key: key, outcome: outcome,
           activate: { _ in }, buy: none, findKey: none, close: none)
}
func licensed(_ entitlement: Entitlement, justActivated: Bool = false, checkNow: Bool = false)
    -> LicenseWindow.State {
    .licensed(entitlement: entitlement, justActivated: justActivated,
              enterAnother: none, checkNow: checkNow ? none : nil, done: none)
}

let window = LicenseWindow()
let states: [(String, LicenseWindow.State, NSAppearance.Name)] = [
    ("1-trial", form(.trial(daysLeft: 6, started: true)), .aqua),
    ("2-trial-unstarted", form(.trial(daysLeft: 7, started: false)), .aqua),
    ("3-expired", form(.expired), .aqua),
    ("4-checking", form(.expired, key: key, outcome: .checking), .aqua),
    ("5-not-a-key", form(.expired, key: "E7086052-3FEE", outcome: .notAKey), .aqua),
    ("6-invalid", form(.expired, key: key, outcome: .invalid(nil)), .aqua),
    ("7-refunded", form(.expired, key: key, outcome: .revoked(.refunded)), .aqua),
    ("8-unreachable", form(.licensed(email: "mat@example.com"), key: key,
                           outcome: .unreachable("The Internet connection appears to be offline.")), .aqua),
    ("9-revoked", form(.revoked(.chargebacked)), .aqua),
    ("10-activated", licensed(.licensed(email: "mat@example.com"), justActivated: true), .aqua),
    ("11-licensed", licensed(.licensed(email: "mat@example.com")), .aqua),
    ("12-provisional", licensed(.provisional(until: until), checkNow: true), .aqua),
    ("13-grandfathered", licensed(.grandfathered), .aqua),
    ("14-expired-dark", form(.expired), .darkAqua),
    ("15-licensed-dark", licensed(.licensed(email: "mat@example.com")), .darkAqua),
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
    window.nativeWindow?.displayIfNeeded()
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
        capture(name)
        index += 1
        step()
    }
}
DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: step)
// Never leave the window up: it holds the keyboard.
DispatchQueue.global().asyncAfter(deadline: .now() + 40) { exit(1) }
app.run()
