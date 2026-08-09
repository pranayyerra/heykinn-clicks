import SwiftUI

/// Everything true about one group of photos: where they came from, how many
/// copies they ask for, and how those copies actually exist.
///
/// Built because the two halves were on different screens and only one of them
/// was labelled. A group row said "two copies on Owner's Back and My Passport"
/// for three sets that were nothing alike — twelve real files, seventeen
/// thousand photos living inside .zip files, and a set named after the Photos
/// library that a Google download was mostly holding. Meanwhile the picture of
/// where those files were sat on the import card, because there was nowhere
/// else to put it.
///
/// Origin above, storage below, stated separately. A name taken from an import
/// is history and cannot change; how the photos are kept is a fact about now.
struct StorageGroupDetail: View {
    @EnvironmentObject private var store: AppStore

    let group: StorageGroup
    @State private var confirmingStopTracking: String?
    @State private var relocating: ExportRelocation?

    private var form: AppStore.StorageForm { store.storageForm(forStorageGroup: group.id) }
    private var backingSets: [String] { store.exportSetIDs(backingStorageGroup: group.id) }

    var body: some View {
        // No header, no Done, no fixed size: this opens inside the row it
        // belongs to. A sheet had to restate the group's name and photo count
        // to be intelligible on its own, which put both on screen twice and
        // covered the list somebody was reading them against.
        VStack(alignment: .leading, spacing: 14) {
            whereTheyAre
            ForEach(backingSets, id: \.self) { atStake($0) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .sheet(item: $relocating) { ExportRelocationSheet(plan: $0) }
    }

    /// The policy, then what is actually there, device by device.
    ///
    /// Also carries the form each device holds them in, because "272 photos"
    /// and "272 photos, 263 of them counted inside a .zip" are the same row
    /// until you say so. A split bar drew that a second time and a group row
    /// drew it a third; the numbers only need to appear where they can be read
    /// against a device name.
    @ViewBuilder
    private var whereTheyAre: some View {
        let holdings = store.holdings(forStorageGroup: group.id)
        VStack(alignment: .leading, spacing: 6) {
            SectionCaption("Where they are")
            // The policy, then the observation. They agree here and will not
            // always, and the difference is the whole reason both are shown —
            // a copy count is what was asked for, not what is.
            // No "Change…" here. Editing is one door now — the Edit button on
            // the panel that contains this — and a second link to a sheet that
            // does the same job differently is how two ways of setting the same
            // policy drift apart.
            Text("Keeping \(Formatters.copies(group.desiredCopies))")
                .font(.callout)
                .foregroundStyle(group.isSatisfiable ? Color.secondary : Color.orange)
            if store.idleDeviceCount(forStorageGroup: group) > 0 {
                Text("You have more drives than this asks copies for, so \(Formatters.count(store.idleDeviceCount(forStorageGroup: group), "drive")) holds none of it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if holdings.isEmpty {
                Text("Nowhere yet.")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
            ForEach(holdings) { holding in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: store.targetsByID[holding.targetID]?.kind == .hostDevice
                          ? "laptopcomputer" : "externaldrive.fill")
                        .foregroundStyle(.secondary)
                        .frame(width: 16)
                    Text(store.targetsByID[holding.targetID]?.name ?? "A device that is gone")
                    Spacer(minLength: 8)
                    Text(Formatters.count(holding.photos, "photo"))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .font(.callout)
                // Where on that drive, one folder per line and each one a way
                // in. Joined with a middle dot and rendered as grey text they
                // were a dead end: a path you can read, cannot click, and have
                // to retype into Finder. A path that leads somewhere should go
                // there.
                ForEach(holding.locations) { location in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        FolderLink(location: location)
                        Spacer(minLength: 8)
                        Text(location.photos.formatted())
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .monospacedDigit()
                    }
                    .padding(.leading, 24)
                }
            }
        }
    }

    /// What the download is holding hostage, and what to do about it.
    ///
    /// Headed by the consequence rather than the statistic. "172 exist only
    /// inside a Google download" is a fact somebody has to work out the meaning
    /// of; "if the download went, 172 of these would be lost" is the meaning.
    /// It is also the honest place for the alarm colour — under a copy count it
    /// read as "you only have one copy", which is not what it says and not
    /// something that is true.
    @ViewBuilder
    private func atStake(_ setID: String) -> some View {
        let archives = store.takeoutArchives.filter { $0.exportSetID == setID }
        let export = ExportSummary(setID: setID, archives: archives, plan: store.archivePlan)
        let names = Dictionary(uniqueKeysWithValues: store.targets.map { ($0.id, $0.name) })
        let verdict = export.protection(driveNames: names)
        let stranded = form.onlyInsideDownload

        VStack(alignment: .leading, spacing: 7) {
            if stranded > 0 {
                Text("If the Google download went, \(Formatters.count(stranded, "photo")) here would be lost")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                Text(form.copiedOut > 0
                     ? "They have their copies, but every one is inside the same .zip files. The other \(form.copiedOut.formatted()) have a file of their own and would survive."
                     : "They have their copies, but every one is inside the same .zip files.")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("\(export.title) — \(verdict.text.prefix(1).lowercased() + verdict.text.dropFirst())")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            // Twelve numbered chips and a colour key, for an answer already
            // given in the sentence above. Shown only when a part is missing or
            // unchecked, which is when per-part detail is the thing you came
            // for rather than furniture.
            if verdict.tint != .green {
                ExportPartGrid(
                    parts: export.parts,
                    archives: export.archives,
                    managedTargetIDs: export.plan.destinations(forSet: setID),
                    copiesRequired: export.copiesRequired,
                    driveNames: names
                )
            }
            // Which reader has been over this export.
            //
            // The exports are kept so an evolved reader can be run over them
            // again; this is the line that makes that a decision rather than a
            // guess. Silent when every part is current, because a 127 GB read
            // that would find nothing is not worth offering.
            let behind = store.exportPartsBehindReader(inSet: setID)
            if !behind.isEmpty {
                Label {
                    Text("\(Formatters.count(behind.count, "part")) of this export \(behind.count == 1 ? "was" : "were") read by an older version of the app. Reading them again picks up anything it walked past — nothing is moved or deleted.")
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "text.magnifyingglass")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                if !behind.isEmpty {
                    Button("Read them again") { store.backfillExportMetadata() }
                }
                // Offered per drive, because an export exists on several and
                // only a connected one can be moved.
                ForEach(store.targets) { target in
                    if let plan = store.exportRelocationPlan(forSet: setID, onTarget: target.id) {
                        Button("Keep in the app's folder on \(target.name)…") { relocating = plan }
                    }
                }
                if !export.extractableZips.isEmpty {
                    Button("Copy them out of the download") {
                        store.extractTakeoutZips(export.extractableZips.map(\.id))
                    }
                }
                Menu("Check for damage") {
                    Button("Read a sample of each file") { store.spotCheckExportParts() }
                    Button("Read every byte — slow, and the only proof") {
                        store.verifyExportPartsByChecksum()
                    }
                }
                .fixedSize()
                Spacer(minLength: 0)
                Button("Stop tracking…", role: .destructive) { confirmingStopTracking = setID }
                    .buttonStyle(.link)
            }
            .font(.caption)
        }
        .padding(10)
        .background(
            (stranded > 0 ? Color.orange : Color.secondary).opacity(0.08),
            in: RoundedRectangle(cornerRadius: 8)
        )
        .confirmationDialog(
            "Stop tracking this download?",
            isPresented: Binding(
                get: { confirmingStopTracking == setID },
                set: { if !$0 { confirmingStopTracking = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Stop tracking", role: .destructive) {
                for archive in archives { store.forgetTakeoutArchive(archive.id) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(strandedWarning(setID))
        }
    }

    private func strandedWarning(_ setID: String) -> String {
        let stranded = store.photosHeldOnlyBy(exportSetID: setID)
        guard stranded > 0 else {
            return "The .zip files stay where they are. Every photo in this download has a copy elsewhere, so nothing is left without one."
        }
        return "The .zip files stay where they are, but the app counts \(Formatters.count(stranded, "photo")) *inside* them rather than holding a separate copy. Stop tracking and \(stranded == 1 ? "it is" : "they are") left with no copy the app knows about anywhere."
    }
}

/// A quiet label over a block of facts.
///
/// Was letter-spaced upper case, which is the typography of a form somebody
/// has to fill in. This sits inside a row the reader opened out of curiosity;
/// sentence case in the secondary colour says the same thing without raising
/// its voice.
private struct SectionCaption: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
    }
}

/// A folder on a device: readable, and a way in when the device is here.
///
/// Dims rather than disappears when the drive is away. Where a photo lives is
/// worth knowing precisely when you cannot get at it — that is the moment
/// somebody is deciding which drive to go and find.
private struct FolderLink: View {
    let location: AppStore.Location

    var body: some View {
        if RevealInFinder.canReveal(location.path) {
            Button {
                RevealInFinder.reveal(location.path)
            } label: {
                Label(location.display, systemImage: "folder")
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .buttonStyle(.link)
            .help("Show \(location.path) in Finder")
        } else {
            Label(location.display, systemImage: "folder")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .help("\(location.path) — plug the drive in to open it")
        }
    }
}
