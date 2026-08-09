import SwiftUI

/// Everything the Sources screen needs to say about one Google download.
///
/// The standalone Takeout screen this used to belong to is gone: Sources
/// covers every place photos come from, and keeping a second screen for one
/// of them meant an export's state was written twice, in two vocabularies.
struct ExportSummary: Identifiable {
    var setID: String
    var archives: [TakeoutArchive]
    var plan: ArchiveReplicationPlan

    var id: String { setID.isEmpty ? "loose" : setID }

    var title: String {
        guard !setID.isEmpty else { return "Archives not part of a numbered download" }
        // Google names an export with the moment it was produced.
        let stamp = setID.prefix(8)
        guard stamp.count == 8, let year = Int(stamp.prefix(4)),
              let month = Int(stamp.dropFirst(4).prefix(2)), let day = Int(stamp.suffix(2)),
              let date = Calendar(identifier: .gregorian)
                  .date(from: DateComponents(year: year, month: month, day: day))
        else { return "Export \(setID)" }
        return "Export of \(Formatters.dateOnly.string(from: date))"
    }

    var parts: [ExportPart] { plan.parts.filter { $0.setID == setID } }
    /// How many copies this export asks for. Per set, so two exports on one
    /// machine can be kept differently.
    var copiesRequired: Int { plan.copiesRequired(forSet: setID) }
    var partCount: Int {
        parts.isEmpty ? Set(archives.compactMap(\.partNumber)).count : parts.count
    }
    var totalBytes: Int64 {
        parts.isEmpty
            ? archives.reduce(0) { $0 + $1.sizeBytes }
            : parts.reduce(0) { $0 + $1.sizeBytes }
    }
    var importedAssetCount: Int { archives.reduce(0) { $0 + $1.importedAssetCount } }
    var unimported: [TakeoutArchive] {
        TakeoutExportSet(setID: setID, parts: archives).unimportedPreferredParts
    }
    var extractableZips: [TakeoutArchive] {
        archives.filter {
            $0.kind == .zip
                && FileManager.default.fileExists(atPath: $0.path)
                && !FileManager.default.fileExists(atPath: TakeoutExtractor.destinationURL(forZip: $0.url).path)
        }
    }
    var missingPartNumbers: [Int] {
        TakeoutExportSet(setID: setID, parts: archives).missingPartNumbers
    }

    /// Parts short of the policy, with the targets each one still owes a copy to.
    var shortfall: [(part: ExportPart, destinations: [UUID])] {
        parts.compactMap { part in
            let redundancy = plan.redundancy(of: part)
            guard !redundancy.meetsPolicy else { return nil }
            let destinations = Array(plan.targetsNeedingACopy(of: part))
            guard !destinations.isEmpty else { return nil }
            return (part, destinations)
        }
    }

    /// Bytes to move for *this* export — not the whole plan, which would
    /// report another export's outstanding work against this one.
    var bytesOutstanding: Int64 {
        shortfall.reduce(0) { $0 + $1.part.sizeBytes * Int64($1.destinations.count) }
    }

    /// "3, 4 and 7" — read aloud the way a person would, because these are
    /// numbers the reader is about to go looking for on a drive.

