import SwiftUI

/// The app's home: one screen that answers "are my photos safe, where do they
/// live, and is anything waiting on me?" in pictures, and links straight to the
/// screen that resolves each answer. Everything here is drawn from catalog
/// state — nothing to configure, nothing to read twice.
struct OverviewView: View {
    @Binding var selection: SidebarSection?
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var commands: AppCommandBus

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


    /// Sources asking for more copies than they name devices to hold them.
    ///
    /// Not a shortfall the app can work off: no amount of copying satisfies a
    /// source set to three copies across two devices. Only the user can fix
    /// it, by naming another device or asking for fewer copies, so it is
    /// reported as its own thing rather than folded into the photos that are
    /// merely behind.
    private var unsatisfiableSources: [StorageGroup] {
        store.storageGroups.filter { !$0.isSatisfiable }
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
    /// Whether the evidence note is the all-clear rather than a shortfall.
    private var everythingRead: Bool {
        protectionCounts
            .filter { $0.key.checkStanding == .neverRead || $0.key.checkStanding == .stale }
            .values.reduce(0, +) == 0
    }

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
        // No "the inner ring is filling in": that ring was removed when this
        // screen was cut back, and the sentence went on pointing at it. It also
        // promised a background pass that will never come for most of these —
        // a photo counted inside an export part has no file of its own to read,
        // and proving those is the export's own full check.
        return "\(confirmedCount.formatted()) of \(localCount.formatted()) read back and matched. The rest are on your drives, unread — for photos held inside a Google export that is what \u{201C}Check for damage\u{201D} on the export proves."
    }


    private var recentAssets: [Asset] {
        countedAssets
            .sorted { ($0.captureDate ?? $0.importDate) > ($1.captureDate ?? $1.importDate) }
            .prefix(14)
            .map { $0 }
    }

    private var pendingArchiveCount: Int {
        TakeoutExportSet.partsAwaitingImport(in: store.takeoutArchives)
    }
    private var activeMigrationCount: Int { store.migrationJobs.filter { $0.state.isActive }.count }

