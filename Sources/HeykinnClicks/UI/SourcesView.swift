import SwiftUI

/// Every place photos come into the archive from, presented the same way.
///
/// Google Takeout had a screen of its own while Apple Photos lived behind a
/// toggle in Settings — two ingest sources, two unrelated experiences, and the
/// user had to know which was which. They are the same kind of thing: a place
/// holding photos, some already in the archive and some not, with work to do
/// about the difference. So they read the same, and Settings goes back to
/// holding preferences rather than jobs.
struct SourcesView: View {
    @EnvironmentObject private var store: AppStore
    @State private var isFolderPickerPresented = false
    @State private var importRequest: TakeoutImportRequest?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let activity = store.takeoutActivity {
                    TakeoutActivityBanner(activity: activity)
                }

                applePhotosCard
                takeoutSection
            }
            .padding(20)
        }
        .navigationTitle("Sources")
        .toolbar {
            ToolbarItem {
                Menu {
                    ForEach(store.targets.filter { store.reachablePaths[$0.id] != nil }) { target in
                        Button("Look on \(target.name)") {
                            if let mount = store.reachablePaths[target.id] {
                                store.scanForTakeout(rootURL: mount, targetID: target.id)
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
        .sheet(item: $importRequest) { TakeoutImportSheet(request: $0) }
        .fileImporter(
            isPresented: $isFolderPickerPresented,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                store.scanForTakeout(rootURL: url, targetID: nil)
            }
        }
    }

    // MARK: - Apple Photos

    private var applePhotosCard: some View {
        CardBox(title: "Apple Photos", systemImage: "photo.on.rectangle.angled") {
            switch store.applePhotosState {
            case .connected:
                connectedApplePhotos
            case .notDetermined:
                VStack(alignment: .leading, spacing: 10) {
                    Text("The Photos library on this Mac holds photos this archive may not. Connecting lets the app see them, work out which it already protects, and bring in the rest.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Connect Apple Photos…") {
                        Task { await store.connectApplePhotos() }
                    }
                    .buttonStyle(.borderedProminent)
                }
            case .denied:
                Label("Access denied — grant it under System Settings → Privacy & Security → Photos, then relaunch.", systemImage: "xmark.circle")
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
                // here, where the work is, rather than buried in preferences.
                VStack(alignment: .leading, spacing: 6) {
                    Text("Does this library sync to iCloud? It decides whether photos found here mean “in Apple Cloud” or “on this Mac”, and the app has no way to tell.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button("Yes — it syncs") { store.iCloudPhotosEnabled = true }
                        Button("No — local to this Mac") { store.iCloudPhotosEnabled = false }
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
                Text("Bringing originals in so your targets can hold them. Photos already in the archive are matched and merged, never stored twice.")
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

    /// What reclamation would release, and what is holding the rest up.
    ///
    /// Shown only once there is a verified cloud copy to talk about. Reclaiming
    /// is not built — this removes nothing — but the preconditions are the
    /// safety mechanism, and a mechanism nobody can see is one nobody can
    /// trust. Drawn here rather than on a screen of its own because it is a
    /// fact about this connector's library.
    @ViewBuilder
    private var reclamationPreview: some View {
        let plan = store.reclamationPlan
        if !plan.isEmpty {
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Text(
                    plan.releasableAssetIDs.isEmpty
                        ? "Nothing in Apple Cloud is ready to release yet."
                        : "\(plan.releasableAssetIDs.count.formatted()) photo(s) — \(Formatters.bytes.string(fromByteCount: plan.releasableBytes)) — are protected locally well enough to release their Apple Cloud copy."
                )
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)

                ForEach(ReclamationPlanner.Blocker.allCases, id: \.self) { blocker in
                    if let count = plan.blocked[blocker], count > 0 {
                        Label(
                            "\(count.formatted()) waiting: \(blocker.displayName)",
                            systemImage: "circle.dotted"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }

                Text("Releasing is not built yet, and nothing here is removed. When it is, it happens on this proof rather than on a prompt.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func appleHeadline(indexed: Int, awaiting: Int) -> String {
        if store.applePhotosLibraryCount == 0 {
            return "The library is empty, or its photos are not on this Mac."
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
        if awaiting > 0 { parts.append("\(awaiting.formatted()) being brought in") }
        return parts.joined(separator: " · ")
    }

    // MARK: - Google Takeout

    @ViewBuilder
    private var takeoutSection: some View {
        if exports.isEmpty {
            CardBox(title: "Google Takeout", systemImage: "shippingbox") {
                Text("No exports found yet. Connect a target holding a Takeout download, or look in a folder — exports are unpacked and imported without further prompting.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            ForEach(exports) { export in
                ExportCard(export: export, importRequest: $importRequest)
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