    /// Plain answer to "is this safe?", and when it is not, which parts are
    /// short and where they need to go — a count alone gives nothing to act on.
    func protection(driveNames: [UUID: String]) -> (text: String, symbol: String, tint: Color) {
        guard !parts.isEmpty else {
            return ("Not recognised as part of a Google download", "questionmark.circle", .secondary)
        }
        let outstanding = shortfall
        if !outstanding.isEmpty {
            let numbers = outstanding
                .map { $0.part.partNumber }
                .sorted()
                .map(String.init)
            let targets = Set(outstanding.flatMap(\.destinations))
                .map { driveNames[$0] ?? "another drive" }
                .sorted()
            // Which files, not just how many: "2 of 12 are missing" leaves the
            // reader with nothing to look for on the drive.
            let subject = numbers.count == 1
                ? "File \(numbers[0]) of this download is"
                : "Files \(Formatters.list(numbers)) of this download are"
            return (
                "\(subject) not on \(targets.joined(separator: " and ")) yet — \(Formatters.bytes.string(fromByteCount: bytesOutstanding)) still to copy",
                "exclamationmark.triangle.fill",
                .orange
            )
        }
        let grades = parts.map { plan.redundancy(of: $0) }
        let verified = grades.filter { $0 == .redundantVerified }
        let spotChecked = grades.filter { $0 == .redundantSpotChecked }
        let soleCopies = grades.filter { $0 == .singleCopyByPolicy }
        // Held on every drive, in forms that cannot be held against each other.
        // Not pending a check — there is no check to be pending.
        let incomparable = grades.filter { $0 == .redundantIncomparable }
        // Nothing was compared and nothing ever will be — the policy asks for
        // one copy, so there is no second copy to hold this one against.
        // Saying "not yet compared" would promise a check that is not coming.
        if soleCopies.count == parts.count {
            return (
                "Safe on your one drive. This export is set to \(Formatters.copies(copiesRequired)), so there is no second copy to check this one against.",
                "checkmark.circle",
                .teal
            )
        }
        if verified.count == parts.count {
            return ("On every drive, and every copy checked in full", "checkmark.seal.fill", .green)
        }
        if verified.count + spotChecked.count == parts.count {
            return ("On every drive, and the copies match on a spot check", "checkmark.seal", .green)
        }
        if incomparable.count == parts.count {
            return (
                "On every drive — one keeps the zips and another the unpacked copies, which hold the same photos and cannot be compared to each other.",
                "checkmark.circle",
                .teal
            )
        }
        // Parts held as a single copy are not waiting on a comparison, so
        // counting them as pending would overstate the work outstanding.
        let pending = parts.count - verified.count - spotChecked.count
            - soleCopies.count - incomparable.count
        guard pending > 0 else {
            return (
                "On every drive. \(Formatters.count(soleCopies.count, "file")) \(soleCopies.count == 1 ? "exists" : "exist") as one copy, so there is nothing to check against.",
                "checkmark.circle",
                .teal
            )
        }
        return ("On every drive. \(Formatters.count(pending, "file")) \(pending == 1 ? "has" : "have") not been checked against the other copy yet.", "checkmark.circle", .teal)
    }
}

/// A single export: what it is, whether it is safe, and a menu for the rare
/// occasions the automatic handling needs overriding.
struct ExportCard: View {
    let export: ExportSummary
    @Binding var importRequest: TakeoutImportRequest?
    @EnvironmentObject private var store: AppStore

    private var driveNames: [UUID: String] {
        Dictionary(uniqueKeysWithValues: store.targets.map { ($0.id, $0.name) })
    }

