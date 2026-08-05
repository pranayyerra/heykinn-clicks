import Foundation

struct ImportBatch: Identifiable, Hashable {
    let id: UUID
    /// Where this import came from, as something to show a person.
    ///
    /// Named `sourcePath`, and it is one for a folder import — but three of
    /// the four things that write it put a label here instead: "Takeout export
    /// 20260710T081521Z-2 (3 parts)", "Recovered import (Google Takeout)". The
    /// name promises a path and the values are sometimes prose, which is a trap
    /// for anything that reads it: a screen listing "folders you have added"
    /// took every batch at its word and showed somebody seven Takeout imports
    /// as folders they had chosen, with no paths, because there were none.
    var sourcePath: String
    var startedAt: Date
    var completedAt: Date?
    var importedCount: Int
    var duplicateCount: Int
    var failedCount: Int
    /// What kind of import this was. Recorded rather than guessed from the
    /// description, because the description is free text and a screen that
    /// pattern-matches prose to decide what something is will be wrong the
    /// first time the wording changes.
    var origin: ImportOrigin?

    /// Whether `sourcePath` is a place on disk, as opposed to a label. Only a
    /// real path is worth showing as one, or offering to open.
    var isFilesystemPath: Bool { sourcePath.hasPrefix("/") }

    /// True for imports somebody performed by pointing at a folder — the ones
    /// "folders you have added" means.
    var isFolderImport: Bool { origin?.isFolderLike == true }
}

/// What one file looked like the last time a sweep read it, and what it hashed
/// to.
///
/// Pointing the app at a folder again is a thing people do — to check it took,
/// to pick up what has been added since, or because the drive is being swept to
/// find content it already holds. Every one of those re-reads every byte of
/// every file to arrive at hashes it worked out before, on a folder that may be
/// hundreds of gigabytes.
///
/// Size and modification date are the same evidence `ReplicaStatGate` uses to
/// decide whether a replica needs re-reading, applied to the other side of the
/// archive. Neither proves the bytes are unchanged — a file rewritten with the
/// same length inside the timestamp's resolution would slip through — so the
/// memo is only ever allowed to skip work for content the catalog *already
/// has*. Nothing new enters the archive on the strength of a `stat`.
struct ScanMemoEntry: Hashable {
    var path: String
    var size: Int64
    var modifiedAt: Date
    var contentHash: String
    var seenAt: Date

    func matches(_ observation: ReplicaStatGate.Observation) -> Bool {
        size == observation.size
            && abs(modifiedAt.timeIntervalSince(observation.modifiedAt))
                < ReplicaStatGate.modificationTolerance
    }
}