    // MARK: - Body

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if countedAssets.isEmpty {
                    firstRun
                } else {
                    // The screen's own subtitle is "the short answer", and it
                    // had grown into five cards, four of which answered a
                    // question another screen answers better and in more
                    // detail. What is left is the answer, anything wanting a
                    // decision, and a way back into the photos.
                    //
                    // Gone: a donut permanently at 100% whose caption had to be
                    // corrected because it did not measure what it claimed; a
                    // legend restating the sentence beside it; a drives card
                    // that is Keep safe in miniature; a residency card that
                    // reads "all 21,401 photos are in Local" and will until the
                    // app has a cloud connector; and a "Nothing needs you" card
                    // shown when the line above already said so.
                    theAnswer
                    if !attentionTiles.isEmpty {
                        attentionCard
                    }
                    if !recentAssets.isEmpty {
                        recentCard
                    }
                }
            }
            .padding(20)
        }
        .navigationTitle("Overview")
    }

    // MARK: - First run

    /// What an empty archive gets instead of an empty dashboard.
    ///
    /// The cards below are all reports on a population, and with no photos in
    /// it they degrade into a grey ring reading "—", a legend with no rows, and
    /// a card headed "Where your photos live" whose only content is a sentence
    /// about a rule. Somebody opening the app for the first time met a
    /// dashboard that looked broken and had to work out for themselves that the
    /// answer was to go and do something in a different section.
    ///
    /// So an empty archive gets the two things that have to happen, in order,
    /// each with the button that does it and a tick once it is done. Ordered
    /// this way round deliberately: photos can be imported with no target
    /// registered at all — they stage on this Mac and queue — and telling
    /// someone to buy a drive before they can try the app would be false.
    private var firstRun: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Nothing in the archive yet")
                    .font(.largeTitle)
                    .bold()
                Text("This app keeps your own copies of your own photos, on drives you own, "
                     + "and checks they are still there and still undamaged. It reads from "
                     + "wherever your photos are now and never changes anything it finds.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.bottom, 4)

            firstRunStep(
                number: 1,
                title: "Point it at your photos",
                detail: "A folder, an old backup, your Photos library, or a download from "
                    + "Google. Everything comes in by copy — the originals are left where "
                    + "they are.",
                symbol: "tray.and.arrow.down",
                isDone: false,
                actionLabel: "Go to Add photos"
            ) {
                selection = .takeout
            }

            firstRunStep(
                number: 2,
                title: "Give it somewhere to keep them",
                detail: targetStepDetail,
                symbol: "externaldrive.badge.plus",
                isDone: !store.targets.isEmpty,
                actionLabel: store.targets.isEmpty ? "Add a drive" : "Manage drives"
            ) {
                selection = .targets
            }

            Divider()
                .padding(.vertical, 4)

            HStack(spacing: 6) {
                Text("New to this?")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button("Read how the app thinks") { commands.isHelpPresented = true }
                    .buttonStyle(.link)
                Spacer()
            }
        }
        .frame(maxWidth: 720, alignment: .leading)
    }

    private var targetStepDetail: String {
        guard !store.targets.isEmpty else {
            return "A device is somewhere holding a whole copy: this Mac, an external drive, "
                + "or both. Until one exists, photos wait in a staging area on this Mac — "
                + "safe, but only in one place."
        }
        let registered = store.targets.map(\.name).sorted().joined(separator: ", ")
        return "Registered: \(registered). Each group of photos says how many copies to keep, and the app works out which of these hold them."
    }

    private func firstRunStep(
        number: Int,
        title: String,
        detail: String,
        symbol: String,
        isDone: Bool,
        actionLabel: String,
        action: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                Circle()
                    .fill(isDone ? Color.green.opacity(0.18) : Color.accentColor.opacity(0.15))
                    .frame(width: 30, height: 30)
                if isDone {
                    Image(systemName: "checkmark")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.green)
                } else {
                    Text("\(number)")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(.tint)
                }
            }
            .accessibilityLabel(isDone ? "Step \(number), done" : "Step \(number)")

            VStack(alignment: .leading, spacing: 6) {
                Label(title, systemImage: symbol)
                    .font(.headline)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                // Written out rather than picking a style with a ternary:
                // ButtonStyle is not a single type, so the two branches cannot
                // be the arms of one expression.
                if isDone {
                    Button(actionLabel, action: action)
                        .buttonStyle(.bordered)
                } else {
                    Button(actionLabel, action: action)
                        .buttonStyle(.borderedProminent)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - Safety

    /// The one thing this screen exists to say.
    ///
    /// Same sentence Keep safe leads with, drawn the same way — a mark, a
    /// headline, and the two facts that qualify it. No ring: a figure pinned at
    /// 100% is decoration, and this one spent the day claiming to measure
    /// drives while measuring policy.
    /// Whether the headline is good news: enough places, and read back.
    private var archiveIsSound: Bool {
        everythingRead && (store.leastCopiesAnywhere ?? 0) >= 2
    }

    private var theAnswer: some View {
        HStack(alignment: .top, spacing: 12) {
            // Reflects the sentence beside it and nothing else. Folding the
            // attention count in turned the mark orange over a green headline
            // and a green evidence line, because a move was running — which is
            // worth surfacing, and is not a statement about whether the photos
            // are safe. That section says it for itself, directly below.
            Image(systemName: archiveIsSound ? "checkmark.seal.fill" : "exclamationmark.circle.fill")
                .font(.title)
                .foregroundStyle(archiveIsSound ? .green : .orange)
            VStack(alignment: .leading, spacing: 6) {
                Text(safetyHeadline)
                    .font(.title3)
                    .fixedSize(horizontal: false, vertical: true)
                if let evidenceNote {
                    Label(
                        evidenceNote,
                        systemImage: everythingRead ? "checkmark.circle.fill" : "circle.dotted"
                    )
                    .font(.callout)
                    .foregroundStyle(everythingRead ? Color.green : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                if store.archiveBackedOnlyCount > 0 {
                    Label(
                        "\(store.archiveBackedOnlyCount.formatted()) of them are inside your Google Takeout files rather than copied out of them.",
                        systemImage: "shippingbox"
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.bottom, 4)
    }



    private var safetyHeadline: String {
        if countedAssets.isEmpty {
            return "Nothing imported yet. Import a folder or a Google export to start the archive."
        }
        // Nowhere to put anything is its own answer, and it is not a shortfall
        // the app can work off.
        if store.targets.isEmpty {
            return "\(localCount.formatted()) photos have nowhere to go yet — no drive is registered. Add one and the copies each group asks for start being made."
        }
        // A source asking for more copies than it names devices can never be
        // satisfied by copying, so it is said plainly rather than counted in
        // with the photos that are merely behind. Named, because "some source"
        // is not something a person can act on.
        if !unsatisfiableSources.isEmpty {
            let named = unsatisfiableSources.prefix(2).map(\.label).joined(separator: " and ")
            let rest = unsatisfiableSources.count > 2
                ? " and \(unsatisfiableSources.count - 2) more"
                : ""
            return "\(named)\(rest) \(Formatters.pluralise(unsatisfiableSources.count, "asks", "ask")) for more copies than \(Formatters.pluralise(unsatisfiableSources.count, "it names devices", "they name devices")) to hold them. Name another device, or lower what \(Formatters.pluralise(unsatisfiableSources.count, "it asks", "they ask")) for, under Keep safe."
        }
        // One answer. What the app has and has not read back is reported under
        // it, not folded into it — the copies either satisfy what the source
        // asked for or they do not, and a stale check does not change that.
        if protectedCount == localCount {
            // "Safe" was doing two jobs — enough copies exist, and they are
            // known to be good — and only the first is true here. Say the one
            // the ring is actually reporting; the line under it says how far
            // the checking has got.
            // The same answer Keep safe leads with, in the same words. Both
            // screens were asked "is my archive safe" and gave different
            // replies: this one reported policy compliance, which a photo
            // alone on one drive satisfies. How many places hold it is the
            // question, and one number cannot be right on one screen only.
            if let fewest = store.leastCopiesAnywhere, fewest > 1 {
                return "Every photo is in \(Formatters.count(fewest, "place"))."
            }
            // Keep safe says this in the same words; the two screens are asked
            // the same question and must not answer it differently.
            if let fewest = store.leastCopiesAnywhere, fewest < 2 {
                let alone = store.copyCoverage[fewest] ?? 0
                return "\(Formatters.count(alone, "photo")) \(alone == 1 ? "is" : "are") \(fewest == 0 ? "in no place at all" : "in one place only")."
            }
            return "All \(localCount.formatted()) photos are on all the drives they are meant to be on."
        }
        let short = localCount - protectedCount
        // How many copies that is, not only how many photos. Under k-of-n a
        // photo can be one copy short or three, and "412 photos short" reads
        // the same either way — the copy count is what tells you whether this
        // is one drive's worth of work or an evening's.
        let copiesShort = store.placementShortfallSummary.copiesShort
        let detail = copiesShort > short
            ? " That is \(Formatters.count(copiesShort, "copy", "copies")) still to make."
            : ""
        return "\(short.formatted()) of \(localCount.formatted()) photos are not yet on all the drives they are meant to be on.\(detail)"
    }

    // MARK: - Drives



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
                // The safety page, not a Violations screen. Violations stopped
                // being a page of their own — they are a section of the page
                // that answers "is it safe", shown only when there are any —
                // and sending the tile to the old destination landed the reader
                // on a screen the sidebar could not highlight, with nothing to
                // click to get back.
                destination: .targets
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
                // Same reason as violations above: a section of the safety
                // page, not a destination.
                destination: .targets
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


    // MARK: - Residency



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
                                    .help(verdict.displayName(copies: store.desiredCopies(forAsset: asset.id)))
                                    .accessibilityLabel(verdict.displayName(copies: store.desiredCopies(forAsset: asset.id)))
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
