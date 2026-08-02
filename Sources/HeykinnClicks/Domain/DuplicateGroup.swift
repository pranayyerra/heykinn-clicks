import Foundation

/// Exact-duplicate group: assets whose content hashes are identical.
/// Grouping is computed from the catalog; merging is never automatic.
struct DuplicateGroup: Identifiable, Hashable {
    var contentHash: String
    var assetIDs: [UUID]

    var id: String { contentHash }
    var count: Int { assetIDs.count }
}
