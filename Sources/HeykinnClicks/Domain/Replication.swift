import Foundation

/// State of one asset's replica on one managed drive.
enum ReplicaFileState: String, Codable, Hashable {
    /// Expected on this drive, not yet copied.
    case pending
    /// Copy in progress (or interrupted; safe to retry).
    case copying
    /// File exists and last verification matched the catalog hash.
    case present
    /// Catalog thinks it should be present but a sync failed or was interrupted.
    case stale
    /// Expected removed (e.g. after migration cleanup) or confirmed absent.
    case missing
    /// File exists but its content no longer matches the catalog hash.
    case drift

    var displayName: String {
        switch self {
        case .pending: return "Pending"
        case .copying: return "Copying"
        case .present: return "Present"
        case .stale: return "Stale"
        case .missing: return "Missing"
        case .drift: return "Changed on disk"
        }
    }
}

struct TargetReplicaState: Hashable, Identifiable {
    var assetID: UUID
    var targetID: UUID
    var state: ReplicaFileState
    /// Path relative to the drive's replica root.
    var relativePath: String?
    var lastVerifiedAt: Date?

    /// What the file looked like the last time the app knew it was right: the
    /// size and modification date observed when the copy was written or last
    /// verified.
    ///
    /// The third leg of the aimed-reads triad. Comparing Merkle roots cannot
    /// see an in-place edit — no hash the catalog holds changed, so the trees
    /// go on agreeing — and stat-ing anchors only sees whole directories move.
    /// A file edited under an intact path is invisible to both, and would wait
    /// for the rot patrol to reach it. Keeping the observed stat here is what
    /// lets a connect aim the expensive read at the few files that moved.
    ///
    /// Nil until the first observation. A baseline nobody recorded is not
    /// evidence of anything, so the first pass establishes it and claims
    /// nothing.
    var observedSize: Int64?
    var observedModifiedAt: Date?

    var id: String { "\(assetID.uuidString)/\(targetID.uuidString)" }
}

/// Which managed targets a file being read might already be sitting on.
///
/// Every import path has to answer one question per file: are these bytes
/// already on a drive the app manages? If they are, that file *is* that drive's
/// copy and staging a second one duplicates the archive for nothing.
///
/// The answer used to be computed once per batch, before the loop, from a
/// single candidate target — and the folder importer picked that candidate by
/// looking at whichever file the sweep happened to return first. So a batch
/// spanning two mounted drives could only ever recognise one of them, and which
/// one depended on the order the file picker returned the roots in. Selecting
/// the same two folders in the other order gave a different archive. Holding
/// every reachable target and resolving per file removes the ordering from the
/// answer entirely.
struct TargetPlacement {
    struct Mount: Hashable {
        var targetID: UUID
        /// Standardised, without a trailing slash.
        var path: String
    }

    /// One entry per target, as registered.
    private(set) var mounts: [Mount]

    /// What `resolve` actually matches against: longest path first, so the
    /// most specific target wins when one is nested inside another, and with
    /// every spelling of each mount that the rest of the system might hand us.
    ///
    /// One directory has more than one name. A target records where it lives
    /// as `/var/…`, and `FileManager`'s enumerator hands back files under it
    /// as `/private/var/…` — the same place through the same symlink, spelled
    /// two ways, and a prefix test cannot see through the difference. Worse,
    /// the obvious fix is backwards: `resolvingSymlinksInPath` *removes* a
    /// leading `/private`, so normalising both sides with it leaves the file
    /// paths untouched and the mismatch intact.
    ///
    /// So the spellings are worked out once, here, from at most a couple of
    /// targets. Normalising each *file* instead would put a filesystem call in
    /// a loop that runs once per photo, to answer a question that does not
    /// change between them.
    private let matchPaths: [(targetID: UUID, path: String)]

    init(mounts: [Mount] = []) {
        self.mounts = mounts
        var candidates: [(targetID: UUID, path: String)] = []
        for mount in mounts {
            for spelling in Self.spellings(of: mount.path) {
                candidates.append((mount.targetID, spelling))
            }
        }
        matchPaths = candidates.sorted { $0.path.count > $1.path.count }
    }

