import Foundation

/// Ordering that means the same thing in every language.
///
/// **The hazard this closes.** Swift's `<` on `String` compares by Unicode
/// canonical ordering, not by bytes. Rust's `str` comparison, Kotlin's
/// `String.compareTo` and C#'s ordinal comparison all order by code units
/// instead, and for anything outside ASCII the two disagree — `"é"` written
/// precomposed sorts one way under one rule and the other way under the other.
///
/// That is harmless in a UI and dangerous in a hash. `MerkleTree` sorts its
/// leaves before building, so the sort decides the tree's shape, which decides
/// the root. Two platforms using their own native ordering would build
/// different roots from identical content and conclude the archives had
/// diverged — every time, unfixably, with no bad bytes anywhere.
///
/// Bytewise over UTF-8 is the rule because it is the one every language can
/// express exactly. It matches what Swift already does for the ASCII keys in
/// use today, so adopting it changes no existing root.
enum ByteOrdering {

    /// Whether `lhs` sorts before `rhs`, comparing UTF-8 bytes.
    static func precedes(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf8.lexicographicallyPrecedes(rhs.utf8)
    }
}

extension Sequence where Element == String {
    /// Sorted by UTF-8 bytes. Use wherever the order is part of a recorded
    /// fact rather than part of a presentation.
    func sortedByBytes() -> [String] {
        sorted(by: ByteOrdering.precedes)
    }
}
