import SwiftUI
import AppKit

/// The app-wide text font, chosen by the user via the toolbar's font picker
/// and applied to the whole window through `.environment(\.font, ...)` —
/// most row/label text in the app doesn't set its own explicit `.font()`,
/// so it inherits whatever this resolves to.
///
/// Rather than a curated shortlist, this enumerates every font family
/// actually installed on the Mac (via `NSFontManager`), same as the
/// system Font menu — the user's own installed fonts (EB Garamond, CMU
/// Serif, Minion Pro, etc.) just show up.
struct FontFace: Identifiable, Hashable {
    let postscriptName: String
    let styleName: String
    var id: String { postscriptName }
}

enum InstalledFonts {
    /// Every installed family name, alphabetically.
    static var familyNames: [String] {
        NSFontManager.shared.availableFontFamilies
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// The family's non-bold, non-italic faces (its distinct weights —
    /// UltraLight, Light, Regular, Medium, …), lightest first, deduplicated
    /// by style name. Most families have exactly one; a few (like
    /// Helvetica Neue) have several worth picking between individually.
    static func weightFaces(forFamily family: String) -> [FontFace] {
        guard let members = NSFontManager.shared.availableMembers(ofFontFamily: family), !members.isEmpty else {
            return []
        }
        var seenStyles = Set<String>()
        let faces: [(face: FontFace, weight: Int)] = members.compactMap { member in
            guard let postscriptName = member[safe: 0] as? String,
                  let styleName = member[safe: 1] as? String,
                  let weight = member[safe: 2] as? Int else { return nil }
            let traits = (member[safe: 3] as? Int).map { NSFontTraitMask(rawValue: UInt($0)) } ?? []
            guard !traits.contains(.italicFontMask), !traits.contains(.boldFontMask) else { return nil }
            guard seenStyles.insert(styleName).inserted else { return nil }
            return (FontFace(postscriptName: postscriptName, styleName: styleName), weight)
        }
        return faces.sorted { $0.weight < $1.weight }.map(\.face)
    }

    /// A representative (regular-weight where possible) face for a family
    /// — used as the default when the family itself, not a specific
    /// weight, is selected.
    static func defaultFace(forFamily family: String) -> FontFace? {
        let faces = weightFaces(forFamily: family)
        let preferredStyles: Set<String> = ["Regular", "Roman", "Book", "Normal"]
        return faces.first(where: { preferredStyles.contains($0.styleName) }) ?? faces.first
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
