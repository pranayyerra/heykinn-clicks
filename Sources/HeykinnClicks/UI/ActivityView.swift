import SwiftUI

/// Operational log: audit events and import batches, newest first.
struct ActivityView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        List {
            if !store.importBatches.isEmpty {
                Section("Import batches") {
                    ForEach(store.importBatches) { batch in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(batch.sourcePath)
                                .font(.headline)
                            Text("\(batch.importedCount) imported · \(batch.duplicateCount) duplicates skipped · \(batch.failedCount) failed · \(Formatters.dateTime.string(from: batch.startedAt))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Section("Audit log") {
                ForEach(store.auditEvents) { event in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(event.category.displayName)
                            .font(.caption)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.12), in: Capsule())
                            .frame(width: 90)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(event.message)
                                .font(.callout)
                            Text(Formatters.dateTime.string(from: event.at))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
        }
        .navigationTitle("Activity")
    }
}
