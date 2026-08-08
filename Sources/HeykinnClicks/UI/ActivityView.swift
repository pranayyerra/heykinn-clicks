import SwiftUI

/// Operational log: audit events and import batches, newest first.
///
/// It was a `List` of everything the app had ever done, in one column, with no
/// way to narrow it. That is fine for a week-old archive and useless for the
/// one this is built for — twenty-four thousand photos across two drives
/// generates thousands of entries, and the reason anybody opens this screen is
/// to find *one* of them: what happened to that drive, why that import stopped.
/// A log you cannot search is a log you scroll past.
struct ActivityView: View {
    @EnvironmentObject private var store: AppStore
    @State private var searchText = ""
    @State private var category: AuditCategory?

    private var filteredEvents: [AuditEvent] {
        store.auditEvents.filter { event in
            if let category, event.category != category { return false }
            if !searchText.isEmpty,
               !event.message.localizedCaseInsensitiveContains(searchText) {
                return false
            }
            return true
        }
    }

    /// Batches are not filtered by category — they have none — so picking one
    /// hides them rather than showing them under a heading they do not belong
    /// to. The search still reaches them.
    private var filteredBatches: [ImportBatch] {
        guard category == nil else { return [] }
        guard !searchText.isEmpty else { return store.importBatches }
        return store.importBatches.filter {
            $0.sourcePath.localizedCaseInsensitiveContains(searchText)
        }
    }

    private var isEmpty: Bool { filteredEvents.isEmpty && filteredBatches.isEmpty }

    var body: some View {
        Group {
            if isEmpty {
                if store.auditEvents.isEmpty && store.importBatches.isEmpty {
                    ContentUnavailableView(
                        "Nothing has happened yet",
                        systemImage: "clock",
                        description: Text("Every import, copy, check and finding is recorded "
                                          + "here as it happens, and kept. This is the archive's "
                                          + "history, not a status line.")
                    )
                } else {
                    ContentUnavailableView(
                        "No matching entries",
                        systemImage: "magnifyingglass",
                        description: Text("Nothing in the log matches that. "
                                          + "Try a different word, or All activity.")
                    )
                }
            } else {
                list
            }
        }
        .navigationTitle("Activity")
        .searchable(text: $searchText, prompt: "Search the log")
        .toolbar {
            ToolbarItem {
                Picker("Show", selection: $category) {
                    Text("All activity").tag(AuditCategory?.none)
                    ForEach(AuditCategory.allCases, id: \.self) { candidate in
                        Text(candidate.displayName).tag(AuditCategory?.some(candidate))
                    }
                }
                .pickerStyle(.menu)
            }
        }
    }

    private var list: some View {
        List {
            if !filteredBatches.isEmpty {
                Section("Import batches") {
                    ForEach(filteredBatches) { batch in
                        VStack(alignment: .leading, spacing: 2) {
                            // The head is the truncatable end: what identifies a
                            // batch is the folder it finished at, not the volume
                            // it started from, and a full-width path pushed the
                            // useful half off the row.
                            Text(batch.sourcePath)
                                .font(.headline)
                                .lineLimit(1)
                                .truncationMode(.head)
                                .help(batch.sourcePath)
                            Text(summary(of: batch))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 1)
                    }
                }
            }
            if !filteredEvents.isEmpty {
                Section(category?.displayName ?? "Audit log") {
                    // Capped at what a person will ever scroll. The whole log
                    // stays in the catalog and the search reaches all of it;
                    // what is bounded is how much of it a single draw builds.
                    ForEach(filteredEvents.prefix(500)) { event in
                        row(event)
                    }
                    if filteredEvents.count > 500 {
                        Text("…and \(Formatters.count(filteredEvents.count - 500, "older entry", "older entries"))."
                             + " Search to reach them.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func summary(of batch: ImportBatch) -> String {
        [
            "\(batch.importedCount.formatted()) imported",
            "\(Formatters.count(batch.duplicateCount, "duplicate")) skipped",
            "\(Formatters.count(batch.failedCount, "failure"))",
            Formatters.dateTime.string(from: batch.startedAt)
        ].joined(separator: " · ")
    }

    private func row(_ event: AuditEvent) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(event.category.displayName)
                .font(.caption)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.secondary.opacity(0.12), in: Capsule())
                .frame(width: 90)
            VStack(alignment: .leading, spacing: 1) {
                // Selectable: these messages are the thing somebody pastes into
                // a message asking for help, and until now they could only be
                // retyped.
                Text(event.message)
                    .font(.callout)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Text(Formatters.dateTime.string(from: event.at))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 1)
    }
}
