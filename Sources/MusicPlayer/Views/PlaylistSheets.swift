import SwiftUI
import MusicPlayerKit

struct NewPlaylistSheet: View {
    @EnvironmentObject private var library: LibraryModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Playlist")
                .font(.title3.weight(.semibold))
            TextField("Playlist name", text: $name)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create") {
                    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    library.createPlaylist(name: trimmed)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 320)
    }
}

struct RenamePlaylistSheet: View {
    @EnvironmentObject private var library: LibraryModel
    @Environment(\.dismiss) private var dismiss
    let playlist: Playlist
    @State private var name: String

    init(playlist: Playlist) {
        self.playlist = playlist
        _name = State(initialValue: playlist.name)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Rename Playlist")
                .font(.title3.weight(.semibold))
            TextField("Playlist name", text: $name)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    library.renamePlaylist(playlist.id, to: trimmed)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 320)
    }
}

/// Builds a smart playlist's rule set — any track field (rating, year,
/// artist, tags, …), not just tags. Each row is one condition; the
/// Match All/Any picker decides whether a track needs to satisfy every
/// row or just one.
struct SmartPlaylistSheet: View {
    @EnvironmentObject private var library: LibraryModel
    @Environment(\.dismiss) private var dismiss

    let existing: Playlist?

    @State private var name: String
    @State private var matchAll: Bool
    @State private var rules: [SmartRule]

    init(existing: Playlist?) {
        self.existing = existing
        _name = State(initialValue: existing?.name ?? "")
        _matchAll = State(initialValue: existing?.smartMatchAll ?? false)
        let initialRules = existing?.smartRules ?? []
        _rules = State(initialValue: initialRules.isEmpty ? [SmartRule(field: .rating, comparison: .greaterThanOrEqual, value: "")] : initialRules)
    }

    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !rules.isEmpty
            && rules.allSatisfy { !$0.value.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(existing == nil ? "New Smart Playlist" : "Edit Smart Playlist")
                .font(.title3.weight(.semibold))

            TextField("Playlist name", text: $name)
                .textFieldStyle(.roundedBorder)

            if rules.count > 1 {
                Picker("Match", selection: $matchAll) {
                    Text("Match Any").tag(false)
                    Text("Match All").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            VStack(alignment: .leading, spacing: 8) {
                ForEach($rules) { $rule in
                    ruleRow($rule)
                }
            }

            Button {
                rules.append(SmartRule(field: .rating, comparison: .greaterThanOrEqual, value: ""))
            } label: {
                Label("Add Rule", systemImage: "plus.circle")
            }
            .buttonStyle(.link)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(existing == nil ? "Create" : "Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isValid)
            }
        }
        .padding(24)
        .frame(width: 460)
    }

    @ViewBuilder
    private func ruleRow(_ rule: Binding<SmartRule>) -> some View {
        HStack(spacing: 8) {
            Picker("", selection: rule.field) {
                ForEach(SmartRuleField.allCases) { field in
                    Text(field.displayName).tag(field)
                }
            }
            .labelsHidden()
            .frame(width: 100)
            .onChange(of: rule.wrappedValue.field) { _, newField in
                if !newField.availableComparisons.contains(rule.wrappedValue.comparison) {
                    rule.wrappedValue.comparison = newField.availableComparisons[0]
                }
            }

            Picker("", selection: rule.comparison) {
                ForEach(rule.wrappedValue.field.availableComparisons) { comparison in
                    Text(comparison.displayName).tag(comparison)
                }
            }
            .labelsHidden()
            .frame(width: 130)

            if rule.wrappedValue.field == .tags, !library.allTags.isEmpty {
                Menu {
                    ForEach(library.allTags, id: \.self) { tag in
                        Button(tag) { rule.wrappedValue.value = tag }
                    }
                } label: {
                    Text(rule.wrappedValue.value.isEmpty ? "Choose a tag…" : rule.wrappedValue.value)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .menuStyle(.borderlessButton)
            } else {
                TextField("Value", text: rule.value)
                    .textFieldStyle(.roundedBorder)
            }

            Button {
                rules.removeAll { $0.id == rule.wrappedValue.id }
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .disabled(rules.count == 1)
        }
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValid else { return }
        if let existing {
            library.updateSmartPlaylist(existing.id, name: trimmed, rules: rules, matchAll: matchAll)
        } else {
            library.createSmartPlaylist(name: trimmed, rules: rules, matchAll: matchAll)
        }
        dismiss()
    }
}
