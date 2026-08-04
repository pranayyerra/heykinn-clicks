import SwiftUI

/// One row per export, not per file.
///
/// Scanning, extracting, importing, pairing and redundancy all happen on their
/// own now, so the screen's job is to answer one question — is this export
/// safe? — and keep the manual escapes out of the way.
struct TakeoutView: View {
    @EnvironmentObject private var store: AppStore
    @State private var isFolderPickerPresented = false
    @State private var importRequest: TakeoutImportRequest?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let activity = store.takeoutActivity {
                    TakeoutActivityBanner(activity: activity)
                }

                if exports.isEmpty {
                    ContentUnavailableView(
                        "No Google exports found",
                        systemImage: "shippingbox",
                        description: Text("Connect a drive holding a Takeout download, or look in a folder. Exports are found, unpacked and imported without further prompting.")
                    )
                    .padding(.top, 40)
                } else {
                    ForEach(exports) { export in
                        ExportCard(export: export, importRequest: $importRequest)
                    }
                }
            }
            .padding()
        }
        .navigationTitle("Google Takeout")
        .toolbar {
            ToolbarItem {
                Menu {
                    ForEach(store.targets.filter { store.reachablePaths[$0.id] != nil }) { drive in
                        Button("Look on \(drive.name)") {
                            if let mount = store.reachablePaths[drive.id] {
                                store.scanForTakeout(rootURL: mount, targetID: drive.id)
                            }
                        }
                    }
                    Button("Look in a folder…") { isFolderPickerPresented = true }
                } label: {
                    Label("Look for exports", systemImage: "magnifyingglass")
                }
                .disabled(store.takeoutActivity != nil)
            }
        }
        .fileImporter(
            isPresented: $isFolderPickerPresented,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                store.scanForTakeout(rootURL: url, targetID: nil)
            }
        }
        .sheet(item: $importRequest) { TakeoutImportSheet(request: $0) }
    }

    /// Archives grouped into the exports they belong to, newest first.
    private var exports: [ExportSummary] {
        let grouped = Dictionary(grouping: store.takeoutArchives) { $0.exportSetID ?? "" }
        return grouped
            .map { ExportSummary(setID: $0.key, archives: $0.value, plan: store.archivePlan) }
            .sorted { $0.setID > $1.setID }
    }
}

/// Everything the screen needs to say about one export, derived once.
struct ExportSummary: Identifiable {
    var setID: String
    var archives: [TakeoutArchive]
    var plan: ArchiveReplicationPlan

    var id: String { setID.isEmpty ? "loose" : setID }

