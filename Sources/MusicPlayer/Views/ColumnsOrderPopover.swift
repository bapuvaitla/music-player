import SwiftUI
import MusicPlayerKit

/// Toggle which optional columns are shown, and drag any column — including
/// Title/Artist/Album — to reorder them. A `List` with `.onMove` supports
/// real drag-to-reorder on macOS; the track table renders columns via 12
/// fixed "slots" that each check `library.columnOrder` for what belongs
/// there, so this actually changes what you see (verified — `Table`'s
/// column builder rejects dynamic `ForEach`-built columns, but accepts
/// this fixed-slot/`if` approach).
struct ColumnsOrderPopover: View {
    @EnvironmentObject private var library: LibraryModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Columns")
                .font(.system(size: 13, weight: .semibold))
                .padding(12)
            Divider()

            List {
                ForEach(library.columnOrder) { column in
                    HStack(spacing: 8) {
                        if column.isAlwaysVisible {
                            Image(systemName: "checkmark.square.fill")
                                .foregroundStyle(Color.secondary.opacity(0.5))
                                .help("Always shown")
                        } else {
                            Button {
                                library.toggleColumn(column)
                            } label: {
                                Image(systemName: library.visibleColumns.contains(column) ? "checkmark.square.fill" : "square")
                                    .foregroundStyle(library.visibleColumns.contains(column) ? Color.accentColor : Color.secondary)
                            }
                            .buttonStyle(.plain)
                        }

                        Text(column.title)
                            .font(.system(size: 12))

                        Spacer()

                        Image(systemName: "line.3.horizontal")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                }
                .onMove { source, destination in
                    library.moveColumn(from: source, to: destination)
                }
            }
            .listStyle(.plain)

            Divider()
            Text("Drag ☰ to reorder")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(10)
        }
        .frame(width: 220, height: 320)
    }
}
