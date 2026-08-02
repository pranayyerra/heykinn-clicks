import SwiftUI

struct DuplicatesView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        NavigationStack {
            Group {
                if store.duplicateGroups.isEmpty {
                    ContentUnavailableView(
                        "No exact duplicates",
                        systemImage: "square.on.square",
                        description: Text("Duplicates are detected by content hash at import and on catalog scans.")
                    )
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            Text("Review is manual by design: the catalog never merges or deletes duplicates automatically.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                            ForEach(store.duplicateGroups) { group in
                                groupBox(group)
                            }
                        }
                        .padding()
                    }
                }
            }
            .navigationTitle("Duplicates")
            .navigationDestination(for: UUID.self) { assetID in
                AssetDetailView(assetID: assetID)
            }
        }
    }

    private func groupBox(_ group: DuplicateGroup) -> some View {
        GroupBox("\(group.count) copies — hash \(String(group.contentHash.prefix(12)))…") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(group.assetIDs, id: \.self) { assetID in
                    if let asset = store.assetsByID[assetID] {
                        HStack {
                            AssetThumbnailView(asset: asset, allowsHoverPreview: false)
                                .frame(width: 44, height: 44)
                            NavigationLink(value: assetID) {
                                VStack(alignment: .leading) {
                                    Text(asset.originalFilename)
                                    Text("\(asset.importOrigin.displayName) · \(Formatters.bytes.string(fromByteCount: asset.fileSize))")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .buttonStyle(.plain)
                            Spacer()
                            ResidencyBadge(domain: asset.residency)
                            // Review workflow placeholder: keep/discard decisions
                            // arrive with the v1.5 duplicate-review pass.
                            Button("Keep") {}
                                .disabled(true)
                                .help("Duplicate resolution workflow lands in a later phase.")
                        }
                    }
                }
            }
            .padding(6)
        }
    }
}
