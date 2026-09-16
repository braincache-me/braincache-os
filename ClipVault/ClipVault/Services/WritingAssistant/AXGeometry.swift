import AppKit

/// Coordinate-space helpers for the Writing Assistant.
///
/// The Accessibility API and Quartz report rects with a top-left origin (y
/// grows downward), while AppKit windows are placed in a bottom-left origin
/// space (y grows upward). Both systems share their origin at the top-left /
/// bottom-left corner of the primary screen, so a single vertical flip about
/// the primary screen's height converts between them — for every screen in the
/// arrangement, not just the primary one.
enum AXGeometry {

    /// Height of the primary screen (the one with Cocoa origin `(0, 0)`), which
    /// is the flip axis shared by both coordinate spaces.
    private static var primaryHeight: CGFloat {
        NSScreen.screens.first?.frame.height ?? 0
    }

    /// Converts an AX / Quartz rect (top-left origin) to AppKit screen
    /// coordinates (bottom-left origin).
    static func cocoaRect(fromAXRect axRect: CGRect) -> CGRect {
        CGRect(
            x: axRect.origin.x,
            y: primaryHeight - axRect.origin.y - axRect.height,
            width: axRect.width,
            height: axRect.height
        )
    }
}
