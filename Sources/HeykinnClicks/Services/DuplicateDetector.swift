import Foundation

/// Exact duplicate detection via content hash. Perceptual/near-duplicate
/// matching is a later phase and will layer on top of these groups.
enum DuplicateDetector {
    static func groups(in assets: [Asset]) -> [DuplicateGroup] {
        var byHash: [String: [UUID]] = [:]
        for asset in assets {
            byHash[asset.contentHash, default: []].append(asset.id)
        }
        return byHash
            .filter { $0.value.count > 1 }
            .map { DuplicateGroup(contentHash: $0.key, assetIDs: $0.value) }
            .sorted { $0.count > $1.count }
    }

}