    /// This export's own source, once it has one.
    ///
    /// Nil until the export has been imported: a download the app has merely
    /// found on a drive has never been asked about, and inventing settings for
    /// it would put a decision in the user's mouth. The card offers the sheet
    /// as soon as there is something for it to govern.
    var body: some View {
        // A plain block, not a `GroupBox`. This opens inside the card the
        // source row draws, so its own filled, rounded container was a third
        // box nested in a second one. Exports are separated by a rule instead,
        // which still tells two of them apart and adds no walls.
        Group {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text(export.title)
                        .font(.headline)
                    Spacer()
                    Menu {
                        if !export.unimported.isEmpty {
                            Button("Read the \(Formatters.count(export.unimported.count, "remaining file"))…") {
                                importRequest = TakeoutImportRequest(
                                    archives: export.unimported, setID: export.setID
                                )
                            }
                        }
                        // Reading the descriptions is not checking the copies,
                        // so it sits above the divider with the other things
                        // that read the download rather than judge it.
                        Button("Read what Google wrote beside the photos") {
                            store.backfillExportMetadata()
                        }
                        Button("Work out which photo each description is about") {
                            store.projectCapturedMetadata()
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .disabled(store.takeoutActivity != nil || store.isImporting)
                }

                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)

                // The redundancy verdict and the grid of which drive holds
                // which file were both here, on a card about an import. They
                // are storage, and they now live with the set of photos they
                // describe — Keep safe, where a set opens. This card grew into
                // a storage screen because the grid had nowhere else to go.

                // `storageLine` and its "Change under Keep safe" link were
                // here. Both are gone rather than repointed: a set of photos
                // now states its own copies where it is opened, and a link out
                // of an import card to explain storage was only ever a symptom
                // of storage being explained here at all.

                transferPlan

                if !export.missingPartNumbers.isEmpty {
                    Label(
                        "\(export.missingPartNumbers.count == 1 ? "File" : "Files") \(Formatters.list(export.missingPartNumbers.map(String.init))) of this download were never found, so some photos in it are missing. Check whether every .zip Google gave you was copied across.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
    }

    private func routeSummary(_ transfers: [ExportPartTransfer]) -> String {
        var phrases: [String] = []
        func name(_ id: UUID) -> String { driveNames[id] ?? "the other drive" }
        if let direct = transfers.first(where: { if case .driveToDrive = $0.route { return true } else { return false } }),
           case .driveToDrive(let from, let to) = direct.route {
            phrases.append("\(name(from)) → \(name(to))")
        }
        if let park = transfers.first(where: { if case .driveToHoldingArea = $0.route { return true } else { return false } }),
           case .driveToHoldingArea(let from, let intendedFor) = park.route {
            phrases.append("\(name(from)) → this Mac, to hand on to \(name(intendedFor))")
        }
        if let deliver = transfers.first(where: { if case .holdingAreaToDrive = $0.route { return true } else { return false } }),
           case .holdingAreaToDrive(let to) = deliver.route {
            phrases.append("this Mac → \(name(to))")
        }
        return phrases.joined(separator: ", ")
    }

    /// What is actually going to happen about a shortfall, rather than only
    /// that one exists. "4 parts need another copy" leaves the user to work
    /// out whether they should plug something in, wait, or free up space.
    @ViewBuilder
    private var transferPlan: some View {
        let plan = store.partTransferPlan
        let mine = plan.transfers.filter { $0.setID == export.setID }
        let stranded = plan.stranded.filter { $0.setID == export.setID }
        let deferred = plan.deferredForSpace.filter { $0.setID == export.setID }

        if !mine.isEmpty {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Label(
                    "\(Formatters.count(mine.count, "file")) can be copied now (\(Formatters.bytes.string(fromByteCount: mine.reduce(0) { $0 + $1.sizeBytes }))) — \(routeSummary(mine))",
                    systemImage: "arrow.left.arrow.right"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                Spacer()
                if store.isTransferringParts {
                    Button("Stop") { store.cancelExportPartTransfers() }
                } else {
                    Button("Copy now") { store.transferExportParts() }
                        .disabled(store.isImporting || store.isSyncing || store.takeoutActivity != nil)
                }
            }
        }
        if !stranded.isEmpty {
            Label(
                "\(Formatters.count(stranded.count, "file")) \(stranded.count == 1 ? "is" : "are") waiting for the drive that holds them to be plugged in.",
                systemImage: "clock"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        if !deferred.isEmpty {
            Label(
                "\(Formatters.count(deferred.count, "file")) would have to wait on this Mac while the other drive is away, and there is not enough free space. Plug both drives in together, or free up space on the Mac.",
                systemImage: "internaldrive"
            )
            .font(.caption)
            .foregroundStyle(.orange)
        }
    }

    private var subtitle: String {
        var pieces = [Formatters.count(export.partCount, "file")]
        if export.totalBytes > 0 {
            pieces.append(Formatters.bytes.string(fromByteCount: export.totalBytes))
        }
        if export.importedAssetCount > 0 {
            pieces.append("\(export.importedAssetCount.formatted()) photos and videos")
        }
        if !export.unimported.isEmpty {
            pieces.append("\(export.unimported.count) still to read")
        }
        return pieces.joined(separator: " · ")
    }
}

/// Names the pipeline phase explicitly, so extraction or import is never
/// mistaken for a scan that won't finish.
struct TakeoutActivityBanner: View {
    let activity: TakeoutActivity

    var body: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Label(activity.phase.displayName, systemImage: activity.phase.symbolName)
                        .font(.callout)
                        .bold()
                    if let stepText = activity.stepText {
                        Text(stepText)
                            .font(.caption)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.15), in: Capsule())
                    }
                }
                Text(activity.note.map { "\(activity.detail) — \($0)" } ?? activity.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let fraction = activity.fractionComplete {
                    HStack(spacing: 8) {
                        ProgressView(value: fraction)
                            .frame(maxWidth: 320)
                        Text("\(Int(fraction * 100))%")
                            .font(.caption2)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Spacer()
        }
        .padding(10)
        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct TakeoutImportRequest: Identifiable {
    let id = UUID()
    var archives: [TakeoutArchive]
    var setID: String?
}

/// Confirms the import. It asks nothing about Google: whether the content is
/// still there is not something the user can answer per asset, and not
/// something the app may record on their say-so.
struct TakeoutImportSheet: View {
    let request: TakeoutImportRequest
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Import \(Formatters.count(request.archives.count, "file"))")
                .font(.title3)
                .bold()
            Text("Photos and videos are added to the library with their dates and locations from Google's metadata. Anything already in the library is skipped.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("They are recorded as living on your own drives. The export proves this content was in Google when the export was made, which is not evidence about now — so the app claims nothing about Google until it can check for itself.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Import") {
                    store.importTakeoutArchives(request.archives.map(\.id))
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 460)
    }
}
