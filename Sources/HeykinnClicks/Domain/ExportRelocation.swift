import Foundation

/// Moving an export into the app's own folder, on the drive it already sits on.
///
/// Same volume, so every move is a rename: instant, and it copies nothing. The
/// point is not to save space or to tidy up — it is that an export kept
/// permanently, as the document the archive is re-read from, should live
/// somewhere the app is responsible for rather than wherever it was filed the
/// day it was downloaded.
///
/// Planned before it is done, and shown before it is agreed to, because it
/// rewrites paths the user chose. Nothing here touches the disk.
struct ExportRelocation: Equatable, Identifiable {

    /// One plan per export per drive, which is also how a sheet identifies it.
    var id: String { "\(setID)|\(targetID.uuidString)" }

    /// One file, and where it would go.
    struct Move: Equatable, Identifiable {
        var archiveID: UUID
        var displayName: String
        var from: String
        var to: String
        var sizeBytes: Int64
        var id: UUID { archiveID }
    }

    var setID: String
    var targetID: UUID
    var driveName: String
    /// Where every one of them is going, so the destination can be named once.
    var destinationDirectory: String
    var moves: [Move]
    /// Files left alone because something is already at their destination.
    /// Never overwritten: two files with one name is a question the app cannot
    /// answer by guessing.
    var blocked: [String]
    /// How many recorded copies name the old location inside themselves and
    /// would have to be rewritten with the move.
    ///
    /// The reason this is on the plan rather than hidden in the doing: a photo
    /// counted inside a zip records that zip's path, so moving the zip without
    /// rewriting them orphans every one of those copies — 6,482 of them on a
    /// real archive, all reading as present on a drive at a path with nothing
    /// there. It is the largest thing this operation does and the least
    /// visible, so it is stated.
    var replicaPathsToRewrite: Int
    var bytes: Int64

    var isEmpty: Bool { moves.isEmpty }

    /// Where the app keeps exports it has been made responsible for.
    ///
    /// Deliberately not `ExportPartRelay`'s directory. That one is a waiting
    /// room for a part in transit — `ExportSetLayout.home` excludes it by name,
    /// on the reasoning that the first delivery must not decide the layout for
    /// every delivery after it. This is the opposite: a place chosen on
    /// purpose, for a whole export, which is exactly what a home is.
    static func destinationDirectory(forSet setID: String, onMount mountURL: URL) -> URL {
        mountURL
            .appendingPathComponent(ReplicationTarget.appFolderName, isDirectory: true)
            .appendingPathComponent("Exports", isDirectory: true)
            .appendingPathComponent(setID, isDirectory: true)
    }

    /// What moving this export on this drive would involve.
    ///
    /// - Parameter occupied: paths that already exist on disk at a destination,
    ///   supplied by the caller so the planner stays pure and testable.
    static func plan(
        setID: String,
        target: ReplicationTarget,
        mountURL: URL,
        archives: [TakeoutArchive],
        zipMemberReplicasByDirectory: [String: Int],
        occupied: (String) -> Bool
    ) -> ExportRelocation {
        let destination = destinationDirectory(forSet: setID, onMount: mountURL)
        let prefix = mountURL.path.hasSuffix("/") ? mountURL.path : mountURL.path + "/"

        var moves: [Move] = []
        var blocked: [String] = []
        var directoriesLeaving: Set<String> = []

        for archive in archives where archive.exportSetID == setID
            && archive.targetID == target.id
            && archive.holdsBytes
            && archive.path.hasPrefix(prefix)
        {
            let name = (archive.path as NSString).lastPathComponent
            let to = destination.appendingPathComponent(name).path
            // Already where it is going. Not a move and not a refusal — there
            // is simply nothing to do, and reporting it either way would make
            // a finished job look unfinished.
            if archive.path == to { continue }
            guard !occupied(to) else {
                blocked.append(name)
                continue
            }
            let directory = (archive.path as NSString).deletingLastPathComponent
            directoriesLeaving.insert(String(directory.dropFirst(prefix.count)))
            moves.append(Move(
                archiveID: archive.id,
                displayName: archive.displayName,
                from: archive.path,
                to: to,
                sizeBytes: archive.sizeBytes
            ))
        }

        let rewrites = directoriesLeaving.reduce(0) { $0 + (zipMemberReplicasByDirectory[$1] ?? 0) }

        return ExportRelocation(
            setID: setID,
            targetID: target.id,
            driveName: target.name,
            destinationDirectory: destination.path,
            moves: moves.sorted { $0.displayName < $1.displayName },
            blocked: blocked.sorted(),
            replicaPathsToRewrite: rewrites,
            bytes: moves.reduce(0) { $0 + $1.sizeBytes }
        )
    }

    /// The mount-relative directory a moved file came from, and the one it is
    /// going to — what a recorded copy naming the old place has to be rewritten
    /// between.
    static func relativeDirectory(of path: String, onMount mountURL: URL) -> String? {
        let prefix = mountURL.path.hasSuffix("/") ? mountURL.path : mountURL.path + "/"
        guard path.hasPrefix(prefix) else { return nil }
        let directory = (path as NSString).deletingLastPathComponent
        guard directory.hasPrefix(prefix) else { return nil }
        return String(directory.dropFirst(prefix.count))
    }
}
