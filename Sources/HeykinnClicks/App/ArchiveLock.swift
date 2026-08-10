import Foundation

/// One running app per archive.
///
/// The App Store build and the Developer ID build deliberately share a
/// catalog — one archive however the app was installed. That is right for
/// somebody who owns one archive, and it means two copies of this app can now
/// be pointed at the same files, which anybody publishing both will do on
/// purpose.
///
/// SQLite would survive it. The app would not. Every screen is drawn from state
/// loaded into memory at launch and written back as whole rows: two instances
/// each hold their own copy, and the second to write wins without ever having
/// seen the first's changes. Nothing is corrupted in the database sense — it is
/// worse than that, because the catalog stays perfectly readable while quietly
/// describing an archive that no longer matches the disks.
///
/// `flock` rather than a file the app writes and deletes: the kernel releases it
/// when the process dies, however it dies. A lock file with a pid in it would
/// outlive a crash and leave somebody unable to open their own archive.
final class ArchiveLock {

    private let descriptor: Int32
    let url: URL

    static let fileName = ".heykinn-clicks.lock"

    /// Takes the lock, or nil when another process already holds it.
    ///
    /// Failing to *create* the file is deliberately not the same as failing to
    /// lock it: a directory that cannot be written to is a different problem
    /// with a different message, and it is not this type's to report. That case
    /// yields a lock that holds nothing, so a read-only or unusual location
    /// does not stop the app opening.
    init?(directory: URL) {
        self.url = directory.appendingPathComponent(Self.fileName)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        descriptor = open(url.path, O_CREAT | O_RDWR, 0o644)
        guard descriptor >= 0 else { return nil }

        // Non-blocking: the answer wanted here is "is somebody else in this
        // archive", not "wait until they leave".
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            return nil
        }
    }

    deinit {
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }

    /// Whether some *other* process holds the archive. Does not disturb a lock
    /// this process is already holding, because it takes and releases its own.
    static func isHeldByAnotherProcess(directory: URL) -> Bool {
        let path = directory.appendingPathComponent(fileName).path
        let descriptor = open(path, O_RDWR)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { return true }
        flock(descriptor, LOCK_UN)
        return false
    }
}
