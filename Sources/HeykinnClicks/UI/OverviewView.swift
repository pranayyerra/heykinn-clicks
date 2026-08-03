import SwiftUI

/// The app's home: one screen that answers "are my photos safe, where do they
/// live, and is anything waiting on me?" in pictures, and links straight to the
/// screen that resolves each answer. Everything here is drawn from catalog
/// state — nothing to configure, nothing to read twice.
struct OverviewView: View {
    @Binding var selection: SidebarSection?
    @EnvironmentObject private var store: AppStore

    // MARK: - Derived figures

    /// Live Photo motion halves belong to their still, not to the counts.
    private var countedAssets: [Asset] {
        store.assets.filter { !$0.isLivePhotoMotion }
    }

    private var protectionCounts: [ProtectionState: Int] {
        var counts: [ProtectionState: Int] = [:]
        for asset in countedAssets {
            guard let state = store.protectionStates[asset.id], state != .notApplicable else { continue }
            counts[state, default: 0] += 1
        }
        return counts
    }

    private var protectionSegments: [SegmentedBar.Segment] {
        let counts = protectionCounts
        return [
            (ProtectionState.fullyReplicated, "Safe on \(store.redundancyPolicy.description)"),
            (.awaitingFirstCheck, ProtectionState.awaitingFirstCheck.displayName),
            (.verificationOverdue, ProtectionState.verificationOverdue.displayName),
            (.replicatedToOneDrive, ProtectionState.replicatedToOneDrive.displayName),
            (.stagedOnly, "Only on this Mac"),
            (.driftDetected, ProtectionState.driftDetected.displayName)
        ].map { state, label in
            SegmentedBar.Segment(label: label, count: counts[state] ?? 0, color: state.tint)
        }
    }

    private var protectedCount: Int {
        protectionCounts.filter { $0.key.isHealthy }.values.reduce(0, +)
    }

    private var localCount: Int {
        protectionCounts.values.reduce(0, +)
    }

    private var residencySegments: [SegmentedBar.Segment] {
        ResidencyDomain.allCases.map { domain in
            SegmentedBar.Segment(
                label: domain.displayName,
                count: countedAssets.filter { $0.residency == domain }.count,
                color: domain.tint
            )
        }
    }

    private var recentAssets: [Asset] {
        countedAssets
            .sorted { ($0.captureDate ?? $0.importDate) > ($1.captureDate ?? $1.importDate) }
            .prefix(14)
            .map { $0 }
    }

    private var damagedCount: Int { protectionCounts[.driftDetected] ?? 0 }
    private var unprotectedCount: Int {
        (protectionCounts[.stagedOnly] ?? 0) + (protectionCounts[.replicatedToOneDrive] ?? 0)
    }
    private var pendingArchiveCount: Int { store.takeoutArchives.filter { !$0.isImported }.count }
    private var activeMigrationCount: Int { store.migrationJobs.filter { $0.state.isActive }.count }

