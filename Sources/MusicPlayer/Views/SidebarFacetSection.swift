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
    /// Only used for the Albums section — albums manually flagged as
    /// incomplete (not every track owned/heard yet) render "Inc" instead
    /// of a numeric rating.
    var incompleteRatingItems: Set<String>? = nil
    var onToggleIncompleteRating: ((String) -> Void)? = nil

    // A dynamic key (keyed on `title`, since each facet section needs its
    // own remembered expand state) means this can't use the plain
    // `@State` default + synthesized memberwise init anymore — see the
    // custom `init` below, which is otherwise just forwarding.
    @AppStorage private var isExpanded: Bool
    @State private var query = ""
    @State private var anchorIndex: Int?
    /// Drives the scrollable item list's edge fade — true only when
    /// there's actually more content in that direction, not just whenever
    /// the box happens to be tall enough to scroll at all.
    @State private var canScrollUp = false
    @State private var canScrollDown = false
    /// Only meaningful (and only shown) when `ratings` is provided — lets
    /// the Albums section be sorted by score instead of alphabetically.
    /// Shared across sections since only one section (Albums) ever passes
    /// ratings in practice. Cycles random → highest first → lowest first.
    @AppStorage("sidebarFacetSortMode") private var sortModeRaw = FacetSortMode.random.rawValue

    private enum FacetSortMode: String {
        case random, ratingDescending, ratingAscending

        var next: FacetSortMode {
            switch self {
            case .random: return .ratingDescending
            case .ratingDescending: return .ratingAscending
            case .ratingAscending: return .random
            }
        }
    }

    private var sortMode: FacetSortMode { FacetSortMode(rawValue: sortModeRaw) ?? .random }
    /// Same `@AppStorage` keys ContentView reads/writes. Item rows need
    /// this applied explicitly — they sat inside `List`/`DisclosureGroup`
    /// content that wasn't picking up the app-wide `.environment(\.font,
    /// ...)` set at the NavigationSplitView level, so a custom typeface
    /// like Helvetica Neue Light silently fell back to the system font
    /// here even though it applied everywhere else.
    @AppStorage("appFontPostscriptName") private var appFontPostscriptName: String = ""
    @AppStorage("appFontSize") private var appFontSize: Double = 13

    private var bodyFont: Font {
        appFontPostscriptName.isEmpty ? .system(size: appFontSize) : .custom(appFontPostscriptName, size: appFontSize)
    }

    // Otherwise identical to the synthesized memberwise init this replaced
    // — only here because `isExpanded`'s AppStorage key has to be built
    // from `title` at construction time.
    init(
        title: String,
        items: [String],
        counts: [String: Int],
        ratings: [String: Double]? = nil,
        partiallyRatedItems: Set<String>? = nil,
        selected: Set<String>,
        onSelectionChange: @escaping (Set<String>) -> Void,
        onClear: @escaping () -> Void,
        onShowAllTracks: ((String) -> Void)? = nil,
        incompleteRatingItems: Set<String>? = nil,
        onToggleIncompleteRating: ((String) -> Void)? = nil
    ) {
        self.title = title
        self.items = items
        self.counts = counts
        self.ratings = ratings
        self.partiallyRatedItems = partiallyRatedItems
        self.selected = selected
        self.onSelectionChange = onSelectionChange
        self.onClear = onClear
        self.onShowAllTracks = onShowAllTracks
        self.incompleteRatingItems = incompleteRatingItems
        self.onToggleIncompleteRating = onToggleIncompleteRating
        self._isExpanded = AppStorage(wrappedValue: false, "sidebarExpanded_\(title)")
    }

    /// A random key assigned once per album, the first time it's seen —
    /// stable for the rest of the app session (not re-shuffled on every
    /// re-render), so the "randomize on launch, only sort by rating once
    /// you ask for it" ordering doesn't visibly jump around on unrelated
    /// state changes. Only meaningful when `ratings != nil` (Albums).
    @State private var randomSortKeys: [String: Double] = [:]

    private var visibleItems: [String] {
        let sorted: [String]
        if let ratings, sortMode != .random {
            let descending = sortMode == .ratingDescending
            sorted = items.sorted { lhs, rhs in
                // An incomplete rating isn't a real score to rank against —
                // sink it to the bottom of "highest first" rather than let
                // it compete on its (partial, potentially misleadingly
                // high) average.
                if descending {
                    let lhsIncomplete = incompleteRatingItems?.contains(lhs) ?? false
                    let rhsIncomplete = incompleteRatingItems?.contains(rhs) ?? false
                    if lhsIncomplete != rhsIncomplete { return !lhsIncomplete }
                }
                let left = ratings[lhs] ?? -1
                let right = ratings[rhs] ?? -1
                if left != right { return descending ? left > right : left < right }
                return lhs.localizedStandardCompare(rhs) == .orderedAscending
            }
        } else if ratings != nil {
            sorted = items.sorted { (randomSortKeys[$0] ?? 0) < (randomSortKeys[$1] ?? 0) }
        } else {
            sorted = items.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        }
        guard !query.isEmpty else { return sorted }
        return sorted.filter { $0.localizedCaseInsensitiveContains(query) }
    }

    private var sortIconName: String {
        switch sortMode {
        case .random: return "arrow.up.arrow.down"
        case .ratingDescending: return "arrow.down"
        case .ratingAscending: return "arrow.up"
        }
    }

    private var sortHelpText: String {
        switch sortMode {
        case .random: return "Random order — click to sort by rating, highest first"
        case .ratingDescending: return "Sorted by rating, highest first — click to reverse"
        case .ratingAscending: return "Sorted by rating, lowest first — click for random order"
        }
    }

    private func assignRandomKeysIfNeeded() {
        for item in items where randomSortKeys[item] == nil {
            randomSortKeys[item] = Double.random(in: 0...1)
        }
    }

    private func reshuffleRandomKeys() {
        for item in items {
            randomSortKeys[item] = Double.random(in: 0...1)
        }
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
                            let next = sortMode.next
                            sortModeRaw = next.rawValue
                            // A fresh shuffle each time random is
                            // (re)selected, not the same stable-for-the-
                            // session order every time you cycle back to it.
                            if next == .random {
                                reshuffleRandomKeys()
                            }
                        } label: {
                            Image(systemName: sortIconName)
                                .font(.system(size: 10))
                                .foregroundStyle(sortMode == .random ? Color.secondary : Color.appAccent)
                        }
                        .buttonStyle(.plain)
                        .help(sortHelpText)
                    }
                    if !selected.isEmpty {
                        Button(action: onClear) {
                            Image(systemName: "xmark.circle")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Clear \(title) filter")
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 6)

                if visibleItems.isEmpty {
                    Text(query.isEmpty ? "None yet" : "No matches")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 2)
                } else {
                    // Capped height, scrolling internally — once there are
                    // enough artists/albums/genres this would otherwise
                    // push everything below it far down the sidebar,
                    // forcing a scroll through the whole list just to reach
                    // Playlists. Signaled with a soft edge fade rather than
                    // a boxed background — a flat color block read as
                    // heavy-handed, and unlike a static box, the fade only
                    // appears on whichever edge actually has more content
                    // to scroll into, so it doubles as a live indicator
                    // rather than a decoration that's sometimes wrong (a
                    // short list that already fits needs no fade at all).
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(visibleItems.enumerated()), id: \.element) { index, item in
                                row(for: item, index: index)
                            }
                        }
                        .padding(.horizontal, 6)
                        .padding(.bottom, 6)
                    }
                    .frame(maxHeight: 220)
                    .onScrollGeometryChange(for: Bool.self) { geometry in
                        geometry.contentOffset.y > 1
                    } action: { _, newValue in
                        canScrollUp = newValue
                    }
                    .onScrollGeometryChange(for: Bool.self) { geometry in
                        geometry.contentOffset.y < geometry.contentSize.height - geometry.containerSize.height - 1
                    } action: { _, newValue in
                        canScrollDown = newValue
                    }
                    .mask(alignment: .top) {
                        VStack(spacing: 0) {
                            LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                                .frame(height: canScrollUp ? 14 : 0)
                            Rectangle()
                            LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                                .frame(height: canScrollDown ? 14 : 0)
                        }
                        .animation(.easeInOut(duration: 0.15), value: canScrollUp)
                        .animation(.easeInOut(duration: 0.15), value: canScrollDown)
                    }
                }
            }
            // Otherwise the box's bottom edge sits right against the next
            // heading below it with no breathing room at all.
            .padding(.bottom, 8)
        } label: {
            SidebarHeadingText(title)
        }
        .disclosureGroupStyle(RightChevronDisclosureGroupStyle())
        .onAppear { assignRandomKeysIfNeeded() }
        .onChange(of: items) { _, _ in assignRandomKeysIfNeeded() }
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
                Text(item)
                    .font(bodyFont)
                    .lineLimit(1)
                    .foregroundStyle(.primary)
                Spacer()
                if let ratings {
                    if incompleteRatingItems?.contains(item) == true {
                        Text("Inc")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    } else if let avg = ratings[item] {
                        let isPartial = partiallyRatedItems?.contains(item) ?? false
                        let ratingColor: Color = isPartial ? .secondary.opacity(0.4) : .secondary
                        HStack(spacing: 2) {
                            if avg >= 10 {
                                Image(systemName: "star.fill")
                                    .font(.system(size: 8))
                                    .foregroundStyle(ratingColor)
                            } else if avg >= 9 {
                                Image(systemName: "star")
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
            .padding(.vertical, 4)
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
            if let onToggleIncompleteRating {
                Toggle("Incomplete Rating", isOn: Binding(
                    get: { incompleteRatingItems?.contains(item) ?? false },
                    set: { _ in onToggleIncompleteRating(item) }
                ))
            }
        }
    }
}

/// Shared heading style for every collapsible sidebar section (Artists,
/// Albums, Genres, Playlists) — a touch larger than a regular row, and
/// built from the app's own chosen font (not a hardcoded `.system` font)
/// so a custom typeface like Helvetica Neue Light still applies here
/// rather than silently reverting to the system font.
struct SidebarHeadingText: View {
    let title: String
    @AppStorage("appFontPostscriptName") private var appFontPostscriptName: String = ""
    @AppStorage("appFontSize") private var appFontSize: Double = 13

    init(_ title: String) {
        self.title = title
    }

    private var headingFont: Font {
        let size = appFontSize + 1.5
        return appFontPostscriptName.isEmpty ? .system(size: size) : .custom(appFontPostscriptName, size: size)
    }

    var body: some View {
        Text(title).font(headingFont).fontWeight(.semibold)
    }
}

/// Puts the disclosure triangle on the trailing edge instead of the
/// standard macOS leading placement — the user wanted it beside the
/// section title rather than out ahead of it.
struct RightChevronDisclosureGroupStyle: DisclosureGroupStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                configuration.label
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(configuration.isExpanded ? 90 : 0))
                Spacer()
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.15)) {
                    configuration.isExpanded.toggle()
                }
            }

            if configuration.isExpanded {
                configuration.content
            }
        }
    }
}