    /// Every name this directory answers to, deduplicated.
    private static func spellings(of path: String) -> [String] {
        var forms = [path]
        let url = URL(fileURLWithPath: path, isDirectory: true)
        for variant in [url.resolvingSymlinksInPath().path, url.standardizedFileURL.path] {
            if !forms.contains(variant) { forms.append(variant) }
        }
        // The fully resolved form: what the enumerator reports, and the one
        // neither URL API produces.
        if let raw = realpath(path, nil) {
            let resolved = String(cString: raw)
            free(raw)
            if !forms.contains(resolved) { forms.append(resolved) }
        }
        return forms
    }

    init(reachablePaths: [UUID: URL]) {
        self.init(mounts: reachablePaths.map {
            Mount(targetID: $0.key, path: $0.value.path)
        })
    }

    /// One target, for callers that genuinely have only one — a Takeout
    /// workspace lives on exactly the drive that holds the export.
    init(targetID: UUID, mountPath: String) {
        self.init(mounts: [Mount(targetID: targetID, path: mountPath)])
    }

    var isEmpty: Bool { mounts.isEmpty }

    /// Whether this path is one of the targets' own roots, or sits inside one.
    /// Unlike `resolve`, true for the root itself — a folder somebody imported
    /// from can be the whole drive.
    func contains(_ url: URL) -> Bool {
        let path = url.path
        return matchPaths.contains { path == $0.path || path.hasPrefix($0.path + "/") }
    }

    /// The target holding this file, and where the file sits relative to that
    /// target's root — the form a `volume:` replica records.
    func resolve(_ url: URL) -> (targetID: UUID, volumeRelativePath: String)? {
        let path = url.path
        for candidate in matchPaths where path.hasPrefix(candidate.path + "/") {
            return (candidate.targetID, String(path.dropFirst(candidate.path.count + 1)))
        }
        return nil
    }

    /// The replica a file resolved onto this placement stands for.
    ///
    /// `present` and verified now is what the caller actually knows: it has
    /// just read this file end to end to hash it, so the claim is no weaker
    /// than the one a fresh copy makes about itself.
    func archiveBackedReplica(
        for assetID: UUID,
        at url: URL,
        now: Date = Date()
    ) -> TargetReplicaState? {
        guard let resolved = resolve(url) else { return nil }
        return TargetReplicaState(
            assetID: assetID,
            targetID: resolved.targetID,
            state: .present,
            relativePath: ReplicationService.volumeBackedPrefix + resolved.volumeRelativePath,
            lastVerifiedAt: now
        )
    }
}

/// What one drive actually holds, tallied in a single pass over replica state.
/// The UI draws a drive's share of the archive on every redraw; recomputing it
/// by filtering the whole replica table each time does not survive a catalog
/// with hundreds of thousands of rows.
struct DriveContentBreakdown: Equatable {
    var present = 0
    /// Expected on the drive but not there yet: queued, mid-copy, or interrupted.
    var pending = 0
    var drift = 0
    var missing = 0
    var presentBytes: Int64 = 0

    /// The same tallies counted in photos rather than files: a Live Photo is
    /// one photo, though it is a still *and* a movie on disk. Files are what
    /// gets copied and verified; photos are what the user thinks they own, and
    /// showing one number where the other is meant reads as a contradiction.
    var presentPhotos = 0
    var pendingPhotos = 0
    var driftPhotos = 0

    /// Held, but never once read back and matched.
    ///
    /// A count the drive screen had no way to show, which let *held* and
    /// *proven* be the same number on screen when they are very different
    /// facts. A drive holding a whole archive of which 90 have ever been verified
    /// is not the drive it looks like beside one where all of them have.
    var neverChecked = 0
    var neverCheckedPhotos = 0

    /// Everything the target is meant to end up holding.
    var expected: Int { present + pending + drift }
    var expectedPhotos: Int { presentPhotos + pendingPhotos + driftPhotos }
}

enum ReplicationAction: String, Codable, Hashable {
    case copy
    case verify
    case remove
}

enum ReplicationTaskState: String, Codable, Hashable {
    case queued
    case inProgress
    case completed
    case failed
}

