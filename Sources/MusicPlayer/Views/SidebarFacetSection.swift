import SwiftUI
import AppKit
import MusicPlayerKit

/// A collapsible (closed by default) sidebar section that acts like a set
/// of toggleable tags. Click behavior follows standard macOS list
/// selection conventions: a plain click replaces the selection with just
/// that item, Cmd-click toggles it in/out of the selection, and
/// Shift-click selects the contiguous range from the last-clicked item.
/// Used for Artists, Albums, and Genres.
struct SidebarFacetSection: View {
    let title: String
    let systemImage: String
    let items: [String]
    let counts: [String: Int]
    var ratings: [String: Double]? = nil
    /// Items whose rating average should render muted — e.g. an album
    /// where only some tracks are rated, so the number is incomplete.
    var partiallyRatedItems: Set<String>? = nil
    let selected: Set<String>
    let onSelectionChange: (Set<String>) -> Void
    let onClear: () -> Void
    /// Only used for the Albums section — "Show All Tracks" unhides every
    /// hidden track in that album.
    var onShowAllTracks: ((String) -> Void)? = nil

    @State private var isExpanded = false
    @State private var query = ""
    @State private var anchorIndex: Int?
    /// Only meaningful (and only shown) when `ratings` is provided — lets
    /// the Albums section be sorted by score instead of alphabetically.
    /// Shared across sections since only one section (Albums) ever passes
    /// ratings in practice.
    @AppStorage("sidebarFacetSortByRating") private var sortByRating = false

    private var visibleItems: [String] {
        let sorted: [String]
        if let ratings, sortByRating {
            sorted = items.sorted { lhs, rhs in
                let left = ratings[lhs] ?? -1
                let right = ratings[rhs] ?? -1
                if left != right { return left > right }
                return lhs.localizedStandardCompare(rhs) == .orderedAscending
            }
        } else {
            sorted = items.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        }
        guard !query.isEmpty else { return sorted }
        return sorted.filter { $0.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    TextField("", text: $query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11))
                    if ratings != nil {
                        Button {
                            sortByRating.toggle()
                        } label: {
                            Image(systemName: sortByRating ? "star.fill" : "textformat")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help(sortByRating ? "Sorted by rating — click to sort A–Z" : "Sorted A–Z — click to sort by rating")
                    }
                    if !selected.isEmpty {
                        Button(action: onClear) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Clear \(title) filter")
                    }
                }
                .padding(.vertical, 3)

                if visibleItems.isEmpty {
                    Text(query.isEmpty ? "None yet" : "No matches")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 2)
                } else {
                    ForEach(Array(visibleItems.enumerated()), id: \.element) { index, item in
                        row(for: item, index: index)
                    }
                }
            }
        } label: {
            Label(title, systemImage: systemImage)
        }
    }

    private func handleClick(on item: String, index: Int) {
        let flags = NSEvent.modifierFlags

        if flags.contains(.command) {
            var newSelection = selected
            if newSelection.contains(item) {
                newSelection.remove(item)
            } else {
                newSelection.insert(item)
            }
            onSelectionChange(newSelection)
            anchorIndex = index
        } else if flags.contains(.shift), let anchor = anchorIndex {
            let lower = min(anchor, index)
            let upper = max(anchor, index)
            onSelectionChange(Set(visibleItems[lower...upper]))
            // Anchor stays put so further Shift-clicks keep extending from
            // the original starting point, matching Finder's behavior.
        } else if selected == [item] {
            // Clicking the one thing that's already solely selected
            // deselects it, falling back to "All Tracks".
            onSelectionChange([])
            anchorIndex = index
        } else {
            onSelectionChange([item])
            anchorIndex = index
        }
    }

    @ViewBuilder
    private func row(for item: String, index: Int) -> some View {
        let isSelected = selected.contains(item)
        Button {
            handleClick(on: item, index: index)
        } label: {
            HStack {
                Text(item).lineLimit(1)
                Spacer()
                if let ratings {
                    if let avg = ratings[item] {
                        let isPartial = partiallyRatedItems?.contains(item) ?? false
                        let ratingColor: Color = isPartial ? .secondary.opacity(0.4) : .secondary
                        HStack(spacing: 2) {
                            if avg >= 9 {
                                Image(systemName: "star.fill")
                                    .font(.system(size: 8))
                                    .foregroundStyle(ratingColor)
                            }
                            Text(String(format: "%.1f", avg))
                                .font(.caption2)
                                .foregroundStyle(ratingColor)
                        }
                    } else {
                        Text("–")
                            .font(.caption2)
                            .foregroundStyle(.secondary.opacity(0.4))
                    }
                }
                if let count = counts[item] {
                    Text("\(count)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(isSelected ? Color.accentColor.opacity(0.18) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            if let onShowAllTracks {
                Button("Show All Tracks") {
                    onShowAllTracks(item)
                }
            }
        }
    }
}
