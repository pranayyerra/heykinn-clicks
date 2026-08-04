import SwiftUI

/// Photos the archive is holding more than one of.
///
/// The heading on each group used to be its content hash, truncated —
/// `2 copies — hash dup-hash-0…`. That is the database's name for the group
/// and there is nothing a person can do with it: you cannot recognise a
/// photograph from twelve characters of SHA-256, and the one thing you would
/// want to know from a list of duplicates — how much of the drive they are
/// costing — was not on the screen at all.
struct DuplicatesView: View {
    @EnvironmentObject private var store: AppStore

    /// Bytes held more than once: every copy after the first, in every group.
    ///
    /// The reason anybody opens this screen. It is also the honest form of the
    /// number — the first copy of each photo is not waste, and counting whole
    /// groups would have claimed back space the archive still needs.
    private var reclaimableBytes: Int64 {
        store.duplicateGroups.reduce(0) { total, group in
            let sizes = group.assetIDs.compactMap { store.assetsByID[$0]?.fileSize }
            guard let largest = sizes.max() else { return total }
            return total + sizes.reduce(0, +) - largest
        }
    }

    private var residencyIsUniform: Bool {
        var seen: ResidencyDomain?
        for asset in store.assets {
            if let seen, seen != asset.residency { return false }
            seen = asset.residency
        }
        return true
    }

    var body: some View {
        NavigationStack {
            Group {
                if store.duplicateGroups.isEmpty {
                    ContentUnavailableView(
                        "No two photos in the archive are identical",
                        systemImage: "square.on.square",
                        description: Text("The app compares every photo's contents as it comes in, so an identical copy is spotted whether or not the files are named the same.")
                    )
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            summary
                            ForEach(store.duplicateGroups) { group in
                                groupBox(group)
                            }
                        }
                        .padding(20)
                    }
                }
            }
            .navigationTitle("Duplicates")
            .navigationDestination(for: UUID.self) { assetID in
                AssetDetailView(assetID: assetID)
            }
        }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(Formatters.count(store.duplicateGroups.count, "photo")) \(store.duplicateGroups.count == 1 ? "is" : "are") in the archive more than once, taking up \(Formatters.bytes.string(fromByteCount: reclaimableBytes)) more than they need to.")
                .font(.title3)
                .fixedSize(horizontal: false, vertical: true)
            // Says what the app will and will not do, rather than defending
            // the design. "Manual by design" answers a question the reader did
            // not ask and leaves the one they did — so what do I do? — open.
            Text("Nothing here is deleted or merged for you. Choosing which copy to keep is not built yet; until it is, this is the list, and opening a photo shows you where each copy lives.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func groupBox(_ group: DuplicateGroup) -> some View {
        let assets = group.assetIDs.compactMap { store.assetsByID[$0] }
        // Named for the photograph, which is what the reader recognises. Where
        // the copies are named differently, both names are worth seeing —
        // that difference is usually the whole story of how it happened.
        let names = Set(assets.map(\.originalFilename)).sorted()
        let heading = names.count == 1
            ? names[0]
            : names.prefix(2).joined(separator: " · ") + (names.count > 2 ? " …" : "")
        let each = assets.first.map { Formatters.bytes.string(fromByteCount: $0.fileSize) } ?? ""

        return CardBox(title: heading, systemImage: "square.on.square") {
            VStack(alignment: .leading, spacing: 8) {
                Text("\(Formatters.count(group.count, "copy", "copies")) · \(each) each")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                ForEach(assets, id: \.id) { asset in
                    HStack {
                        AssetThumbnailView(asset: asset, allowsHoverPreview: false)
                            .frame(width: 44, height: 44)
                        NavigationLink(value: asset.id) {
                            VStack(alignment: .leading) {
                                Text(asset.originalFilename)
                                Text("Came in from \(asset.importOrigin.displayName)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                        Spacer()
                        if !residencyIsUniform {
                            ResidencyBadge(domain: asset.residency)
                        }
                    }
                }
            }
        }
    }
}