    // MARK: - Body

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                safetyCard
                drivesCard
                if !attentionTiles.isEmpty {
                    attentionCard
                } else if !countedAssets.isEmpty {
                    allClearCard
                }
                residencyCard
                if !recentAssets.isEmpty {
                    recentCard
                }
            }
            .padding(20)
        }
        .navigationTitle("Overview")
    }

    // MARK: - Safety

    private var safetyCard: some View {
        CardBox(title: "Protection", systemImage: "checkmark.shield") {
            HStack(alignment: .top, spacing: 24) {
                ProtectionDonut(
                    segments: protectionSegments,
                    headline: donutHeadline,
                    caption: localCount == 0 ? "nothing yet" : "safe"
                )
                VStack(alignment: .leading, spacing: 12) {
                    Text(safetyHeadline)
                        .font(.title3)
                        .fixedSize(horizontal: false, vertical: true)
                    SegmentLegend(segments: protectionSegments)
                    if store.drives.count < store.redundancyPolicy.desiredCopies {
                        Button {
                            selection = .drives
                        } label: {
                            Label("Set up drives", systemImage: "externaldrive.badge.plus")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var donutHeadline: String {
        guard localCount > 0 else { return "—" }
        return "\(Int((Double(protectedCount) / Double(localCount) * 100).rounded()))%"
    }

    private var safetyHeadline: String {
        if countedAssets.isEmpty {
            return "Nothing imported yet. Import a folder or a Google export to start the archive."
        }
        if store.drives.count < store.redundancyPolicy.desiredCopies {
            let missing = store.redundancyPolicy.desiredCopies - store.drives.count
            return "\(localCount.formatted()) photos are on this Mac only. Register \(missing) more drive(s) to keep \(store.redundancyPolicy.description) of everything."
        }
        if protectedCount == localCount {
            // "Safe" here means the copies exist. Saying so without mentioning
            // the ones never read back would overstate what the app has proven.
            let unchecked = (protectionCounts[.awaitingFirstCheck] ?? 0) + (protectionCounts[.verificationOverdue] ?? 0)
            guard unchecked > 0 else {
                return "All \(localCount.formatted()) photos have \(store.redundancyPolicy.description)."
            }
            return "All \(localCount.formatted()) photos have \(store.redundancyPolicy.description) — \(unchecked.formatted()) of them not read back yet."
        }
        return "\(protectedCount.formatted()) of \(localCount.formatted()) photos have \(store.redundancyPolicy.description). The rest are waiting on a drive."
    }

    // MARK: - Drives

    private var drivesCard: some View {
        CardBox(
            title: "Drives",
            systemImage: "externaldrive",
            accessory: AnyView(
                Button("Manage") { selection = .drives }
                    .buttonStyle(.link)
            )
        ) {
            if store.drives.isEmpty {
                emptyDrivesPrompt
            } else {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 320), spacing: 12)],
                    spacing: 12
                ) {
                    ForEach(store.drives) { drive in
                        DriveCard(drive: drive, showsActions: false)
                    }
                }
            }
        }
    }

    private var emptyDrivesPrompt: some View {
        HStack(spacing: 12) {
            Image(systemName: "externaldrive.badge.plus")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text("No drives registered yet")
                    .font(.headline)
                Text("Imports land on this Mac and stay there until two drives hold them.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Register a drive…") { selection = .drives }
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Attention

    private struct AttentionTile: Identifiable {
        let id: String
        let symbol: String
        let value: String
        let title: String
        let tint: Color
        let destination: SidebarSection
    }

    private var attentionTiles: [AttentionTile] {
        var tiles: [AttentionTile] = []
        if damagedCount > 0 {
            tiles.append(.init(
                id: "damaged",
                symbol: "exclamationmark.triangle.fill",
                value: damagedCount.formatted(),
                title: "copies no longer match what was imported",
                tint: .red,
                destination: .violations
            ))
        }
        if unprotectedCount > 0 {
            tiles.append(.init(
                id: "unprotected",
                symbol: "shield.lefthalf.filled",
                value: unprotectedCount.formatted(),
                title: "photos without \(store.redundancyPolicy.description) yet",
                tint: .orange,
                destination: .drives
            ))
        }
        if !store.violations.isEmpty {
            tiles.append(.init(
                id: "violations",
                symbol: "exclamationmark.octagon",
                value: store.violations.count.formatted(),
                title: "rule violations to review",
                tint: .red,
                destination: .violations
            ))
        }
        if pendingArchiveCount > 0 {
            tiles.append(.init(
                id: "takeout",
                symbol: "shippingbox",
                value: pendingArchiveCount.formatted(),
                title: "Google exports not imported yet",
                tint: .blue,
                destination: .takeout
            ))
        }
        if !store.duplicateGroups.isEmpty {
            tiles.append(.init(
                id: "duplicates",
                symbol: "square.on.square",
                value: store.duplicateGroups.count.formatted(),
                title: "sets of identical files",
                tint: .purple,
                destination: .duplicates
            ))
        }
        if activeMigrationCount > 0 {
            tiles.append(.init(
                id: "migrations",
                symbol: "arrow.left.arrow.right",
                value: activeMigrationCount.formatted(),
                title: "migrations in flight",
                tint: .teal,
                destination: .migrations
            ))
        }
        return tiles
    }

    private var attentionCard: some View {
        CardBox(title: "Needs attention", systemImage: "bell.badge") {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 12)], spacing: 12) {
                ForEach(attentionTiles) { tile in
                    StatTile(
                        symbol: tile.symbol,
                        value: tile.value,
                        title: tile.title,
                        tint: tile.tint
                    ) {
                        selection = tile.destination
                    }
                }
            }
        }
    }

    private var allClearCard: some View {
        CardBox(title: "Nothing needs you", systemImage: "checkmark.seal") {
            Label(
                "No damaged copies, no violations, no exports waiting to be imported.",
                systemImage: "hand.thumbsup"
            )
            .foregroundStyle(.green)
        }
    }

    // MARK: - Residency

    private var residencyCard: some View {
        CardBox(title: "Where your photos live", systemImage: "map") {
            VStack(alignment: .leading, spacing: 10) {
                SegmentedBar(segments: residencySegments, height: 14)
                HStack(alignment: .top, spacing: 28) {
                    ForEach(residencySegments) { segment in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(segment.color)
                                    .frame(width: 8, height: 8)
                                Text(segment.label)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Text(segment.count.formatted())
                                .font(.title3)
                                .monospacedDigit()
                        }
                    }
                    Spacer()
                }
                Text("Every photo lives in exactly one place. Move them between places from Migrations.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Recent

    private var recentCard: some View {
        CardBox(
            title: "Most recent",
            systemImage: "clock",
            accessory: AnyView(
                Button("Open library") { selection = .library }
                    .buttonStyle(.link)
            )
        ) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(recentAssets) { asset in
                        VStack(spacing: 4) {
                            AssetThumbnailView(asset: asset)
                                .frame(width: 96, height: 96)
                            if let state = store.protectionStates[asset.id], state != .notApplicable {
                                Image(systemName: state.symbolName)
                                    .font(.caption)
                                    .foregroundStyle(state.tint)
                                    .help(state.displayName)
                            }
                        }
                        .help(asset.originalFilename)
                    }
                }
                .padding(.bottom, 2)
            }
        }
    }
}
