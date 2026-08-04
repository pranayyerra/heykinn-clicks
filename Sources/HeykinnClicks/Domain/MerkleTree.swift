import Foundation
import CryptoKit

/// A Merkle tree over the catalog's recorded content hashes, one per target.
///
/// Comparing two targets by root is a single comparison and no reads at all;
/// when the roots differ, descending the tree finds the assets responsible in
/// O(log n) comparisons instead of a sweep over everything. That is what
/// replaces re-reading every replica on a timer.
///
/// **What this proves.** It compares what the catalog *recorded*, so it finds
/// every divergence the catalog can see — a missing replica, a file replaced, a
/// copy that never completed, two targets holding different subsets. It cannot
/// see bit rot: a file whose bytes decayed while its recorded hash stayed put
/// leaves the root unchanged. Git has the same property, which is why
/// `git fsck` still reads every object. A matching root is never proof the
/// bytes are good.
///
/// Built rather than taken from a package: this is a hundred lines against
/// CryptoKit, and a dependency here would add supply-chain and version risk to
/// replace code smaller than the tests covering it.
struct MerkleTree: Equatable {

    /// One asset's contribution: its identity, and the hash the catalog holds
    /// for the copy on this target.
    struct Leaf: Equatable {
        var key: String
        var digest: String

        init(key: String, digest: String) {
            self.key = key
            self.digest = digest
        }
    }

    /// Sorted by key, so two targets holding the same content always build the
    /// same tree regardless of the order rows came out of the database.
    private(set) var keys: [String]
    /// `levels[0]` is the leaf hashes; each level above is the pairwise hash of
    /// the one below, up to a single root.
    ///
    /// Held as raw digests rather than hex strings. These trees are rebuilt on
    /// every catalog change, and formatting 32 bytes into a string per node
    /// cost seconds at archive scale — for text nothing ever reads.
    private(set) var levels: [[Data]]

    /// Hex only at the boundary, where a human or a log might see it.
    var root: String? {
        levels.last?.first.map { $0.map { String(format: "%02x", $0) }.joined() }
    }
    var isEmpty: Bool { keys.isEmpty }
    var leafCount: Int { keys.count }

    init(leaves: [Leaf]) {
        let sorted = leaves.sorted { $0.key < $1.key }
        keys = sorted.map(\.key)

        guard !sorted.isEmpty else {
            levels = []
            return
        }

        var level = sorted.map { Self.leafDigest(key: $0.key, digest: $0.digest) }
        var built = [level]
        while level.count > 1 {
            var next: [Data] = []
            next.reserveCapacity((level.count + 1) / 2)
            for index in stride(from: 0, to: level.count, by: 2) {
                // An odd node is carried up rather than paired with itself,
                // which would make two different shapes hash the same.
                if index + 1 < level.count {
                    next.append(Self.nodeDigest(level[index], level[index + 1]))
                } else {
                    next.append(level[index])
                }
            }
            built.append(next)
            level = next
        }
        levels = built
    }

    /// Whether the two targets hold the same recorded content. One comparison,
    /// no reads.
    func agrees(with other: MerkleTree) -> Bool {
        levels.last?.first == other.levels.last?.first && keys.count == other.keys.count
    }

    /// The assets responsible for a disagreement — the only ones worth reading.
    ///
    /// Where the two trees have the same shape, this descends and touches only
    /// the branches that differ. Where they do not — one target holds assets
    /// the other has never been given — the shapes cannot be compared node for
    /// node, so the keys are reconciled directly and the differing digests
    /// found among the keys they share.
    func divergentKeys(from other: MerkleTree) -> [String] {
        if agrees(with: other) { return [] }

        if keys == other.keys {
            return divergentLeafIndices(from: other).map { keys[$0] }.sorted()
        }

        let mine = Set(keys)
        let theirs = Set(other.keys)
        var result = Array(mine.symmetricDifference(theirs))

        let sharedDigests = Dictionary(uniqueKeysWithValues: zip(other.keys, other.levels.first ?? []))
        for (index, key) in keys.enumerated() where theirs.contains(key) {
            if let leaf = levels.first?[index], let counterpart = sharedDigests[key], leaf != counterpart {
                result.append(key)
            }
        }
        return result.sorted()
    }

    /// Descends both trees together, following only the subtrees whose hashes
    /// disagree. This is the part that makes divergence cheap to localise:
    /// a single changed asset costs one comparison per level, not one per asset.
    private func divergentLeafIndices(from other: MerkleTree) -> [Int] {
        guard let topLevel = levels.indices.last, topLevel == other.levels.indices.last else {
            return Array(keys.indices)
        }
        var frontier = [0]
        for level in stride(from: topLevel, through: 1, by: -1) {
            var next: [Int] = []
            for index in frontier {
                guard index < levels[level].count, index < other.levels[level].count else {
                    next.append(contentsOf: [index * 2, index * 2 + 1])
                    continue
                }
                guard levels[level][index] != other.levels[level][index] else { continue }
                for child in [index * 2, index * 2 + 1] where child < levels[level - 1].count {
                    next.append(child)
                }
            }
            frontier = next
            if frontier.isEmpty { return [] }
        }
        return frontier.filter { index in
            index < levels[0].count && index < other.levels[0].count
                ? levels[0][index] != other.levels[0][index]
                : true
        }
    }

    private static func leafDigest(key: String, digest: String) -> Data {
        var input = Data("leaf:".utf8)
        input.append(contentsOf: key.utf8)
        input.append(0x1f)
        input.append(contentsOf: digest.utf8)
        return Data(SHA256.hash(data: input))
    }

    private static func nodeDigest(_ left: Data, _ right: Data) -> Data {
        var input = Data(capacity: left.count + right.count + 1)
        input.append(contentsOf: [0x01])
        input.append(left)
        input.append(right)
        return Data(SHA256.hash(data: input))
    }
}
