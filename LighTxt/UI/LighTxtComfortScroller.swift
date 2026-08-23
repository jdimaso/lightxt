import AppKit

/// A native AppKit scroller with a slightly more forgiving track and hit area.
///
/// The extra two points are deliberately modest. AppKit still draws and tracks
/// every part, honors the user's preferred overlay/legacy style, and controls
/// when managed scroll-view scrollers appear.
@MainActor
final class LighTxtComfortScroller: NSScroller {
    static let addedThickness: CGFloat = 2

    override class var isCompatibleWithOverlayScrollers: Bool { true }

    override class func scrollerWidth(
        for controlSize: NSControl.ControlSize,
        scrollerStyle: NSScroller.Style
    ) -> CGFloat {
        super.scrollerWidth(for: controlSize, scrollerStyle: scrollerStyle)
            + addedThickness
    }

    static func install(
        in scrollView: NSScrollView,
        vertical: Bool,
        horizontal: Bool
    ) {
        if vertical, !(scrollView.verticalScroller is LighTxtComfortScroller) {
            let scroller = replacement(
                for: scrollView.verticalScroller,
                in: scrollView
            )
            scrollView.verticalScroller = scroller
        }
        if horizontal, !(scrollView.horizontalScroller is LighTxtComfortScroller) {
            let scroller = replacement(
                for: scrollView.horizontalScroller,
                in: scrollView
            )
            scrollView.horizontalScroller = scroller
        }
    }

    private static func replacement(
        for existing: NSScroller?,
        in scrollView: NSScrollView
    ) -> LighTxtComfortScroller {
        let scroller = LighTxtComfortScroller()
        scroller.controlSize = existing?.controlSize ?? .regular
        scroller.scrollerStyle = scrollView.scrollerStyle
        scroller.knobStyle = scrollView.scrollerKnobStyle
        return scroller
    }
}
