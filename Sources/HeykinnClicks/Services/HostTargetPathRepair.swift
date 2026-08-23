import Foundation

/// Finds this device's own copy again after the archive directory has moved.
///
/// **The bug this exists for.** The archive migrates from the old
/// `Application Support` location into the app-group container, and
/// `ArchiveLocation.migrateIfNeeded` moves the whole directory — `LocalCopy`
/// included. What it does not move is the *path recorded for the host device
/// target*, which lives in the catalog that just moved and still names the old
/// location. The folder is right there, with its marker intact, and the app
/// looks for it where it used to be.
///
/// Nothing recovers from that on its own. The device reads "away" for ever,
/// while being the machine the app is running on; the photographs it holds stop
/// counting toward safety, and nothing new is ever copied to it. Found on a
/// real archive whose own device had been unreachable since the migration.
///
/// **Repointed only on the marker's word.** A folder is adopted because it
/// carries a marker naming this target, never because it sits where one would
/// expect — the same rule registration follows, and the reason invariant 13
/// exists. A path that merely looks right is how an archive ends up writing
/// into a stranger's directory.
enum HostTargetPathRepair {

    /// The new path for a host target whose recorded one has gone, or nil to
    /// leave it alone.
    ///
    /// - Parameters:
    ///   - target: the host-device target to check.
    ///   - archiveDirectory: where the archive lives *now*.
    ///   - markerAt: reads the marker sitting at a folder, if there is one.
    ///   - exists: whether a directory is there.
    static func repairedPath(
        for target: ReplicationTarget,
        archiveDirectory: URL,
        markerAt: (URL) -> TargetMarker?,
        exists: (URL) -> Bool
    ) -> String? {
        guard target.kind == .hostDevice else { return nil }
        // A path that still resolves is not broken, whatever else is true.
        if let configured = target.configuredPath, exists(URL(fileURLWithPath: configured)) {
            return nil
        }
        let candidate = archiveDirectory.appendingPathComponent(
            ReplicationTarget.hostCopyFolderName, isDirectory: true
        )
        guard exists(candidate) else { return nil }
        guard let marker = markerAt(candidate), marker.targetID == target.id else { return nil }
        // Already there and simply unreadable is a different problem, and not
        // one a rewrite of the same value would fix.
        guard candidate.path != target.configuredPath else { return nil }
        return candidate.path
    }
}
