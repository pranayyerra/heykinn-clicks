import Foundation

/// Where one source's photos are, against where its settings say they belong.
///
/// This has now been wrong twice, in opposite directions, and both mistakes are
/// worth keeping written down.
///
/// The first version counted every registered device and called anything a
/// device did not hold "owed" — which assumed every device should hold
/// everything, and would have reported a healthy archive as permanently behind.
///
/// The second over-corrected into a histogram of copies-per-photo with no
/// notion of *which* devices, which hid the thing that actually matters: a
/// source set to keep its photos on Archive Drive and the NAS, with nothing on
/// the NAS, is short — and a bare count of copies cannot say so.
///
/// The answer is that both questions are real and neither substitutes for the
/// other. **Photos** are measured against the source's copy count; **devices**
/// are measured against the source's named destinations. A device the source
/// never named is not behind, it is simply not part of this.
struct SourceCopyStatus {

    /// One device's standing for this source.
    struct Placement: Identifiable, Hashable {
        var targetID: UUID
        var name: String
        var kind: TargetKind
        var isReachable: Bool
        /// Named by the source. A named device holding nothing is a shortfall;
        /// an unnamed device holding something is a leftover.
        var isDestination: Bool
        /// Photos from this source the device holds and the app has confirmed.
        var held: Int
        /// Photos placed on it and not copied yet.
        var pending: Int
        /// Photos it is meant to hold and has neither got nor started.
        var owed: Int
        var owedBytes: Int64
        /// Photos whose copy here is the source's own files, counted where they
        /// sit rather than duplicated onto the same disk. Emptying the folder
        /// takes this device's copy with it.
        var archiveBacked: Int

        var id: UUID { targetID }
        /// A named device with nothing outstanding.
        var isSatisfied: Bool { isDestination && owed == 0 && pending == 0 }
        /// Holding copies of a source that no longer names it — after a
        /// retarget, or from before its settings changed. Not a fault, but the
        /// user should be able to see it rather than wonder where the space
        /// went.
        var isLeftover: Bool { !isDestination && held > 0 }
    }

    /// Photos attributed to the source, motion halves excluded — the same count
    /// the source's header shows, so the two cannot disagree.
    var total: Int
    /// Copies the source asks for.
    var desiredCopies: Int
    /// Photos by how many confirmed copies they have **on named devices**.
    var copiesHistogram: [Int: Int]
    /// Named devices first, then any leftovers still holding copies.
    var placements: [Placement]
    /// How many devices the source names. Fewer than `desiredCopies` is a
    /// configuration gap only the user can close.
    var destinationCount: Int
    /// Photos held on this Mac only so a named device that is not connected can
    /// be given them later. Not protection — the corridor doing its job, and
    /// saying so is what distinguishes it from being stuck.
    var waitingInCorridor: Int
    /// Photos this source's own files are the archive's only copy of.
    var loadBearing: Int

    var fullyProtected: Int {
        copiesHistogram.filter { $0.key >= desiredCopies }.values.reduce(0, +)
    }
    var partlyProtected: Int {
        copiesHistogram.filter { $0.key >= 1 && $0.key < desiredCopies }.values.reduce(0, +)
    }
    var unprotected: Int { copiesHistogram[0] ?? 0 }

    var destinations: [Placement] { placements.filter(\.isDestination) }
    var leftovers: [Placement] { placements.filter(\.isLeftover) }

    /// Nowhere named to put anything.
    var hasNoDestinations: Bool { destinationCount == 0 }
    /// Fewer devices named than copies wanted. Cannot be fixed by waiting for a
    /// sync — only by naming another device — so it reads differently.
    var hasTooFewDestinations: Bool {
        destinationCount > 0 && destinationCount < desiredCopies
    }

    static let empty = SourceCopyStatus(
        total: 0, desiredCopies: 2, copiesHistogram: [:], placements: [],
        destinationCount: 0, waitingInCorridor: 0, loadBearing: 0
    )
}
