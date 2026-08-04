import SwiftUI

struct MigrationsView: View {
    @EnvironmentObject private var store: AppStore
    @State private var isCreateSheetPresented = false
    @State private var cleanupCandidate: MigrationJob?

    var body: some View {
        Group {
            if store.migrationJobs.isEmpty {
                ContentUnavailableView(
                    "No migrations",
                    systemImage: "arrow.left.arrow.right",
                    description: Text("Migrations are the only sanctioned way to move assets between residency domains.")
                )
            } else {
                List {
                    Section {
                        ForEach(store.migrationJobs) { job in
                            jobRow(job)
                        }
                    } header: {
                        Text("A migration may hold an asset in two domains temporarily; the overlap must end in Clearing Source before the job can complete.")
                    }
                }
            }
        }
        .navigationTitle("Migrations")
        .toolbar {
            ToolbarItem {
                Button {
                    isCreateSheetPresented = true
                } label: {
                    Label("New migration", systemImage: "plus")
                }
            }
        }
        .sheet(isPresented: $isCreateSheetPresented) {
            MigrationCreator()
        }
        .confirmationDialog(
            "Clear source retention?",
            isPresented: Binding(
                get: { cleanupCandidate != nil },
                set: { if !$0 { cleanupCandidate = nil } }
            )
        ) {
            if let job = cleanupCandidate {
                Button("Clear \(job.fromDomain.displayName) copies", role: .destructive) {
                    store.completeMigrationCleanup(job)
                    cleanupCandidate = nil
                }
            }
            Button("Cancel", role: .cancel) { cleanupCandidate = nil }
        } message: {
            if let job = cleanupCandidate {
                Text(cleanupMessage(job))
            }
        }
    }

    private func cleanupMessage(_ job: MigrationJob) -> String {
        if job.fromDomain == .local {
            return "This removes the source copies from the managed targets (queued as explicit remove tasks) and marks local presence cleared for \(job.assetIDs.count) asset(s). This is the destructive final step of the migration."
        }
        return "Confirm that you have removed these \(job.assetIDs.count) asset(s) from \(job.fromDomain.displayName). The catalog will record the source as cleared."
    }

    private func jobRow(_ job: MigrationJob) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                ResidencyBadge(domain: job.fromDomain)
                Image(systemName: "arrow.right")
                    .foregroundStyle(.secondary)
                ResidencyBadge(domain: job.toDomain)
                Text(Formatters.count(job.assetIDs.count, "photo"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                stateBadge(job.state)
            }
            if let note = job.note {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("Created \(Formatters.dateTime.string(from: job.createdAt)) · Updated \(Formatters.relative(job.updatedAt))")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            actionRow(job)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func actionRow(_ job: MigrationJob) -> some View {
        HStack {
            switch job.state {
            case .pending:
                Button("Start") { store.startMigration(job) }
                    .buttonStyle(.borderedProminent)
            case .copyingToTarget:
                Text(copyInstruction(job))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Mark target copy complete") { store.markMigrationTargetCopied(job) }
            case .verifyingTarget:
                Text("Confirm the target copies are intact and complete.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Mark verified") { store.markMigrationTargetVerified(job) }
            case .clearingSource:
                Button("Clear source retention…", role: .destructive) { cleanupCandidate = job }
            case .completed, .failed:
                EmptyView()
            }
            if job.state.isActive {
                Button("Mark failed") { store.failMigration(job, reason: "Manually aborted") }
                    .foregroundStyle(.red)
            }
        }
    }

    private func copyInstruction(_ job: MigrationJob) -> String {
        switch job.toDomain {
        case .appleCloud: return "Upload the assets to Apple Photos/iCloud, then confirm."
        case .googleCloud: return "Upload the assets to Google Photos/Drive, then confirm."
        case .local: return "Import the assets into staging (they will replicate to the targets), then confirm."
        }
    }

    private func stateBadge(_ state: MigrationState) -> some View {
        let color: Color
        switch state {
        case .pending: color = .secondary
        case .copyingToTarget, .verifyingTarget, .clearingSource: color = .orange
        case .completed: color = .green
        case .failed: color = .red
        }
        return Text(state.displayName)
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }
}

/// Creates a migration job from assets currently in a chosen source domain.
struct MigrationCreator: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss

    @State private var source: ResidencyDomain = .local
    @State private var target: ResidencyDomain = .appleCloud
    @State private var selectedAssetIDs: Set<UUID> = []
    @State private var note = ""

    private var candidates: [Asset] {
        store.assets.filter { $0.residency == source }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New migration")
                .font(.title3)
                .bold()
            HStack {
                Picker("From", selection: $source) {
                    ForEach(ResidencyDomain.allCases) { domain in
                        Text(domain.displayName).tag(domain)
                    }
                }
                Picker("To", selection: $target) {
                    ForEach(ResidencyDomain.allCases) { domain in
                        Text(domain.displayName).tag(domain)
                    }
                }
            }
            .onChange(of: source) { _, _ in selectedAssetIDs.removeAll() }

            List(candidates, selection: $selectedAssetIDs) { asset in
                HStack {
                    Text(asset.originalFilename)
                    Spacer()
                    Text(Formatters.bytes.string(fromByteCount: asset.fileSize))
                        .foregroundStyle(.secondary)
                }
                .tag(asset.id)
            }
            .frame(minHeight: 220)

            TextField("Note (optional)", text: $note)
                .textFieldStyle(.roundedBorder)

            HStack {
                Text("\(selectedAssetIDs.count) selected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Create") {
                    store.createMigration(
                        assetIDs: Array(selectedAssetIDs),
                        from: source,
                        to: target,
                        note: note.isEmpty ? nil : note
                    )
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedAssetIDs.isEmpty || source == target)
            }
            if source == target {
                Text("Source and target must differ.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(24)
        .frame(width: 520, height: 480)
    }
}
