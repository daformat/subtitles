// What History.swift needs from Overlay.swift, without Overlay.swift.
import AppKit

enum SubtitleView {
    static let pad: CGFloat = 4
    static let secondaryScale: CGFloat = 0.8
    static let secondaryOpacity: CGFloat = 0.75
    static func secondaryGap(for size: CGFloat) -> CGFloat { (size * 0.35).rounded() }
}
