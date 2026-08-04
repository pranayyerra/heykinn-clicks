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
    @State private var opened: UUID?

    /// Newest first — a folder added this morning is the one being asked
    /// about; one added last year is history.
    private var batches: [ImportBatch] {
        store.importBatches.sorted { $0.startedAt > $1.startedAt }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(batches) { batch in
                row(batch)
                if opened == batch.id {
                    contents(of: batch)
                }
            }
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
                    Text((batch.sourcePath as NSString).lastPathComponent)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    Text((batch.sourcePath as NSString).deletingLastPathComponent)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
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
            HStack(spacing: 10) {
                Text(batch.sourcePath)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                RevealButton(path: batch.sourcePath)
                Spacer(minLength: 0)
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
