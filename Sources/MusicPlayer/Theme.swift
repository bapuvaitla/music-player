import SwiftUI
import AppKit

/// A soft, warm palette for the app's own background surfaces — used in
/// place of the stock system window background wherever SwiftUI can
/// cleanly paint one. Native AppKit-backed views (the sidebar's `List`,
/// the track `Table`) draw their own opaque background and aren't
/// affected by this — see the Learn Song / mini player usages for where
/// it applies.
///
/// Adapts to light/dark automatically via `NSColor`'s dynamic provider —
/// the same mechanism system colors use — so call sites never need an
/// `@Environment(\.colorScheme)` read.
extension Color {
    static let appBackground = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0.063, green: 0.078, blue: 0.165, alpha: 1.0) // midnight blue
            : NSColor(srgbRed: 0.930, green: 0.916, blue: 0.876, alpha: 1.0) // soft warm white, a bit deeper
    })

    /// A "lifted" surface for cards/panels sitting on top of
    /// `appBackground` — brighter than the page in both themes, so a
    /// panel always reads as elevated rather than recessed. (A plain
    /// `Color.secondary` tint darkens a light page but lightens a dark
    /// one — inconsistent, and in light mode it was dimming the tab
    /// view's already-small numbers.)
    static let panelBackground = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0.114, green: 0.137, blue: 0.239, alpha: 1.0) // lighter slate-navy
            : NSColor(srgbRed: 0.965, green: 0.965, blue: 0.968, alpha: 1.0) // soft light gray, not stark white
    })

    /// The sidebar's own background — separate from `appBackground`
    /// because the two ended up needing different light-mode answers: a
    /// warm cream reads fine as a full-page background (Learn Song), but
    /// sitting directly beside the plain white/native track table it read
    /// as an odd, overly prominent clash. A neutral light gray (closer to
    /// what Finder/Mail sidebars use) sits quietly next to that native
    /// content instead. Dark mode keeps the same midnight blue as
    /// `appBackground` — that one already reads well.
    static let sidebarBackground = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0.063, green: 0.078, blue: 0.165, alpha: 1.0) // midnight blue
            : NSColor(srgbRed: 0.906, green: 0.930, blue: 0.895, alpha: 1.0) // soft sage green
    })

    /// A custom accent green, standing in for the system accent color on
    /// the track table's selection highlight and "currently playing" row
    /// text — so those read as part of the app's own sage-green theme
    /// instead of whatever blue the user's system accent color happens to
    /// be set to.
    static let appAccent = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0.298, green: 0.851, blue: 0.392, alpha: 1.0) // vibrant spring green, for contrast on midnight blue
            : NSColor(srgbRed: 0.086, green: 0.545, blue: 0.223, alpha: 1.0) // vivid kelly green, for contrast on white
    })

    /// The tuner popover's own background — a dark brown rather than the
    /// app's standard panel surface, so the tuner reads as its own
    /// distinct instrument rather than just another panel. Same dark
    /// brown in both appearances since the popover already floats above
    /// whatever's behind it.
    static let tunerPopoverBackground = Color(nsColor: NSColor(srgbRed: 0.145, green: 0.098, blue: 0.075, alpha: 1.0))
}
