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

    /// Two segments, because the user is given one answer. The six-state
    /// breakdown that used to live here made the reader learn a taxonomy in
    /// order to work out whether their photos were safe.
    private var protectionSegments: [SegmentedBar.Segment] {
        let counts = protectionCounts
        var met = 0
        var short = 0
        var diverged = 0
        for (state, count) in counts {
            switch state.verdict {
            case .meetsPolicy: met += count
            case .shortOfPolicy: short += count
            case .diverged: diverged += count
            case .notLocal: break
            }
        }
        return [
            SegmentedBar.Segment(label: "Has \(store.redundancyPolicy.description)", count: met, color: .green),
            SegmentedBar.Segment(label: "Short of \(store.redundancyPolicy.description)", count: short, color: .orange),
            SegmentedBar.Segment(label: "A copy no longer matches", count: diverged, color: .red)
        ]
    }

    private var protectedCount: Int {
        protectionCounts.filter { $0.key.verdict.isSatisfied }.values.reduce(0, +)
    }

    private var localCount: Int {
        protectionCounts.values.reduce(0, +)
    }

    /// Photos whose copies the app has actually read back and matched.
    ///
    /// The verdict counts copies that exist; this counts copies somebody has
    /// looked at. On a fresh archive the two are wildly different — every
    /// import writes copies and reads none of them back — and the gap is the
    /// single most misleading thing the old card could leave implicit behind a
    /// full green ring.
    private var confirmedCount: Int {
        protectionCounts
            .filter { $0.key.verdict.isSatisfied && $0.key.checkStanding == .fresh }
            .values.reduce(0, +)
    }

    /// The evidence behind the verdict, stated rather than buried. A check that
    /// has gone stale is not a copy that has gone missing, and reporting it as
    /// though it were is what made a healthy archive look broken — but leaving
    /// it as a grey aside under a 100% is how a reader comes away believing
    /// every photo has been verified when almost none of them have.
    private var evidenceNote: String? {
        let neverRead = protectionCounts.filter { $0.key.checkStanding == .neverRead }.values.reduce(0, +)
        let stale = protectionCounts.filter { $0.key.checkStanding == .stale }.values.reduce(0, +)
        guard neverRead + stale > 0 else {
            guard localCount > 0 else { return nil }
            return "Every copy has been read back and matched."
        }
        if neverRead > 0, stale > 0 {
            return "\(confirmedCount.formatted()) read back and matched. \(neverRead.formatted()) have never been read, and \(stale.formatted()) not for a while — the app is working through them."
        }
        if stale > 0 {
            return "\(confirmedCount.formatted()) read back and matched. \(stale.formatted()) were last read a while ago and are due another look."
        }
        return "\(confirmedCount.formatted()) of \(localCount.formatted()) read back and matched. The rest are on your drives but nobody has read them yet — that is what the inner ring is filling in."
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
    private var pendingArchiveCount: Int {
        TakeoutExportSet.partsAwaitingImport(in: store.takeoutArchives)
    }
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
                    caption: localCount == 0 ? "nothing yet" : "on enough drives",
                    confirmed: localCount == 0 ? nil : confirmedCount
                )
                VStack(alignment: .leading, spacing: 12) {
                    Text(safetyHeadline)
                        .font(.title3)
                        .fixedSize(horizontal: false, vertical: true)
                    SegmentLegend(segments: protectionSegments)
                    if let evidenceNote {
                        // The inner ring's line. Not a footnote qualifying the
                        // verdict — a second fact, and the one the reader would
                        // otherwise assume the green ring had already promised.
                        Label(evidenceNote, systemImage: "circle.dotted")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .help("Having enough copies and having read them back are different things. A copy nobody has read is still a copy — it just has not been confirmed undamaged yet.")
                    }
                    if store.targets.count < store.redundancyPolicy.desiredCopies {
                        Button {
                            selection = .targets
                        } label: {
                            Label("Set up targets", systemImage: "externaldrive.badge.plus")
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
        if store.targets.count < store.redundancyPolicy.desiredCopies {
            let missing = store.redundancyPolicy.desiredCopies - store.targets.count
            return "\(localCount.formatted()) photos have nowhere to go. Add \(missing) more target(s) to keep \(store.redundancyPolicy.description) of everything."
        }
        // One answer. What the app has and has not read back is reported under
        // it, not folded into it — the copies either satisfy the policy or they
        // do not, and a stale check does not change that.
        if protectedCount == localCount {
            // "Safe" was doing two jobs — enough copies exist, and they are
            // known to be good — and only the first is true here. Say the one
            // the ring is actually reporting; the line under it says how far
            // the checking has got.
            return "All \(localCount.formatted()) photos have \(store.redundancyPolicy.description)."
        }
        let short = localCount - protectedCount
        return "\(short.formatted()) of \(localCount.formatted()) photos do not have \(store.redundancyPolicy.description) yet."
    }

    // MARK: - Drives

    /// One line, not a second copy of Storage & Health. The cards live there;
    /// repeating them here made the same state render twice and gave neither
    /// screen a clear job.
    private var drivesCard: some View {
        CardBox(
            title: "Drives holding your archive",
            systemImage: "externaldrive",
            accessory: AnyView(
                Button("Manage") { selection = .targets }
                    .buttonStyle(.link)
            )
        ) {
            if store.targets.isEmpty {
                HStack(spacing: 12) {
                    Image(systemName: "externaldrive.badge.plus")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Nothing holds a copy yet")
                            .font(.headline)
                        Text("Imports land in staging and stay there until a target holds them.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Add a target…") { selection = .targets }
                        .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text(copiesSummary)
                        .font(.title3)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(store.targets.map(\.name).sorted().joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var copiesSummary: String {
        let reachable = store.targets.filter { store.reachablePaths[$0.id] != nil }.count
        let complete = store.targets.filter { target in
            let breakdown = store.driveBreakdowns[target.id] ?? DriveContentBreakdown()
            return breakdown.expectedPhotos > 0 && breakdown.presentPhotos == breakdown.expectedPhotos
        }.count
        let total = store.targets.count

        // Counted in drives. "2 copies" here and "one copy" in the verdict
        // above are different things — a drive, and how many copies of each
        // photo the policy asks for — and using one word for both on a single
        // screen made the two numbers look like they should agree.
        let completeness: String
        switch (complete == total, total) {
        case (true, 1): completeness = "One drive, holding everything"
        case (true, 2): completeness = "Both drives hold everything"
        case (true, _): completeness = "All \(total) drives hold everything"
        default: completeness = "\(complete) of \(total) drives hold everything"
        }
        let availability = reachable == 0
            ? "none plugged in right now"
            : (reachable == total ? "all plugged in now" : "\(reachable) plugged in now")
        return "\(completeness) — \(availability)."
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

    /// Things the protection card has not already said.
    ///
    /// It used to lead with damaged copies and photos short of the policy —
    /// both of which are the second and third rows of the legend six inches
    /// above, with more context there than a tile can carry. The reader met
    /// "25" twice on one screen and had to work out whether it was the same 25.
    /// A card called "Needs attention" earns its place by adding something.
    private var attentionTiles: [AttentionTile] {
        var tiles: [AttentionTile] = []
        if !store.violations.isEmpty {
            tiles.append(.init(
                id: "violations",
                symbol: "exclamationmark.octagon",
                value: store.violations.count.formatted(),
                title: store.violations.count == 1 ? "thing to review" : "things to review",
                tint: .red,
                destination: .violations
            ))
        }
        if pendingArchiveCount > 0 {
            tiles.append(.init(
                id: "takeout",
                symbol: "shippingbox",
                value: pendingArchiveCount.formatted(),
                // Parts, because that is the unit: "13 exports" for one export
                // whose twelve parts are all imported said the archive was
                // barely started when it was finished.
                title: pendingArchiveCount == 1
                    ? "downloaded file still to read"
                    : "downloaded files still to read",
                tint: .blue,
                destination: .takeout
            ))
        }
        if !store.duplicateGroups.isEmpty {
            tiles.append(.init(
                id: "duplicates",
                symbol: "square.on.square",
                value: store.duplicateGroups.count.formatted(),
                title: store.duplicateGroups.count == 1
                    ? "set of identical files"
                    : "sets of identical files",
                tint: .purple,
                destination: .duplicates
            ))
        }
        if activeMigrationCount > 0 {
            tiles.append(.init(
                id: "migrations",
                symbol: "arrow.left.arrow.right",
                value: activeMigrationCount.formatted(),
                title: activeMigrationCount == 1 ? "move in progress" : "moves in progress",
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

    /// Domains actually holding something. A bar drawn from one non-zero
    /// segment is a full-width block of one colour with two zeroes underneath
    /// it — chart furniture around a fact that is one sentence long.
    private var occupiedResidencySegments: [SegmentedBar.Segment] {
        residencySegments.filter { $0.count > 0 }
    }

    private var residencyCard: some View {
        CardBox(title: "Where your photos live", systemImage: "map") {
            VStack(alignment: .leading, spacing: 10) {
                if occupiedResidencySegments.count < 2 {
                    if let only = occupiedResidencySegments.first {
                        HStack(spacing: 8) {
                            Circle()
                                .fill(only.color)
                                .frame(width: 10, height: 10)
                            Text("All \(only.count.formatted()) photos are in \(only.label).")
                                .font(.title3)
                        }
                    }
                } else {
                    SegmentedBar(segments: occupiedResidencySegments, height: 14)
                    HStack(alignment: .top, spacing: 28) {
                        ForEach(occupiedResidencySegments) { segment in
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
                            if let state = store.protectionStates[asset.id],
                               case let verdict = state.verdict,
                               verdict != .notLocal, !verdict.isSatisfied {
                                Image(systemName: verdict.symbolName)
                                    .font(.caption)
                                    .foregroundStyle(verdict.tint)
                                    .help(verdict.displayName(policy: store.redundancyPolicy))
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