    var title: String {
        guard !setID.isEmpty else { return "Individual archives" }
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
            let redundancy = part.redundancy(acrossTargets: plan.managedTargetIDs, policy: plan.policy)
            guard !redundancy.meetsPolicy else { return nil }
            let destinations = Array(part.targetsNeedingACopy(managedTargetIDs: plan.managedTargetIDs))
            guard !destinations.isEmpty else { return nil }
            return (part, destinations)
        }
    }

    /// Bytes to move for *this* export — not the whole plan, which would
    /// report another export's outstanding work against this one.
    var bytesOutstanding: Int64 {
        shortfall.reduce(0) { $0 + $1.part.sizeBytes * Int64($1.destinations.count) }
    }

    /// Plain answer to "is this safe?", and when it is not, which parts are
    /// short and where they need to go — a count alone gives nothing to act on.
    func protection(driveNames: [UUID: String]) -> (text: String, symbol: String, tint: Color) {
        guard !parts.isEmpty else {
            return ("Not part of a tracked export", "questionmark.circle", .secondary)
        }
        let outstanding = shortfall
        if !outstanding.isEmpty {
            let numbers = outstanding.map { String($0.part.partNumber) }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            let targets = Set(outstanding.flatMap(\.destinations))
                .map { driveNames[$0] ?? "another drive" }
                .sorted()
            return (
                "Part\(numbers.count == 1 ? "" : "s") \(numbers.joined(separator: ", ")) not yet on \(targets.joined(separator: " and ")) — \(Formatters.bytes.string(fromByteCount: bytesOutstanding)) to copy",
                "exclamationmark.triangle.fill",
                .orange
            )
        }
        let grades = parts.map {
            $0.redundancy(acrossTargets: plan.managedTargetIDs, policy: plan.policy)
        }
        let verified = grades.filter { $0 == .redundantVerified }
        let spotChecked = grades.filter { $0 == .redundantSpotChecked }
        let soleCopies = grades.filter { $0 == .singleCopyByPolicy }
        // Nothing was compared and nothing ever will be — the policy asks for
        // one copy, so there is no second copy to hold this one against.
        // Saying "not yet compared" would promise a check that is not coming.
        if soleCopies.count == parts.count {
            return (
                "On the one managed drive — \(plan.policy.description) is what the policy asks for, and there is no second copy to compare against",
                "checkmark.circle",
                .teal
            )
        }
        if verified.count == parts.count {
            return ("On every drive, copies verified byte for byte", "checkmark.seal.fill", .green)
        }
        if verified.count + spotChecked.count == parts.count {
            return ("On every drive, copies match on a quick check", "checkmark.seal", .green)
        }
        // Parts held as a single copy are not waiting on a comparison, so
        // counting them as pending would overstate the work outstanding.
        let pending = parts.count - verified.count - spotChecked.count - soleCopies.count
        guard pending > 0 else {
            return (
                "On every drive — \(soleCopies.count) part(s) exist as a single copy, with nothing to compare",
                "checkmark.circle",
                .teal
            )
        }
        return ("On every drive — \(pending) part(s) not yet compared", "checkmark.circle", .teal)
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

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text(export.title)
                        .font(.headline)
                    Spacer()
                    Menu {
                        if !export.unimported.isEmpty {
                            Button("Import \(export.unimported.count) remaining part(s)…") {
                                importRequest = TakeoutImportRequest(
                                    archives: export.unimported, setID: export.setID
                                )
                            }
                        }
                        if !export.extractableZips.isEmpty {
                            Button("Unpack \(export.extractableZips.count) zip(s) onto the drive") {
                                store.extractTakeoutZips(export.extractableZips.map(\.id))
                            }
                        }
                        Button("Quick compare copies") {
                            store.spotCheckExportParts()
                        }
                        Button("Compare copies byte for byte…") {
                            store.verifyExportPartsByChecksum()
                        }
                        Divider()
                        Button("Forget this export", role: .destructive) {
                            for archive in export.archives { store.forgetTakeoutArchive(archive.id) }
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

                let protection = export.protection(driveNames: driveNames)
                Label(protection.text, systemImage: protection.symbol)
                    .font(.callout)
                    .foregroundStyle(protection.tint)

                transferPlan

                if !export.missingPartNumbers.isEmpty {
                    Label(
                        "Parts \(export.missingPartNumbers.map(String.init).joined(separator: ", ")) were never found — this export looks incomplete.",
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
                    "\(mine.count) part(s) can move now (\(Formatters.bytes.string(fromByteCount: mine.reduce(0) { $0 + $1.sizeBytes }))) — \(routeSummary(mine))",
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
                "\(stranded.count) part(s) are waiting for the drive that holds them to be connected.",
                systemImage: "clock"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        if !deferred.isEmpty {
            Label(
                "\(deferred.count) part(s) need to wait on the Mac while the other drive is away, and there is not enough free space for them. Connect both targets at once, or free up space.",
                systemImage: "internaldrive"
            )
            .font(.caption)
            .foregroundStyle(.orange)
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

    private var subtitle: String {
        var pieces = ["\(export.partCount) part(s)"]
        if export.totalBytes > 0 {
            pieces.append(Formatters.bytes.string(fromByteCount: export.totalBytes))
        }
        if export.importedAssetCount > 0 {
            pieces.append("\(export.importedAssetCount) photos and videos")
        }
        if !export.unimported.isEmpty {
            pieces.append("\(export.unimported.count) part(s) still to import")
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
            Text("Import \(request.archives.count) part(s)")
                .font(.title3)
                .bold()
            Text("Photos and videos are added to the library with their dates and locations from Google's metadata. Anything already in the library is skipped.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("They are recorded as living on your own targets. The export proves this content was in Google when the export was made, which is not evidence about now — so the app claims nothing about Google until it can check for itself.")
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
