import SwiftUI

/// One managed drive, drawn rather than described: how much of the archive it
/// already holds, how full it is, and what it is doing right now. Shared by the
/// Overview and the Drives screen so a drive looks the same wherever it appears.
struct DriveCard: View {
    let drive: ReplicationTarget
    /// The Overview shows targets to be understood; the Drives screen shows them
    /// to be operated. Same card, actions only where they belong.
    var showsActions: Bool = true
    /// Supplied only where forgetting makes sense — the screen that manages
    /// targets, not the Overview.
    var onForget: (() -> Void)?

    @EnvironmentObject private var store: AppStore
    @State private var capacity: (total: Int64, available: Int64)?

    private var mountURL: URL? { store.reachablePaths[drive.id] }
    private var isConnected: Bool { mountURL != nil }
    private var breakdown: DriveContentBreakdown { store.driveBreakdowns[drive.id] ?? DriveContentBreakdown() }
    private var summary: BacklogSummary { store.backlogSummary(for: drive.id) }
    private var progress: SyncProgress? {
        store.syncProgress?.targetID == drive.id ? store.syncProgress : nil
    }

    private var contentSegments: [SegmentedBar.Segment] {
        [
            .init(label: "On the drive", count: breakdown.present, color: .green),
            .init(label: "Still to copy", count: breakdown.pending, color: .orange),
            .init(label: "Damaged", count: breakdown.drift, color: .red)
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            coverage
            if let capacity, isConnected {
                capacityBar(capacity)
            }
            agreementLine
            if let progress {
                syncProgress(progress)
            }
            if showsActions && isConnected && progress == nil {
                actions
            }
        }
        .padding(14)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(isConnected ? Color.green.opacity(0.35) : Color.secondary.opacity(0.18), lineWidth: 1)
        )
        .task(id: mountURL) {
            capacity = mountURL.flatMap { VolumeCapacity.read($0) }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: isConnected ? "externaldrive.fill.badge.checkmark" : "externaldrive.badge.xmark")
                .font(.title2)
                .foregroundStyle(isConnected ? Color.green : Color.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(drive.name)
                    .font(.headline)
                if isConnected {
                    if store.isQuiescing(drive.id) {
                        statusLine("Releasing…", symbol: "hourglass", tint: .orange)
                    } else if store.isBusy(drive.id) {
                        statusLine("In use — do not unplug", symbol: "exclamationmark.triangle.fill", tint: .orange)
                    } else {
                        statusLine("Connected — safe to eject", symbol: "checkmark.circle.fill", tint: .green)
                    }
                } else {
                    statusLine(
                        "Not connected — last seen \(Formatters.relative(drive.lastSeenAt))",
                        symbol: "moon.zzz.fill",
                        tint: .secondary
                    )
                }
                // Sync and snapshot are both "when was this target last
                // brought up to date" — one line, not two panels.
                Text(metaLine)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .help(mountURL.map { "Mounted at \($0.path)" } ?? "")
            }
            Spacer()
        }
    }

    /// Last sync and last catalog snapshot, together. Snapshots live on the
    /// target they describe, so this is where they belong — a separate panel
    /// listing them per target said the same thing a second time, further from
    /// the target it was about.
    private var metaLine: String {
        var parts = ["Last sync \(Formatters.relative(store.lastCompletedSync(for: drive.id)))"]
        // Snapshots are listed off the target itself, so an unreachable target
        // reports none — which is not the same as having none. Say nothing
        // rather than claim a backup is missing when we simply cannot look.
        if let newest = (store.catalogSnapshots[drive.id] ?? []).first {
            parts.append("catalog backup \(Formatters.relative(newest.createdAt))")
        } else if isConnected {
            parts.append("no catalog backup yet")
        }
        return parts.joined(separator: " · ")
    }

    private func statusLine(_ text: String, symbol: String, tint: Color) -> some View {
        Label(text, systemImage: symbol)
            .font(.caption)
            .foregroundStyle(tint)
    }

    /// The headline fact about a drive: how much of the archive is actually on
    /// it. A bar makes "nearly everything" and "barely started" distinguishable
    /// at a glance, which two numbers side by side do not.
    private var coverage: some View {
        VStack(alignment: .leading, spacing: 5) {
            SegmentedBar(segments: contentSegments, height: 10)
            HStack(spacing: 10) {
                // A full bar, "24,626 of 24,626" and a "Complete" badge were
                // three ways of saying one thing. When the target holds
                // everything, say so once.
                Text(coverageSummary)
                    .font(.callout)
                    .monospacedDigit()
                Spacer()
                if breakdown.drift > 0 {
                    Label("\(breakdown.drift) damaged", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                } else if breakdown.pending > 0 {
                    Label("\(breakdown.pending.formatted()) waiting", systemImage: "tray.full")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    /// Photos lead; files follow quietly. A Live Photo is one photo but two
    /// files, so labelling the file count "photos" overstates the library and
    /// contradicts every other total on screen.
    private var coverageSummary: String {
        guard breakdown.expectedPhotos > 0 else { return "Nothing to hold yet" }
        let size = breakdown.presentBytes > 0
            ? " · \(Formatters.bytes.string(fromByteCount: breakdown.presentBytes))"
            : ""
        let files = " · \(breakdown.present.formatted()) files"
        if breakdown.presentPhotos == breakdown.expectedPhotos {
            return "All \(breakdown.presentPhotos.formatted()) photos\(size)\(files)"
        }
        return "\(breakdown.presentPhotos.formatted()) of \(breakdown.expectedPhotos.formatted()) photos\(size)\(files)"
    }

    /// What share of the archive this device carries.
    ///
    /// This line used to report whether the device held the same content as
    /// every other one, which under k-of-n is neither true nor a problem:
    /// devices are *supposed* to hold different subsets, so "differs from
    /// Field Drive on 12,000 files" was about to become a permanent orange
    /// warning describing a healthy archive.
    ///
    /// The honest replacement is what this device contributes, and whether the
    /// archive as a whole is short — which is a fact about photos, not about
    /// how two drives compare.
    @ViewBuilder
    private var agreementLine: some View {
        let breakdown = store.driveBreakdowns[drive.id]
        let held = breakdown?.presentPhotos ?? 0
        if held > 0 {
            Label(
                "Carries \(Formatters.count(held, "photo")) of the archive's \(store.localPhotoCount.formatted())",
                systemImage: "chart.pie"
            )
            .font(.caption2)
            .foregroundStyle(.secondary)
            .help("Your devices are meant to hold different photos. What matters is that every photo is on enough of them, which the Overview reports.")
        }
    }

    private func capacityBar(_ capacity: (total: Int64, available: Int64)) -> some View {
        let used = max(capacity.total - capacity.available, 0)
        return VStack(alignment: .leading, spacing: 4) {
            SegmentedBar(
                segments: [
                    .init(label: "Used", count: Int(used / 1_000_000), color: .blue.opacity(0.6)),
                    .init(label: "Free", count: Int(capacity.available / 1_000_000), color: .secondary.opacity(0.25))
                ],
                height: 6
            )
            Text("\(Formatters.bytes.string(fromByteCount: capacity.available)) free of \(Formatters.bytes.string(fromByteCount: capacity.total))")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func syncProgress(_ progress: SyncProgress) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ProgressView(value: progress.fractionComplete)
            HStack {
                Text(progress.currentItem.map { "Syncing \($0)" } ?? "Syncing…")
                    .lineLimit(1)
                Spacer()
                Text("\(progress.completedTasks + progress.failedTasks) of \(progress.totalTasks)\(progress.failedTasks > 0 ? " (\(progress.failedTasks) failed)" : "")")
                    .monospacedDigit()
                Button("Stop") { store.cancelSync() }
                    .controlSize(.small)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var actions: some View {
        HStack {
            // One verb. There were four here, three of which were the app's own
            // bookkeeping wearing a menu: "Check the archive is fully placed"
            // asked the app to confirm its own consistency, "Clear N queued
            // checks" was queue surgery, and "Tidy up empty folders" apologised
            // for a bug older versions caused. None is a decision a person has
            // information to make, so the app makes them — the placement audit
            // already runs on every connect and every settings change, and
            // removal prunes as it goes.
            //
            // "Check a batch now" was the fourth and it was this button, listed
            // again inside itself.
            Button {
                store.queueVerificationSweep(drive.id)
            } label: {
                Label("Check for damage", systemImage: "checkmark.shield")
            }
            .disabled(store.isSyncing)
            .help("Re-reads a batch of files on this drive and confirms they are still byte-for-byte what was imported, starting with the ones checked longest ago. Reading is the only thing that finds silent corruption — bit rot, a bad cable, an accidental edit — and it finds it while the other drive still holds a good copy to restore from.")

            // "Look for copies this drive already has" was here too. It is the
            // right thing to do and the wrong place to offer it: a drive with
            // photos on it is already met with that offer when it is plugged
            // in, which is the moment it means something. A second door to it,
            // months later, is a question with no reason to answer no.
            if let onForget {
                Menu {
                    Button("Forget this drive…", role: .destructive, action: onForget)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }

            Spacer()

            Button(syncButtonTitle) { store.syncDrive(drive.id) }
                .buttonStyle(.borderedProminent)
                .disabled(store.isSyncing || summary.isEmpty)
                .help(summary.isEmpty
                      ? "Nothing pending for this drive."
                      : "Works through this drive's queue: \(summary.description).")
        }
    }

    /// Says what the run will actually do — "Sync now" reads like copying,
    /// which is misleading when the queue is entirely verification.
    private var syncButtonTitle: String {
        if summary.isEmpty { return "Nothing to do" }
        if summary.copyCount == 0 && summary.removeCount == 0 { return "Check \(summary.verifyCount) files" }
        if summary.verifyCount == 0 && summary.removeCount == 0 { return "Copy \(summary.copyCount) now" }
        return "Process \(summary.total) now"
    }
}
