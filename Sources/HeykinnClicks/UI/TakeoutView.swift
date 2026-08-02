import SwiftUI

struct TakeoutView: View {
    @EnvironmentObject private var store: AppStore
    @State private var isFolderPickerPresented = false
    @State private var importRequest: TakeoutImportRequest?
    @State private var deleteCandidate: TakeoutArchive?

    /// Multi-part zips grouped by export session; everything else listed singly.
    private var grouped: (sets: [TakeoutExportSet], singles: [TakeoutArchive]) {
        let bySet = Dictionary(grouping: store.takeoutArchives.filter { $0.exportSetID != nil }) {
            $0.exportSetID!
        }
        let sets = bySet
            .filter { $0.value.count > 1 }
            .map { TakeoutExportSet(setID: $0.key, parts: $0.value.sorted { ($0.partNumber ?? 0) < ($1.partNumber ?? 0) }) }
            .sorted { $0.setID > $1.setID }
        let multiPartSetIDs = Set(sets.map(\.setID))
        let singles = store.takeoutArchives.filter {
            $0.exportSetID == nil || !multiPartSetIDs.contains($0.exportSetID!)
        }
        return (sets, singles)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Google Takeout exports found on your drives can be imported into the archive. The archive files themselves are never modified or deleted — media is copied into staging, paired with Google's JSON sidecars for capture dates and locations, and deduplicated against the catalog. Split downloads (takeout-…-001.zip, -002.zip, …) are grouped into export sets and imported together.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Automatically manage Takeout on managed drives", isOn: $store.autoManageTakeout)
                        .toggleStyle(.switch)
                    Text("On connect, a managed drive is scanned, zips are extracted in place, and everything is imported — with the drive's Takeout files counting as its replica copy. The second drive's copy fills in when it connects.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let activity = store.takeoutActivity {
                    TakeoutActivityBanner(activity: activity)
                }

                GroupBox("Scan for Takeout archives") {
                    VStack(alignment: .leading, spacing: 8) {
                        let connectedDrives = store.drives.filter { store.connectedMounts[$0.id] != nil }
                        if connectedDrives.isEmpty {
                            Text("No managed drives connected. Connect a drive to scan it, or scan any folder.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        ForEach(connectedDrives) { drive in
                            HStack {
                                Label(drive.name, systemImage: "externaldrive")
                                Spacer()
                                Button("Scan \(drive.name)") {
                                    if let mount = store.connectedMounts[drive.id] {
                                        store.scanForTakeout(rootURL: mount, driveID: drive.id)
                                    }
                                }
                                .disabled(store.takeoutActivity != nil)
                            }
                        }
                        HStack {
                            Label("Any folder", systemImage: "folder")
                            Spacer()
                            Button("Scan a folder…") { isFolderPickerPresented = true }
                                .disabled(store.takeoutActivity != nil)
                        }
                    }
                    .padding(6)
                }

                let (sets, singles) = grouped

                ForEach(sets) { set in
                    exportSetBox(set)
                }

                GroupBox(sets.isEmpty ? "Archives" : "Other archives") {
                    if singles.isEmpty {
                        Text(sets.isEmpty ? "Nothing discovered yet. Scan a drive or folder above." : "No standalone archives.")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(6)
                    } else {
                        VStack(spacing: 10) {
                            ForEach(singles) { archive in
                                archiveRow(archive, showImportButton: true)
                            }
                        }
                        .padding(6)
                    }
                }
            }
            .padding()
        }
        .navigationTitle("Google Takeout")
        .fileImporter(
            isPresented: $isFolderPickerPresented,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                store.scanForTakeout(rootURL: url, driveID: nil)
            }
        }
        .sheet(item: $importRequest) { request in
            TakeoutImportSheet(request: request)
        }
        .confirmationDialog(
            "Delete extracted folder?",
            isPresented: Binding(
                get: { deleteCandidate != nil },
                set: { if !$0 { deleteCandidate = nil } }
            )
        ) {
            if let candidate = deleteCandidate {
                Button("Delete \(candidate.displayName)", role: .destructive) {
                    store.deleteExtractedTakeoutFolder(candidate.id)
                    deleteCandidate = nil
                }
            }
            Button("Cancel", role: .cancel) { deleteCandidate = nil }
        } message: {
            if let candidate = deleteCandidate {
                Text("Its \(candidate.importedAssetCount) imported asset(s) are fully replicated to both managed drives, and the zip original stays on the drive. This only reclaims the extracted copy's space.")
            }
        }
    }

    private func exportSetBox(_ set: TakeoutExportSet) -> some View {
        let toImport = set.unimportedPreferredParts
        let allAccessible = toImport.allSatisfy { FileManager.default.fileExists(atPath: $0.path) }
        let totalBytes = set.parts.reduce(Int64(0)) { $0 + $1.sizeBytes }
        let hasFolderTwins = set.representativesByPartNumber.values.contains { $0.count > 1 }

        return GroupBox("Export set \(set.setID) — \(set.uniquePartCount) parts, \(Formatters.bytes.string(fromByteCount: totalBytes))") {
            VStack(alignment: .leading, spacing: 10) {
                if !set.missingPartNumbers.isEmpty {
                    Label(
                        "Parts missing from this set: \(set.missingPartNumbers.map(String.init).joined(separator: ", ")). Import will proceed with the parts found, but the export may be incomplete.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                }
                HStack {
                    Text(toImport.isEmpty
                         ? "All parts imported."
                         : "\(toImport.count) of \(set.uniquePartCount) part(s) not yet imported.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if !toImport.isEmpty {
                        Button("Import set…") {
                            importRequest = TakeoutImportRequest(archives: toImport, setID: set.setID)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!allAccessible || store.isImporting || store.takeoutActivity != nil)
                    }
                }
                if hasFolderTwins {
                    Text("Parts available both as zip and extracted folder import from the folder — no extraction needed.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                let extractable = set.parts.filter { part in
                    part.kind == .zip
                        && FileManager.default.fileExists(atPath: part.path)
                        && !FileManager.default.fileExists(atPath: TakeoutExtractor.destinationURL(forZip: part.url).path)
                }
                if !extractable.isEmpty {
                    HStack {
                        Text("Pre-extracting on the drive makes imports faster and avoids Mac scratch space.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Extract \(extractable.count) zip part(s) on drive") {
                            store.extractTakeoutZips(extractable.map(\.id))
                        }
                        .disabled(store.isImporting || store.takeoutActivity != nil)
                    }
                }
                if !allAccessible {
                    Text("Some parts are on an offline drive — connect it to import the set.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                ForEach(set.parts) { part in
                    archiveRow(part, showImportButton: false)
                }
            }
            .padding(6)
        }
    }

    private func archiveRow(_ archive: TakeoutArchive, showImportButton: Bool) -> some View {
        let accessible = FileManager.default.fileExists(atPath: archive.path)
        let driveName = archive.driveID.flatMap { store.drivesByID[$0]?.name }

        return HStack(alignment: .top) {
            Image(systemName: archive.kind == .zip ? "doc.zipper" : "folder")
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(archive.displayName)
                        .font(.headline)
                    if let part = archive.partNumber {
                        Text("part \(part)")
                            .font(.caption)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.12), in: Capsule())
                    }
                }
                Text(archive.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 10) {
                    Text("\(archive.kind.displayName) · \(Formatters.bytes.string(fromByteCount: archive.sizeBytes))")
                    if let driveName {
                        Text("on \(driveName)\(accessible ? "" : " (offline)")")
                            .foregroundStyle(accessible ? Color.secondary : .orange)
                    } else if !accessible {
                        Text("not accessible")
                            .foregroundStyle(.orange)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if archive.isImported {
                    Label(
                        "Imported \(Formatters.relative(archive.importedAt)) — \(archive.importedAssetCount) asset(s), \(archive.skippedDuplicateCount) duplicate(s) skipped",
                        systemImage: "checkmark.circle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.green)
                }
            }
            Spacer()
            if archive.kind == .zip, accessible,
               !FileManager.default.fileExists(atPath: TakeoutExtractor.destinationURL(forZip: archive.url).path) {
                Button("Extract on drive") { store.extractTakeoutZips([archive.id]) }
                    .disabled(store.isImporting || store.takeoutActivity != nil)
                    .help("Extracts next to the zip (named without .zip) so imports skip the extraction step. The zip is kept.")
            }
            if archive.kind == .folder, archive.isImported, accessible {
                Button("Delete folder…", role: .destructive) { deleteCandidate = archive }
                    .disabled(!store.isBatchFullyReplicated(archive.importBatchID))
                    .help(store.isBatchFullyReplicated(archive.importBatchID)
                          ? "Reclaims the extracted copy's space. The zip original is kept."
                          : "Available once every imported asset is fully replicated to both managed drives.")
            }
            if archive.isImported {
                Button("Forget") { store.forgetTakeoutArchive(archive.id) }
                    .help("Removes this record from the catalog. The archive file and imported assets are untouched.")
            } else if showImportButton {
                Button("Import…") { importRequest = TakeoutImportRequest(archives: [archive], setID: nil) }
                    .buttonStyle(.borderedProminent)
                    .disabled(!accessible || store.isImporting || store.takeoutActivity != nil)
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
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
                    ProgressView(value: fraction)
                        .frame(maxWidth: 320)
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

struct TakeoutImportSheet: View {
    let request: TakeoutImportRequest
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var stillInGoogle = true

    private var title: String {
        if let setID = request.setID {
            return "Import export set \(setID) (\(request.archives.count) parts)"
        }
        return "Import \(request.archives[0].displayName)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.title3)
                .bold()
            Text("Media will be copied into staging as Local-resident assets (queued for drive replication), with capture dates and locations from Google's sidecar files. Exact duplicates already in the catalog\(request.archives.count > 1 ? " — including across parts —" : "") are skipped.")
                .font(.callout)
                .foregroundStyle(.secondary)

            Toggle("These photos still exist in Google Photos", isOn: $stillInGoogle)
            Text(stillInGoogle
                 ? "A single GoogleCloud → Local migration job will track the temporary overlap\(request.archives.count > 1 ? " for the whole set" : ""): verify replication, then confirm you've deleted the originals from Google Photos to complete it."
                 : "The assets will be recorded as present only in the Local domain.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if request.archives.contains(where: { $0.kind == .zip }) {
                Label("Zips are extracted to a temporary workspace one part at a time; large archives take a while and need matching free disk space.", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button(request.archives.count > 1 ? "Import \(request.archives.count) parts" : "Import") {
                    store.importTakeoutArchives(request.archives.map(\.id), assumeStillInGoogle: stillInGoogle)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 500)
    }
}
