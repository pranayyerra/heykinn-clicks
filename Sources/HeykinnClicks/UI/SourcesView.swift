import SwiftUI

/// Every place photos come into the archive from, presented the same way.
///
/// Google Takeout had a screen of its own while Apple Photos lived behind a
/// toggle in Settings — two ingest sources, two unrelated experiences, and the
/// user had to know which was which. They are the same kind of thing: a place
/// holding photos, some already in the archive and some not, with work to do
/// about the difference. So they read the same, and Settings goes back to
/// holding preferences rather than jobs.
///
/// Written for someone opening the app for the first time. Every source says
/// what it is before it says what state it is in, because "3 of 12 parts
/// imported" means nothing to a reader who does not yet know what a part is;
/// the app's own words for things — target, export part, replica — are
/// explained here or not used here. The precision is kept: plainer wording is
/// not permission to claim more than the app checked.
struct SourcesView: View {
    @EnvironmentObject private var store: AppStore
    @State private var isExportSearchPickerPresented = false
    @State private var isFolderImportPickerPresented = false
    @State private var importRequest: TakeoutImportRequest?
    /// Which sources are showing their detail. A source's detail belongs to
    /// the source: it used to sit further down the page as its own section, so
    /// clicking a node in the diagram scrolled somewhere else and the reader
    /// had to keep the connection in their head. Nothing is open to begin
    /// with, so the screen opens as three sources and a diagram rather than
    /// everything at once.
    @State private var expanded: Set<String> = []

    // MARK: - The flow diagram

    /// The three sources as the diagram sees them. One node per kind rather
    /// than one per download: the diagram answers "where do my photos come
    /// from, and is it all in yet?", and four cards for four zips of the same
    /// download answers a question nobody asked. The breakdown is in the cards
    /// underneath, which is where someone goes once they want it.
    private var flowSources: [PhotoSource] {
        [applePhotosSource, googleSource, folderSource]
    }

    private var applePhotosSource: PhotoSource {
        let indexed = store.assets.filter { $0.providerLocalID != nil }.count
        let library = store.applePhotosLibraryCount
        let state: PhotoSource.State
        switch store.applePhotosState {
        case .notDetermined:
            state = .notSet
        case .denied:
            state = .blocked("macOS is blocking access")
        case .unavailable:
            state = .blocked("Not available on this Mac")
        case .connected:
            if library == 0 {
                state = .nothingFound
            } else if indexed >= library {
                state = .allIn(count: indexed)
            } else {
                state = .partlyIn(inArchive: indexed, total: library)
            }
        }
        return PhotoSource(
            id: "apple",
            name: "Photos app",
            symbol: "photo.on.rectangle.angled",
            state: state,
            detail: "The Photos library on this Mac"
        )
    }

    private var googleSource: PhotoSource {
        let awaiting = TakeoutExportSet.partsAwaitingImport(in: store.takeoutArchives)
        let total = Set(
            store.takeoutArchives.compactMap { archive in
                archive.exportSetID.flatMap { set in archive.partNumber.map { "\(set)-\($0)" } }
                    ?? archive.id.uuidString
            }
        ).count
        let state: PhotoSource.State
        if store.takeoutArchives.isEmpty {
            state = .notSet
        } else if awaiting == 0 {
            state = .allIn(count: total)
        } else {
            state = .partlyIn(inArchive: total - awaiting, total: total)
        }
        return PhotoSource(
            id: "google",
            name: "Google Photos download",
            symbol: "shippingbox",
            state: state,
            detail: store.takeoutArchives.isEmpty
                ? "A copy of your photos from takeout.google.com"
                : "Counted in files, because Google splits one download into several"
        )
    }

    private var folderSource: PhotoSource {
        let fromFolders = store.assets.filter {
            $0.importOrigin == .localFolder || $0.importOrigin == .whatsapp
        }.count
        // Names the folders rather than the category. "Photos copied in from a
        // folder on a disk" describes what this kind of source *is*, which the
        // reader worked out from the word "folder" — and leaves out the only
        // thing they cannot know without being told: which folders.
        let newest = store.importBatches.max { $0.startedAt < $1.startedAt }
        let detail: String
        if let newest, !store.importBatches.isEmpty {
            let name = (newest.sourcePath as NSString).lastPathComponent
            detail = store.importBatches.count == 1
                ? name
                : "\(Formatters.count(store.importBatches.count, "folder")) · most recently \(name)"
        } else {
            detail = "A backup, a memory card, anywhere photos sit loose"
        }
        return PhotoSource(
            id: "folder",
            name: "Folders you have added",
            symbol: "folder",
            state: fromFolders == 0 ? .notSet : .allIn(count: fromFolders),
            detail: detail
        )
    }

    var body: some View { content }

