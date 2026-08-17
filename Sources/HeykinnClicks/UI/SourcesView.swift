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
    /// Both pickers are the window's, shared with the File menu — see the note
    /// on `AppCommandBus`. This screen used to own copies of both.
    @EnvironmentObject private var commands: AppCommandBus
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
        // Counted once per catalog change in the store, not per redraw here.
        let indexed = store.applePhotosIndexedCount
        let library = store.applePhotosLibraryCount
        let state: PhotoSource.State
        switch store.applePhotosState {
        case .notDetermined:
            state = .notSet
        case .denied:
            state = .blocked("macOS is blocking access")
        case .unavailable:
            state = .blocked("Not available on this device")
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
            detail: "The Photos library on this device",
            help: Self.explanation(for: "apple")
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
                : "Counted in files, because Google splits one download into several",
            help: Self.explanation(for: "google")
        )
    }

    private var hasFolderOriginPhotos: Bool {
        store.assets.contains { $0.importOrigin.isFolderLike && !$0.isLivePhotoMotion }
    }

    private var folderSource: PhotoSource {
        // One definition, shared with the list below and with the batch model,
        // so the node cannot count photos one way while the list counts their
        // sources another — which is how "All 8 in the archive" ended up over
        // an empty list.
        let fromFolders = store.assets.filter {
            $0.importOrigin.isFolderLike && !$0.isLivePhotoMotion
        }.count
        // Names the folders rather than the category. "Photos copied in from a
        // folder on a disk" describes what this kind of source *is*, which the
        // reader worked out from the word "folder" — and leaves out the only
        // thing they cannot know without being told: which folders.
        // The app's own folders are not folders somebody added — same filter
        // `FolderSourceList` applies to the list this summarises, or the card
        // and the list underneath it disagree about what is in the archive.
        let folderBatches = store.importBatches.filter {
            guard $0.isFolderImport else { return false }
            guard $0.isFilesystemPath else { return true }
            return !store.isAppOwnedFolder(URL(fileURLWithPath: $0.sourcePath, isDirectory: true))
        }
        let newest = folderBatches.max { $0.startedAt < $1.startedAt }
        let detail: String
        if let newest {
            let name = newest.isFilesystemPath
                ? (newest.sourcePath as NSString).lastPathComponent
                : newest.sourcePath
            detail = folderBatches.count == 1
                ? name
                : "\(Formatters.count(folderBatches.count, "folder")) · most recently \(name)"
        } else if fromFolders > 0 {
            // Photos from folders, but no folder recorded. Saying "not set up"
            // over a count of eight is the same contradiction from the other end.
            detail = "Added before the app recorded which folder"
        } else {
            detail = "A backup, a memory card, anywhere photos sit loose"
        }
        return PhotoSource(
            id: "folder",
            name: "Folders you have added",
            symbol: "folder",
            state: fromFolders == 0 ? .notSet : .allIn(count: fromFolders),
            detail: detail,
            help: Self.explanation(for: "folders")
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

                // The list is the list. It draws every place photos arrive
                // from, with its name and its state — and nothing about where
                // they are kept, which is Keep safe's subject and was being
                // answered here in a second voice.
                SourceFlowView(
                    sources: flowSources,
                    opened: expanded,
                    onSelect: { toggle($0.id) }
                ) { source in
                    // Inside the row, not under the list. Three lists on three
                    // screens now open the same way, and none of them has to
                    // repeat a name to say which thing it is describing.
                    detailPanel(source)
                } action: { source in
                    switch source.id {
                    case "apple":
                        // Once connected the row's own detail carries what to
                        // do next, and a button that repeats it is noise.
                        guard store.applePhotosState != .connected else { return nil }
                        return (
                            "Connect Photos", "photo.on.rectangle.angled",
                            { Task { await store.connectApplePhotos() } }
                        )
                    case "google":
                        return (
                            "Find a download", "magnifyingglass",
                            { commands.isExportSearchPickerPresented = true }
                        )
                    default:
                        return (
                            "Choose a folder", "folder.badge.plus",
                            { commands.isImportPickerPresented = true }
                        )
                    }
                }
                .padding(.vertical, 4)

                if let activity = store.takeoutActivity {
                    TakeoutActivityBanner(activity: activity)
                }
            }
            .padding(20)
        }
        .navigationTitle("Add photos")
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
                    Button("Search a folder…") { commands.isExportSearchPickerPresented = true }
                } label: {
                    Label("Search for Google downloads", systemImage: "magnifyingglass")
                }
                .disabled(store.takeoutActivity != nil)
            }
        }
        .sheet(item: $importRequest) { TakeoutImportSheet(request: $0) }
    }

    /// The opened source's detail, titled so it is obvious which node it
    /// belongs to.
    ///
    /// No header of its own. It opens inside the row that names it, and the
    /// row's chevron already closes it — a title and a Hide button here were
    /// the same two things a line apart.
    @ViewBuilder
    private func detailPanel(_ source: PhotoSource) -> some View {
        VStack(alignment: .leading, spacing: 0) {

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
        // No background of its own. It sits inside the card the row draws, and
        // a second rounded fill inside that one is the box-in-a-box the whole
        // pass is removing.
    }

    /// What this screen is, in the two sentences someone needs before any of
    /// the numbers below mean anything — including the reassurance they are
    /// most likely to want first, which is that pointing the app at their
    /// photos does not put those photos at risk.
    private var introduction: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Was "Places your photos already live" — present tense, on a
            // screen whose whole job is arrival. The Google download reads as
            // a place because it *is* one, which is why it belongs under Keep
            // safe rather than being described in two tenses here.
            Text("Where your photos come from")
                .font(.title3)
            Label(
                "Your originals are only ever read. Nothing here moves or deletes them.",
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
                    // No Connect button here: the row this opens from has
                    // one, and two buttons doing one thing a centimetre apart
                    // is a choice nobody has to make.
                }
            case .denied:
                VStack(alignment: .leading, spacing: 8) {
                    Label(
                        store.applePhotosIndexedCount > 0
                            ? "macOS no longer recognises this app's permission, so it refused without asking. This happens when the app is updated or re-signed — the switch below will not have it listed."
                            : "macOS is blocking access to your Photos library.",
                        systemImage: "xmark.circle"
                    )
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)

                    if store.applePhotosIndexedCount > 0 {
                        // The command, on screen and selectable, rather than a
                        // sentence telling somebody to go and find out what to
                        // type. Nothing here can run it for them: an app that
                        // could clear its own privacy refusals would be a
                        // reason not to trust any of them.
                        Text("Run this in Terminal, then reopen the app:")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Text("tccutil reset Photos \(Bundle.main.bundleIdentifier ?? "com.heykinn.HeykinnClicks")")
                            .font(.system(.callout, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(6)
                            .background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
                    }

                    HStack(spacing: 8) {
                        Button("Open Photos settings") {
                            ApplePhotosVerifier.openPrivacySettings()
                        }
                        Button("Try again") {
                            Task { await store.connectApplePhotos() }
                        }
                    }
                    .font(.callout)
                }
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
        let indexed = store.applePhotosIndexedCount

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
                    Text("macOS does not let the app find this out for itself, and the answer changes what a photo found here means — a copy in Apple's cloud, or a copy on this device. It is safer to ask you than to guess. You can check in Photos → Settings → iCloud.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button("Yes, it syncs to iCloud") { store.iCloudPhotosEnabled = true }
                        Button("No, these stay on this device") { store.iCloudPhotosEnabled = false }
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
    private func appleHeadline(indexed: Int, awaiting: Int) -> String {
        if store.applePhotosLibraryCount == 0 {
            return "The library is empty, or its photos are not stored on this device."
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
                    Text("Google calls this a Takeout: you ask for a copy of your photos at takeout.google.com and it emails you a set of large .zip files, usually about 10 GB each. Put them on one of your drives, or anywhere on this device, and use Find a download. The app unpacks and reads them on its own from there.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(exports.enumerated()), id: \.element.id) { index, export in
                    if index > 0 { Divider() }
                    ExportCard(export: export, importRequest: $importRequest)
                }
            }
        }
    }

    /// What each way in is, for the ⓘ beside its name.
    ///
    /// Only for a section with something in it. Where a section is *empty*
    /// these words are not furniture, they are the entire content — "None
    /// found yet" followed by nothing would be a screen that has stopped
    /// talking to somebody who has not started yet — so the empty states keep
    /// their prose where it is.
    static func explanation(for sourceID: String) -> String {
        switch sourceID {
        case "apple":
            return "The Photos library on this device. Connecting lets the app look through it, spot the photos this archive already has, and copy in the ones it is missing. It reads the library and never changes it."
        case "google":
            return "Google splits one download into several large .zip files. Each block is one of them — click one to see which drive holds it, as the .zip or unpacked into a folder."
        default:
            return "An old backup, a memory card, a Downloads folder — anywhere photos and videos are sitting loose. The app copies them into the archive and leaves the folder exactly as it found it."
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
                if store.importBatches.filter(\.isFolderImport).isEmpty && !hasFolderOriginPhotos {
                    Text("An old backup, a memory card, a Downloads folder — anywhere photos and videos are sitting loose. The app copies them into the archive and leaves the folder exactly as it found it.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    FolderSourceList()
                }
                // No "Choose a folder" here either — it is on the row.
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
