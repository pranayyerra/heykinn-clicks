import SwiftUI

/// The folders somebody actually added, and what came out of each.
///
/// The Sources screen said "Photos copied in from a folder on a disk" and
/// stopped there — a description of the *category*, with the one thing the
/// reader wants to know about their own archive left out: which folders? The
/// app has always known. Every import writes an `ImportBatch` with the path,
/// the time, and how many photos came in, were skipped as duplicates, or
/// failed; it was only ever rendered as a line in the audit log, filed under
/// the mechanism rather than under the place the photos came from.
struct FolderSourceList: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var commands: AppCommandBus
    @State private var opened: UUID?

    /// Folder imports, newest first.
    ///
    /// Filtered, because an `ImportBatch` is written by every import path —
    /// Takeout and Apple Photos as much as a folder somebody chose. Listing
    /// them all under "folders you have added" showed a user seven Google
    /// Takeout imports as folders they had picked, none of which they
    /// remembered doing, and with no paths under them because three of the
    /// four writers put a label in `sourcePath` rather than a path.
    private var allFolderBatches: [ImportBatch] {
        store.importBatches.filter(\.isFolderImport)
    }

    /// Folder imports worth showing, newest first.
    ///
    /// The app's own folders are left out. Before the self-import guard
    /// existed, pointing "look for copies this drive already has" at a host
    /// device swept the app's own replica root, which wrote a batch row for
    /// `HeykinnClicks/LocalCopy` — so a screen headed "folders you have added"
    /// listed a folder the user had never seen, let alone added.
    ///
    /// Filtered here rather than deleted from the catalog: the import did
    /// happen, and a record of what the app did to itself is worth keeping even
    /// when it is not worth showing.
    private var batches: [ImportBatch] {
        allFolderBatches
            .filter { batch in
                guard batch.isFilesystemPath else { return true }
                return !store.isAppOwnedFolder(
                    URL(fileURLWithPath: batch.sourcePath, isDirectory: true)
                )
            }
            .sorted { $0.startedAt > $1.startedAt }
    }

    /// Photos this source is credited with that no recorded folder accounts
    /// for — imported before the app wrote a batch row, or by a version that
    /// did not.
    ///
    /// The count above this list comes from the photos and the list comes from
    /// the batches, and those are two different questions. On a real archive
    /// they disagreed by eight: the header said "All 8 in the archive" over an
    /// empty list, which reads as the app having lost them. They are not lost;
    /// what is missing is the record of which folder they came from, and that
    /// is worth saying rather than hiding by counting the other way.
    private var unaccountedFor: [Asset] {
        // Every folder batch, including the ones not shown: a hidden batch's
        // photos are accounted for, they are simply not listed.
        let folderBatchIDs = Set(allFolderBatches.map(\.id))
        return store.assets.filter { asset in
            guard asset.importOrigin.isFolderLike, !asset.isLivePhotoMotion else { return false }
            guard let batchID = asset.importBatchID else { return true }
            return !folderBatchIDs.contains(batchID)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(batches) { batch in
                row(batch)
                if opened == batch.id {
                    contents(of: batch)
                }
            }
            if !unaccountedFor.isEmpty {
                unaccountedRow
            }
        }
    }

    /// The source a batch's photos belong to, so its settings can be edited
    /// from where its photos are shown. Nil for photos imported before sources
    /// existed and not yet backfilled.
    /// What keeps this folder's photos, said plainly.
    private func storageNote(for batch: ImportBatch) -> String? {
        guard let assetID = store.assets.first(where: { $0.importBatchID == batch.id })?.id,
              let sourceID = store.sourceIDByAsset[assetID]
        else { return nil }
        switch store.groupPlacement(forSource: sourceID) {
        case .none:
            return nil
        case .exclusive(let group):
            return "Kept as \(Formatters.copies(group.desiredCopies)) on \(store.deviceNames(group.destinationTargetIDs))."
        case .shared(let group, let otherPhotos):
            return "Kept as \(Formatters.copies(group.desiredCopies)) on \(store.deviceNames(group.destinationTargetIDs)), in the group \(group.label) — which also holds \(Formatters.count(otherPhotos, "photo")) from elsewhere."
        case .split(let groups, _):
            return "These photos are kept in \(Formatters.count(groups.count, "group")): \(groups.map(\.label).joined(separator: ", "))."
        }
    }

    @ViewBuilder
    private var unaccountedRow: some View {
        let assets = unaccountedFor
        let origins = Set(assets.map(\.importOrigin))
            .map(\.displayName)
            .sorted()
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "questionmark.folder")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Added before the app kept a record")
                        .font(.callout.weight(.medium))
                    Text("From \(origins.joined(separator: " and ")) — the folder itself was not written down")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Text(Formatters.count(assets.count, "photo"))
                    .font(.callout)
                    .monospacedDigit()
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))

            // The folder these came from was never written down, but where
            // they are *now* is known perfectly well — and that is the part
            // that matters for whether they are safe.
            let status = store.copyStatus(forAssetIDs: assets.map(\.id))
            if status.total > 0 {
                SourceCopyStatusView(status: status, showsLoadBearingWarning: false)
                    .padding(.leading, 28)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(assets.prefix(24)) { asset in
                        AssetThumbnailView(asset: asset, allowsHoverPreview: false)
                            .frame(width: 56, height: 56)
                            .clipShape(RoundedRectangle(cornerRadius: 5))
                    }
                }
            }
            .padding(.leading, 28)
        }
    }

    private func row(_ batch: ImportBatch) -> some View {
        let isOpen = opened == batch.id
        return Button {
            opened = isOpen ? nil : batch.id
        } label: {
            HStack(spacing: 10) {
                Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(width: 10)
                Image(systemName: "folder")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    // The folder's own name, big enough to recognise, with the
                    // path it sits at underneath. A full path as the heading
                    // is unreadable and truncates from the wrong end.
                    Text(batch.isFilesystemPath
                         ? (batch.sourcePath as NSString).lastPathComponent
                         : batch.sourcePath)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    if batch.isFilesystemPath {
                        Text((batch.sourcePath as NSString).deletingLastPathComponent)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(Formatters.count(batch.importedCount, "photo"))
                        .font(.callout)
                        .monospacedDigit()
                    Text(Formatters.relative(batch.startedAt))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                Color.secondary.opacity(isOpen ? 0.10 : 0.05),
                in: RoundedRectangle(cornerRadius: 8)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func contents(of batch: ImportBatch) -> some View {
        let assets = store.assets
            .filter { $0.importBatchID == batch.id && !$0.isLivePhotoMotion }
            .sorted { ($0.captureDate ?? $0.importDate) > ($1.captureDate ?? $1.importDate) }

        VStack(alignment: .leading, spacing: 8) {
            // What happened, not only what arrived. A folder of 400 that
            // brought in 12 is a fact worth knowing, and "388 were already in
            // the archive" is the reason — otherwise it reads as a failure.
            HStack(spacing: 14) {
                stat(batch.importedCount, "came in", .green)
                if batch.duplicateCount > 0 {
                    stat(batch.duplicateCount, "already had", .secondary)
                }
                if batch.failedCount > 0 {
                    stat(batch.failedCount, "could not be read", .orange)
                }
            }
            // The path whether or not its disk is attached. It used to vanish
            // with the drive, which hid the answer at exactly the moment the
            // question gets asked: an unreachable folder is the one somebody
            // needs to be told the location of.
            if batch.isFilesystemPath {
                PathRow(path: batch.sourcePath)
            }

            // Where this folder's photos are now — the same reading the Google
            // export cards do, off the same replica states. A folder on one of
            // the archive's own devices is not only a source: its files were
            // counted as that device's copy rather than duplicated onto it,
            // which makes the folder load-bearing, and the status says so.
            let status = store.copyStatus(forBatch: batch.id)
            if status.total > 0 {
                Divider()
                SourceCopyStatusView(status: status)
                // Reported, not edited. Two screens writing one setting is
                // what made "does this override that?" a question anybody had
                // to ask; Policies is the single place it is answered.
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if let note = storageNote(for: batch) {
                        Text(note)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Button("Change under Keep safe") { commands.requestedPage = .targets }
                        .buttonStyle(.link)
                        .font(.caption)
                }
                .padding(.top, 2)
            }

            if assets.isEmpty {
                Text("Nothing from this folder is in the archive — every photo in it was already here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(assets.prefix(24)) { asset in
                            AssetThumbnailView(asset: asset, allowsHoverPreview: false)
                                .frame(width: 56, height: 56)
                                .clipShape(RoundedRectangle(cornerRadius: 5))
                        }
                        if assets.count > 24 {
                            Text("+\((assets.count - 24).formatted())")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(width: 56, height: 56)
                                .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 5))
                        }
                    }
                }
            }
        }
        .padding(.leading, 28)
        .padding(.bottom, 4)
    }

    private func stat(_ value: Int, _ label: String, _ tint: Color) -> some View {
        HStack(spacing: 4) {
            Text(value.formatted())
                .font(.callout.weight(.medium))
                .monospacedDigit()
                .foregroundStyle(tint)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
