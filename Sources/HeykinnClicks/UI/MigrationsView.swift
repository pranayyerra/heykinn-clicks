import SwiftUI

struct MigrationsView: View {
    @EnvironmentObject private var store: AppStore
    @State private var isCreateSheetPresented = false
    @State private var cleanupCandidate: MigrationJob?

    var body: some View {
        Group {
            if store.migrationJobs.isEmpty {
                ContentUnavailableView(
                    "Nothing is being moved",
                    systemImage: "arrow.left.arrow.right",
                    description: Text("A move is how photos change where they live — from your drives to a cloud, or back. The app never moves anything on its own: you start one here, and it walks you through each step.")
                )
            } else {
                List {
                    Section {
                        ForEach(store.migrationJobs) { job in
                            jobRow(job)
                        }
                    } header: {
                        // The old line named a state ("Clearing Source") to
                        // explain why a rule is suspended, which only means
                        // something to a reader who already knows the machine.
                        Text("While a move is under way its photos are in both places at once. That is the one time the app allows it, and it is why a move has to be finished rather than left running.")
                            .fixedSize(horizontal: false, vertical: true)
                            .textCase(nil)
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
            "Release the old copies?",
            isPresented: Binding(
                get: { cleanupCandidate != nil },
                set: { if !$0 { cleanupCandidate = nil } }
            )
        ) {
            if let job = cleanupCandidate {
                Button("Release the \(job.fromDomain.displayName) copies", role: .destructive) {
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
            return "This deletes \(Formatters.count(job.assetIDs.count, "photo")) from your drives, leaving \(job.toDomain.displayName) as the only place they exist. It is the last step and it cannot be undone from here — do it once you are satisfied the copies over there are good."
        }
        return "Only confirm this once you have deleted \(Formatters.count(job.assetIDs.count, "photo")) from \(job.fromDomain.displayName) yourself. The app cannot check that for you, and recording it while the copies are still there would leave the archive believing something untrue."
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
            stepTrail(job)
            Text("Created \(Formatters.dateTime.string(from: job.createdAt)) · Updated \(Formatters.relative(job.updatedAt))")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            actionRow(job)
        }
        .padding(.vertical, 4)
    }

    /// The four steps a move goes through, with the one it is on marked.
    ///
    /// A move is a multi-step process the user carries out by hand across two
    /// applications, and the screen used to show only a state badge — a single
    /// word, in the state machine's vocabulary, with no indication of how many
    /// steps there were or how many were left. Somebody halfway through had no
    /// way to tell that from nearly finished.
    @ViewBuilder
    private func stepTrail(_ job: MigrationJob) -> some View {
        let steps: [(MigrationState, String)] = [
            (.pending, "Not started"),
            (.copyingToTarget, "You copy them across"),
            (.verifyingTarget, "You check they arrived"),
            (.clearingSource, "Release the old copies"),
        ]
        let reached = steps.firstIndex { $0.0 == job.state }
        HStack(spacing: 6) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                let done = job.state == .completed || (reached.map { index < $0 } ?? false)
                let current = job.state == step.0
                HStack(spacing: 4) {
                    Image(systemName: done ? "checkmark.circle.fill"
                          : current ? "circle.inset.filled" : "circle")
                        .font(.caption2)
                        .foregroundStyle(done ? .green : current ? Color.accentColor : .secondary)
                    Text(step.1)
                        .font(.caption2)
                        .foregroundStyle(current ? .primary : .secondary)
                }
                if index < steps.count - 1 {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.3))
                        .frame(width: 10, height: 1)
                }
            }
            Spacer(minLength: 0)
        }
        .opacity(job.state == .failed ? 0.4 : 1)
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
                Button("I have copied them") { store.markMigrationTargetCopied(job) }
            case .verifyingTarget:
                Text("Check the copies arrived and open properly, then confirm.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("They are all there") { store.markMigrationTargetVerified(job) }
            case .clearingSource:
                Button("Release the old copies…", role: .destructive) { cleanupCandidate = job }
            case .completed, .failed:
                EmptyView()
            }
            if job.state.isActive {
                Button("Stop this move") { store.failMigration(job, reason: "Stopped by hand") }
                    .foregroundStyle(.red)
            }
        }
    }

    private func copyInstruction(_ job: MigrationJob) -> String {
        switch job.toDomain {
        case .appleCloud: return "Add these photos to Apple Photos so they reach iCloud, then confirm below."
        case .googleCloud: return "Upload these photos to Google Photos, then confirm below."
        case .local: return "Bring these photos back in from Add photos; they will copy themselves onto your drives. Then confirm below."
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
                Text("A move has to go somewhere else.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(24)
        .frame(width: 520, height: 480)
    }
}

/// Moves under way, inline on the safety page — because a photo in two places
/// at once is a fact about whether the archive is safe, and it was two clicks
/// away under a tab named after the mechanism that produced it.
struct MigrationsSummary: View {
    @EnvironmentObject private var store: AppStore
    @State private var isPresented = false

    var body: some View {
        let active = store.migrationJobs.filter { $0.state.isActive }
        VStack(alignment: .leading, spacing: 8) {
            ForEach(active) { job in
                HStack(spacing: 8) {
                    Text("\(Formatters.count(job.assetIDs.count, "photo")) from \(job.fromDomain.displayName) to \(job.toDomain.displayName)")
                        .font(.callout)
                    Spacer()
                    Text(job.state.displayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            EmptyView()
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Carry on with this…") { isPresented = true }
                .buttonStyle(.link)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .sheet(isPresented: $isPresented) {
            NavigationStack {
                MigrationsView()
                    .frame(minWidth: 620, minHeight: 460)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { isPresented = false }
                        }
                    }
            }
        }
    }
}
