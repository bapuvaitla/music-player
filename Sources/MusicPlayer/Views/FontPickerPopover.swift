import SwiftUI

/// Lets the user pick the app's font from every family installed on the
/// Mac, with a live "Aa" preview per row rendered in that font — mirrors
/// `ColumnsOrderPopover`'s look. "System Default" is pinned above the
/// alphabetical list. A family with more than one distinct weight (e.g.
/// Helvetica Neue's UltraLight/Light/Regular/Medium/…) expands to let a
/// specific weight be picked, since those aren't separate families.
///
/// `selection` is a PostScript face name (what `Font.custom` needs), or
/// "" for System Default — the caller persists it as-is.
struct FontPickerPopover: View {
    @Binding var selection: String

    @State private var query = ""

    private var visibleFamilies: [String] {
        let all = InstalledFonts.familyNames
        guard !query.isEmpty else { return all }
        return all.filter { $0.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Font")
                .font(.system(size: 13, weight: .semibold))
                .padding(12)
            Divider()

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                TextField("Search fonts", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            Divider()

            List {
                Button {
                    selection = ""
                } label: {
                    rowLabel(title: "System Default", isSelected: selection.isEmpty, preview: nil)
                }
                .buttonStyle(.plain)

                ForEach(visibleFamilies, id: \.self) { family in
                    familyRow(family)
                }
            }
            .listStyle(.plain)
        }
        .frame(width: 280, height: 360)
    }

    @ViewBuilder
    private func familyRow(_ family: String) -> some View {
        let faces = InstalledFonts.weightFaces(forFamily: family)
        let defaultFace = InstalledFonts.defaultFace(forFamily: family)

        if faces.count > 1 {
            DisclosureGroup {
                ForEach(faces) { face in
                    Button {
                        selection = face.postscriptName
                    } label: {
                        rowLabel(
                            title: face.styleName,
                            isSelected: selection == face.postscriptName,
                            preview: face.postscriptName
                        )
                    }
                    .buttonStyle(.plain)
                    .padding(.leading, 12)
                }
            } label: {
                Button {
                    if let defaultFace { selection = defaultFace.postscriptName }
                } label: {
                    rowLabel(
                        title: family,
                        isSelected: defaultFace.map { $0.postscriptName == selection } ?? false,
                        preview: defaultFace?.postscriptName
                    )
                }
                .buttonStyle(.plain)
            }
        } else {
            Button {
                if let defaultFace { selection = defaultFace.postscriptName }
            } label: {
                rowLabel(
                    title: family,
                    isSelected: defaultFace.map { $0.postscriptName == selection } ?? false,
                    preview: defaultFace?.postscriptName
                )
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private func rowLabel(title: String, isSelected: Bool, preview postscriptName: String?) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 12))
                .lineLimit(1)
            Spacer()
            if let postscriptName {
                Text("Aa")
                    .font(.custom(postscriptName, size: 13))
                    .foregroundStyle(.secondary)
            }
            if isSelected {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }
        }
        .contentShape(Rectangle())
        .padding(.vertical, 2)
    }
}