    private func toggle(_ id: String) {
        withAnimation(.easeInOut(duration: 0.18)) {
            if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
        }
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                introduction

                // The diagram is the list. It already draws every source with
                // its name, its state and how much of it has made it across —
                // repeating that as a row of headers underneath was the same
                // fact twice on one screen, which is the thing this screen was
                // being fixed for.
                SourceFlowView(
                    sources: flowSources,
                    photoCount: store.assets.count,
                    opened: expanded,
                    onSelect: { toggle($0.id) }
                )
                .padding(.vertical, 4)

                if let activity = store.takeoutActivity {
                    TakeoutActivityBanner(activity: activity)
                }

                // Opened detail, directly under the thing it belongs to.
                ForEach(flowSources.filter { expanded.contains($0.id) }) { source in
                    detailPanel(source)
                }
            }
            .padding(20)
        }
        .navigationTitle("Sources")
        .toolbar {
            ToolbarItem {
                Menu {
                    ForEach(store.targets.filter { store.reachablePaths[$0.id] != nil }) { target in
                        Button("Search \(target.name)") {
                            if let mount = store.reachablePaths[target.id] {
                                store.scanForTakeout(rootURL: mount, targetID: target.id)
                            }
                        }
                    }
                    Button("Search a folder…") { isExportSearchPickerPresented = true }
                } label: {
                    Label("Search for Google downloads", systemImage: "magnifyingglass")
                }
                .disabled(store.takeoutActivity != nil)
            }
        }
        .sheet(item: $importRequest) { TakeoutImportSheet(request: $0) }
        .fileImporter(
            isPresented: $isExportSearchPickerPresented,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                store.scanForTakeout(rootURL: url, targetID: nil)
            }
        }
        .fileImporter(
            isPresented: $isFolderImportPickerPresented,
            allowedContentTypes: [.folder, .image, .movie],
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result { store.importFolders(urls) }
        }
    }

    /// The opened source's detail, titled so it is obvious which node it
    /// belongs to and closable from its own header.
    @ViewBuilder
    private func detailPanel(_ source: PhotoSource) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: source.symbol)
                    .foregroundStyle(source.isSet ? source.tint : Color.secondary)
                Text(source.name)
                    .font(.headline)
                Spacer(minLength: 0)
                Button {
                    toggle(source.id)
                } label: {
                    Label("Hide", systemImage: "chevron.up")
                        .font(.caption)
                }
                .buttonStyle(.link)
            }
            .padding(12)

            Group {
                switch source.id {
                case "apple": applePhotosCard
                case "google": takeoutSection
                default: folderCard
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
        }
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
    }

    /// What this screen is, in the two sentences someone needs before any of
    /// the numbers below mean anything — including the reassurance they are
    /// most likely to want first, which is that pointing the app at their
    /// photos does not put those photos at risk.
    private var introduction: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Places your photos already live")
                .font(.title3)
            Label(
                "Sources are only ever read. Nothing here moves or deletes your originals.",
                systemImage: "lock.open.trianglebadge.exclamationmark"
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Apple Photos

    private var applePhotosCard: some View {
        Group {
            switch store.applePhotosState {
            case .connected:
                connectedApplePhotos
            case .notDetermined:
                VStack(alignment: .leading, spacing: 10) {
                    Text("Your Photos library probably holds pictures this archive does not. Connecting lets the app look through it, spot the ones it already has, and copy in the ones it is missing. It reads the library and never changes it.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Connect Photos…") {
                        Task { await store.connectApplePhotos() }
                    }
                    .buttonStyle(.borderedProminent)
                }
            case .denied:
                Label("macOS is blocking access. Allow it in System Settings → Privacy & Security → Photos, then reopen the app.", systemImage: "xmark.circle")
                    .font(.callout)
                    .foregroundStyle(.orange)
            case .unavailable(let reason):
                Label(reason, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
        }
    }

    @ViewBuilder
    private var connectedApplePhotos: some View {
        let awaiting = store.applePhotosAwaitingImport.count
        let indexed = store.assets.filter { $0.providerLocalID != nil }.count

        VStack(alignment: .leading, spacing: 10) {
            Text(appleHeadline(indexed: indexed, awaiting: awaiting))
                .font(.title3)
                .fixedSize(horizontal: false, vertical: true)

            if store.iCloudPhotosEnabled == nil {
                // Topology the app cannot detect and must not assume. Asked
                // here, where the work is, rather than buried in preferences —
                // and asked in terms of the setting the user themselves turned
                // on, not in terms of what the app will do with the answer.
                VStack(alignment: .leading, spacing: 6) {
                    Text("One question first: is iCloud Photos turned on for this library?")
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("macOS does not let the app find this out for itself, and the answer changes what a photo found here means — a copy in Apple's cloud, or a copy on this Mac. It is safer to ask you than to guess. You can check in Photos → Settings → iCloud.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button("Yes, it syncs to iCloud") { store.iCloudPhotosEnabled = true }
                        Button("No, these stay on this Mac") { store.iCloudPhotosEnabled = false }
                    }
                }
            } else if indexed == 0 {
                Button("Look through the library") { store.indexApplePhotos() }
                    .buttonStyle(.borderedProminent)
                    .disabled(store.isIndexingApplePhotos)
            }

            if awaiting > 0 {
                ProgressView(
                    value: Double(indexed - awaiting),
                    total: Double(max(indexed, 1))
                )
                Text("Copying the full-size originals in, so your drives can hold them. A photo the archive already has is recognised and left alone rather than stored twice.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 6) {
                if store.isIndexingApplePhotos || store.isImportingFromApplePhotos {
                    ProgressView().controlSize(.small)
                }
                Text(appleDetail(indexed: indexed, awaiting: awaiting))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            reclamationPreview
        }
    }

    /// What could be freed from Apple's cloud, and what is holding the rest up.
    ///
    /// Shown only once there is a verified cloud copy to talk about. Reclaiming
    /// is not built — this removes nothing — but the preconditions are the
    /// safety mechanism, and a mechanism nobody can see is one nobody can
    /// trust. Drawn here rather than on a screen of its own because it is a
    /// fact about this connector's library. Worded so the reader learns what it
    /// is for before they are given a number: the point is paying iCloud for
    /// copies of photos you already own outright.
    @ViewBuilder
    private var reclamationPreview: some View {
        let plan = store.reclamationPlan
        if !plan.isEmpty {
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Text("Freeing up iCloud")
                    .font(.callout)
                Text("Once the app can prove your own drives hold a photo safely, its iCloud copy is no longer paying for itself.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text(
                    plan.releasableAssetIDs.isEmpty
                        ? "Nothing is ready to be freed yet."
                        : "\(plan.releasableAssetIDs.count.formatted()) photo(s) — \(Formatters.bytes.string(fromByteCount: plan.releasableBytes)) — are safe enough on your own drives that their iCloud copy could go."
                )
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)

                ForEach(ReclamationPlanner.Blocker.allCases, id: \.self) { blocker in
                    if let count = plan.blocked[blocker], count > 0 {
                        Label(
                            "\(count.formatted()) not ready: \(blocker.displayName)",
                            systemImage: "circle.dotted"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }

                Text("This is a preview. Nothing is deleted from iCloud, and that part of the app is not built yet — when it is, it will go on this proof rather than on asking you to confirm.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func appleHeadline(indexed: Int, awaiting: Int) -> String {
        if store.applePhotosLibraryCount == 0 {
            return "The library is empty, or its photos are not stored on this Mac."
        }
        if store.iCloudPhotosEnabled == nil {
            return "\(store.applePhotosLibraryCount.formatted()) photos in the library."
        }
        if indexed == 0 {
            return "\(store.applePhotosLibraryCount.formatted()) photos in the library, none looked at yet."
        }
        if awaiting > 0 {
            return "\(awaiting.formatted()) of \(indexed.formatted()) still to bring into the archive."
        }
        return "All \(indexed.formatted()) photos from the library are in the archive."
    }

    private func appleDetail(indexed: Int, awaiting: Int) -> String {
        var parts = ["\(store.applePhotosLibraryCount.formatted()) in library"]
        if indexed > 0 { parts.append("\(indexed.formatted()) matched to the archive") }
        if awaiting > 0 { parts.append("\(awaiting.formatted()) being copied in") }
        return parts.joined(separator: " · ")
    }

    // MARK: - Google Takeout

    @ViewBuilder
    private var takeoutSection: some View {
        if exports.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("None found yet.")
                        .font(.callout)
                    Text("Google calls this a Takeout: you ask for a copy of your photos at takeout.google.com and it emails you a set of large .zip files, usually about 10 GB each. Put them on one of your drives, or anywhere on this Mac, and use Search for Google downloads above. The app unpacks and reads them on its own from there.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Text("Google splits one download into several large .zip files. Each block below is one of them — click one to see which drive holds it, as the .zip or unpacked into a folder.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(exports) { export in
                    ExportCard(export: export, importRequest: $importRequest)
                }
            }
        }
    }

    // MARK: - Plain folders

    /// The most ordinary case there is, and until now the one this screen had
    /// no answer for: photos sitting in a folder. It was reachable only from
    /// the Library screen's toolbar, which is not where someone goes looking
    /// for a place to add photos from.
    private var folderCard: some View {
        Group {
            VStack(alignment: .leading, spacing: 10) {
                if store.importBatches.isEmpty {
                    Text("An old backup, a memory card, a Downloads folder — anywhere photos and videos are sitting loose. The app copies them into the archive and leaves the folder exactly as it found it.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    FolderSourceList()
                }
                Button("Choose a folder…") { isFolderImportPickerPresented = true }
                    .disabled(store.isImporting)
                if store.isImporting {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Reading photos in…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var exports: [ExportSummary] {
        let grouped = Dictionary(grouping: store.takeoutArchives) { $0.exportSetID ?? "" }
        return grouped
            .map { ExportSummary(setID: $0.key, archives: $0.value, plan: store.archivePlan) }
            .sorted { $0.setID > $1.setID }
    }
}
