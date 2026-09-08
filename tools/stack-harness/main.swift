// Does a wider box arriving move the boxes already up? It used to (1.6.1).
//
// The ⌥ stack is presented with two short boxes over a white backdrop, then
// again with a much wider box added, and the region is captured before and
// at 16, 40, 80 and 500 ms after. measure.py reads each capture and prints
// every box's left and right edge; the two short boxes must print the same
// numbers in every file. Against the History.swift before StackLayout they
// were 149 points to the right at 16 ms and still 10 off at 40 ms.
//
//   D=build/stack-harness; mkdir -p $D
//   swiftc -O -emit-library -emit-module -module-name CaptionCore \
//     -o $D/libCaptionCore.dylib app/captions/*.swift
//   swiftc -O -o $D/harness tools/stack-harness/main.swift tools/stack-harness/stubs.swift \
//     app/macos/History.swift app/macos/Pill.swift app/macos/Hotkey.swift \
//     -I $D -L $D -lCaptionCore -I core/include -Lcore/target/release -lsubs_core \
//     -framework AppKit -framework Carbon
//   DYLD_LIBRARY_PATH=$D $D/harness $D/shots && python3 tools/stack-harness/measure.py $D/shots
//
// CaptionCore is built as a library first because History.swift imports it
// as a module, and there is no module to import outside the package. The
// harness takes the screen for two seconds; nothing else should be moving
// in the region it captures. Not part of the build.
import AppKit

setvbuf(stdout, nil, _IONBF, 0)
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let outDir = CommandLine.arguments[1]

// A white backdrop under the stack, so the boxes' edges are trivially findable.
let region = NSRect(x: 500, y: 200, width: 600, height: 700)
let backdrop = NSWindow(contentRect: region, styleMask: [.borderless], backing: .buffered, defer: false)
backdrop.backgroundColor = .white
backdrop.level = .floating
backdrop.orderFrontRegardless()

let history = HistoryController()
let style = HistoryStyle(fontSize: 30, maxLines: 2, fill: 0.7, textOpacity: 0.85)
let anchor = NSRect(x: 750, y: 220, width: 100, height: 60)   // the live box, bottom centre
let centreX: CGFloat = 800

func capture(_ name: String) {
    let screenH = NSScreen.main!.frame.height
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    let top = screenH - region.maxY
    p.arguments = ["-x", "-R", "\(Int(region.minX)),\(Int(top)),\(Int(region.width)),\(Int(region.height))", "\(outDir)/\(name).png"]
    try? p.run(); p.waitUntilExit()
    print("captured \(name)")
}

let short = ["Short one.", "Tiny."]
let wide = short + ["A much wider box than either of the two above it, arriving now."]
DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
    history.present(entries: short, style: style, anchor: anchor, centreX: centreX, maxWidth: 700, animated: false)
}
DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { capture("0-before") }
DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) {
    history.present(entries: wide, style: style, anchor: anchor, centreX: centreX, maxWidth: 700, animated: false)
}
for (i, delay) in [0.016, 0.04, 0.08, 0.5].enumerated() {
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.3 + delay) { capture("\(i + 1)-after-\(Int(delay * 1000))ms") }
}
DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { app.terminate(nil) }
DispatchQueue.global().asyncAfter(deadline: .now() + 6) { exit(1) }
app.run()
