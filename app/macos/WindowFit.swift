// Windows that are taller than the screen.
//
// Both of this app's windows size themselves to their content: Settings to
// whichever pane is showing, Welcome to a demo whose height it only learns once
// the page has drawn. On a display with the room that is the right answer and
// there is nothing here to see. On one without, a window sized to its content
// runs off the bottom, and everything down there — the button that dismisses
// Welcome, half the dials in Settings — is simply unreachable. Welcome hides its
// title bar as well, so there is not even anything to drag it back by.
//
// So: what does not fit scrolls, and the window is pulled back inside the screen
// afterwards. The pieces are here rather than in either window because both need
// all three of them and they have to agree.

import AppKit

/// A clip view that holds its content at the top.
///
/// AppKit's origin is bottom-left, so a document taller than its clip view sits
/// at offset zero showing its *last* page — which is how a settings window opens
/// scrolled to the bottom. Flipping the clip view puts zero at the top, where a
/// page of controls starts, and keeps it there as the content grows underneath.
final class TopClipView: NSClipView {
    override var isFlipped: Bool { true }
}

enum WindowFit {
    /// Air left between the window and the edge of the screen.
    static let margin: CGFloat = 24

    /// A scroll view for a page of controls: no border, no background of its
    /// own, and scrollers that are not there until there is something to reach.
    static func scrollView() -> NSScrollView {
        let scroll = NSScrollView()
        scroll.contentView = TopClipView()
        scroll.drawsBackground = false
        scroll.contentView.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        // Nothing here is ever wider than the window, so sideways is never a
        // direction.
        scroll.horizontalScrollElasticity = .none
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        // Off, or the clip view is given insets of its own and stops matching
        // the window it is measured against.
        scroll.automaticallyAdjustsContentInsets = false
        return scroll
    }

    /// Height a window may take up on the screen it is on.
    static func available(for window: NSWindow) -> CGFloat {
        let visible = (window.screen ?? NSScreen.main)?.visibleFrame.height ?? 900
        return visible - margin
    }

    /// What the window costs before any content: its title bar.
    static func chrome(of window: NSWindow) -> CGFloat {
        window.frame.height - window.contentLayoutRect.height
    }

    /// Pull the window back inside the visible frame, moving it as little as
    /// possible: down from the top edge first, since that is the one a window
    /// grows away from.
    static func clamp(_ window: NSWindow) {
        guard let visible = (window.screen ?? NSScreen.main)?.visibleFrame else { return }
        var frame = window.frame
        if frame.maxY > visible.maxY { frame.origin.y = visible.maxY - frame.height }
        if frame.minY < visible.minY { frame.origin.y = visible.minY }
        guard frame.origin != window.frame.origin else { return }
        window.setFrame(frame, display: true, animate: false)
    }

    /// Whether there is anything past the clip view's edge to reach.
    static func canScroll(_ scroll: NSScrollView) -> Bool {
        guard let document = scroll.documentView else { return false }
        return document.frame.height > scroll.contentView.bounds.height + 1
    }

    /// Take the wheel away from a scroll view with nothing to scroll.
    ///
    /// Elastic only while there is somewhere to go: rubber-banding a page that
    /// fits reads as something broken rather than as feedback — and a window
    /// that bounces under a gesture meant for something inside it is worse than
    /// one that simply sits still.
    static func syncScrolling(_ scroll: NSScrollView) {
        scroll.verticalScrollElasticity = canScroll(scroll) ? .allowed : .none
    }

    /// Show the top of whatever the scroll view is holding.
    static func scrollToTop(_ scroll: NSScrollView) {
        guard let document = scroll.documentView else { return }
        let top = scroll.contentView.isFlipped ? 0 : max(0, document.frame.height
            - scroll.contentView.bounds.height)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: top))
        scroll.reflectScrolledClipView(scroll.contentView)
    }
}