/// How many copies must be read before agreement between them can be claimed.
///
/// Comparing takes two, whatever a source asks for: a lone copy under a
/// one-copy setting is exactly as protected as it was asked to be and still has
/// nothing to be compared against, so a check over it would confirm nothing.
///
/// A `LocalRedundancyPolicy` type used to sit here, carrying one copy count for
/// the whole archive. It is gone: the number belongs to each source, which
/// names its own devices and its own copy count, and a single global figure
/// could only ever contradict them. What survived is this one piece of
/// arithmetic, which is about comparison rather than policy.
func copiesNeededToCompare(forCopies desiredCopies: Int) -> Int {
    max(desiredCopies, 2)
}

/// What a drive's pending backlog actually consists of. A bare task count
/// hides the difference between "copy 3 files" and "re-read 120 GB", which are
/// wildly different asks of the user's time and drive.
struct BacklogSummary: Equatable {
    var copyCount: Int = 0
    var verifyCount: Int = 0
    var removeCount: Int = 0
    /// Bytes that must be read or written to drain the backlog.
    var estimatedBytes: Int64 = 0

    var total: Int { copyCount + verifyCount + removeCount }
    var isEmpty: Bool { total == 0 }

    /// Human description of the work, heaviest action first.
    var description: String {
        var parts: [String] = []
        if copyCount > 0 { parts.append("\(copyCount) to copy") }
        if verifyCount > 0 { parts.append("\(verifyCount) to check") }
        if removeCount > 0 { parts.append("\(removeCount) to remove") }
        guard !parts.isEmpty else { return "nothing pending" }
        let work = parts.joined(separator: ", ")
        guard estimatedBytes > 0 else { return work }
        return "\(work) (~\(ByteCountFormatter.string(fromByteCount: estimatedBytes, countStyle: .file)))"
    }
}

/// Limits how much verification a single sweep queues. Re-hashing a whole
/// archive is legitimate work but must never be dumped on the drive as one
/// enormous burst; sweeps take the stalest replicas first and stop at a budget.
struct VerificationBudget {
    var maxFiles: Int
    var maxBytes: Int64
    /// No single file may take more than this share of one run.
    ///
    /// Without it, one 10 GB video consumes an entire patrol ration and every
    /// other file waits for the next run half an hour later — and large files
    /// are exactly what should not be able to monopolise the budget, being
    /// also the slowest to read. A file over the cap is skipped rather than
    /// blocking the queue behind it; an explicit sweep still reaches it.
    var maxBytesPerFile: Int64 = .max

    static let sweep = VerificationBudget(maxFiles: 500, maxBytes: 4 * 1024 * 1024 * 1024)
    static let unlimited = VerificationBudget(maxFiles: .max, maxBytes: .max)
    /// The background patrol's ration. Small enough that a run finishes in
    /// seconds and is never what the user notices about the app — the point is
    /// that reading eventually happens, not that it happens quickly.
    static let patrol = VerificationBudget(
        maxFiles: 40,
        maxBytes: 256 * 1024 * 1024,
        maxBytesPerFile: 64 * 1024 * 1024
    )
}

/// Live progress of an in-flight sync against one drive. Present only while a
/// sync runs; cancellation or disconnect simply leaves unprocessed tasks
/// queued, so resuming is just running sync again.
struct SyncProgress: Equatable {
    var targetID: UUID
    var targetName: String
    var totalTasks: Int
    var completedTasks: Int
    var failedTasks: Int
    var currentItem: String?
    /// What is being done to it. A queue of re-reads reported itself as
    /// "Syncing IMG_3636.HEIC", which reads as copying — the one thing a
    /// verification never does, and the thing somebody watching a drive they
    /// were about to unplug most wants to know it is not doing.
    var currentAction: ReplicationAction?

    /// The verb for what is happening, in the present continuous.
    var currentVerb: String {
        switch currentAction {
        case .verify: return "Checking"
        case .remove: return "Removing"
        case .copy, .none: return "Copying"
        }
    }

    var fractionComplete: Double {
        totalTasks == 0 ? 0 : Double(completedTasks + failedTasks) / Double(totalTasks)
    }
}

/// One unit of the per-drive replication backlog. Queued whenever the drive is
/// absent or busy; processed serially when the drive is connected.
struct ReplicationTask: Identifiable, Hashable {
    let id: UUID
    var assetID: UUID
    var targetID: UUID
    var action: ReplicationAction
    var state: ReplicationTaskState
    var queuedAt: Date
    var completedAt: Date?
    var errorMessage: String?
}
