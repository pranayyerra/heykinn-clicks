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
    @Environment(\.dismiss) private var dismiss

    let group: StorageGroup
    @State private var editing = false
    @State private var confirmingStopTracking: String?

    private var photoCount: Int { store.photoCountByStorageGroup[group.id] ?? 0 }
    private var form: AppStore.StorageForm { store.storageForm(forStorageGroup: group.id) }
    private var backingSets: [String] { store.exportSetIDs(backingStorageGroup: group.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    copies
                    keptAs
                    whereTheyAre
                    ForEach(backingSets, id: \.self) { download($0) }
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 520, height: 520)
        .sheet(isPresented: $editing) { EditStorageGroupSheet(group: group) }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(group.label)
                .font(.title3)
                .bold()
            // Where they came from. History, and it does not change — which is
            // exactly why it must not be read as a claim about storage.
            Text(arrival)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
    }

    private var arrival: String {
        let count = "\(Formatters.count(photoCount, "photo"))"
        guard let provenance = store.provenanceSummary(forStorageGroup: group.id) else {
            return count
        }
        return "\(count) · \(provenance)"
    }

    private var copies: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionCaption("How many copies")
            HStack(alignment: .firstTextBaseline) {
                Text("\(Formatters.copies(group.desiredCopies)) on \(store.deviceNames(group.destinationTargetIDs))")
                    .foregroundStyle(group.isSatisfiable ? Color.primary : Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button("Change…") { editing = true }
                    .buttonStyle(.link)
            }
            if store.idleDeviceCount(forStorageGroup: group) > 0 {
                Text("You have more drives than this asks copies for, so \(Formatters.count(store.idleDeviceCount(forStorageGroup: group), "drive")) holds none of it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The split that the copy count cannot show.
    @ViewBuilder
    private var keptAs: some View {
        let form = self.form
        if form.insideDownload + form.copiedOut > 0 {
            VStack(alignment: .leading, spacing: 6) {
                SectionCaption("How they are kept")
                if form.onlyInsideDownload > 0 {
                    // Split so the two halves are exclusive and add up. Showing
                    // "counted inside" against "copied out" put 21,117 beside
                    // 5,658 under a total of 21,117 — a photo can be counted
                    // inside a download on one drive *and* have a file of its
                    // own elsewhere, so the two overlap and a bar drawn from
                    // them says the set is bigger than it is.
                    GeometryReader { proxy in
                        HStack(spacing: 0) {
                            Rectangle().fill(Color.orange)
                                .frame(width: proxy.size.width * fraction(form.onlyInsideDownload, form))
                            Rectangle().fill(Color.green)
                        }
                    }
                    .frame(height: 8)
                    .clipShape(Capsule())
                    Text("\(form.onlyInsideDownload.formatted()) exist only inside a Google download · \(form.copiedOut.formatted()) also have a file of their own")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Label(
                        "Deleting those .zip files loses the first group, however many drives hold the files.",
                        systemImage: "shippingbox"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                } else {
                    Label(
                        "All copied out as their own files.",
                        systemImage: "doc.on.doc"
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// Which device holds how many, and how many of those are counted inside a
    /// download rather than written out.
    ///
    /// The line above says how the set as a whole is kept; this says where.
    /// Without it the detail answered "where are the ones inside the download"
    /// — the part grid does that — and never answered where the rest were, so
    /// a set with no download behind it said nothing about its whereabouts at
    /// all. It is also the only place the per-device difference shows: the two
    /// drives here do not hold the same mix.
    @ViewBuilder
    private var whereTheyAre: some View {
        let holdings = store.holdings(forStorageGroup: group.id)
        if !holdings.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                SectionCaption("Where they are")
                ForEach(holdings) { holding in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: store.targetsByID[holding.targetID]?.kind == .hostDevice
                              ? "laptopcomputer" : "externaldrive.fill")
                            .foregroundStyle(.secondary)
                            .frame(width: 16)
                        Text(store.targetsByID[holding.targetID]?.name ?? "A device that is gone")
                        Spacer(minLength: 8)
                        Text(holding.insideDownload > 0
                             ? "\(holding.photos.formatted()) · \(holding.insideDownload.formatted()) inside the download"
                             : "\(holding.photos.formatted()) as their own files")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    .font(.callout)
                }
            }
        }
    }

    private func fraction(_ part: Int, _ form: AppStore.StorageForm) -> Double {
        let total = form.onlyInsideDownload + form.copiedOut
        guard total > 0 else { return 0 }
        return Double(part) / Double(total)
    }

    /// The download backing this set, and what can be done about it.
    @ViewBuilder
    private func download(_ setID: String) -> some View {
        let archives = store.takeoutArchives.filter { $0.exportSetID == setID }
        let export = ExportSummary(setID: setID, archives: archives, plan: store.archivePlan)
        VStack(alignment: .leading, spacing: 8) {
            SectionCaption("The download holding them")
            Text(export.title)
                .font(.callout.weight(.medium))
            let names = Dictionary(uniqueKeysWithValues: store.targets.map { ($0.id, $0.name) })
            let verdict = export.protection(driveNames: names)
            Label(verdict.text, systemImage: verdict.symbol)
                .font(.caption)
                .foregroundStyle(verdict.tint)
                .fixedSize(horizontal: false, vertical: true)
            ExportPartGrid(
                parts: export.parts,
                archives: export.archives,
                managedTargetIDs: export.plan.destinations(forSet: setID),
                copiesRequired: export.copiesRequired,
                driveNames: names
            )
            HStack(spacing: 12) {
                Menu("Check these files for damage") {
                    Button("Read a sample of each file") { store.spotCheckExportParts() }
                    Button("Read every byte — slow, and the only proof") {
                        store.verifyExportPartsByChecksum()
                    }
                }
                .fixedSize()
                if !export.extractableZips.isEmpty {
                    // Named for what it changes, not for the tool it uses.
                    // "Unzip N files onto the drive" sat beside "Read the
                    // remaining files" and read as another way of importing;
                    // it is the opposite end — the photos are already in, and
                    // this changes how they are stored.
                    Button("Copy them out of the download") {
                        store.extractTakeoutZips(export.extractableZips.map(\.id))
                    }
                }
                Spacer(minLength: 0)
            }
            .font(.caption)
            Button("Stop tracking this download…", role: .destructive) {
                confirmingStopTracking = setID
            }
            .buttonStyle(.link)
            .font(.caption)
        }
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

private struct SectionCaption: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased())
            .font(.caption2)
            .tracking(0.6)
            .foregroundStyle(.secondary)
    }
}
