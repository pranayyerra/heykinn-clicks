import Foundation

/// Somewhere sync files can live.
///
/// **The one seam in this layer, and deliberately the only one.** This codebase
/// has almost no protocols, because most of it has exactly one implementation
/// and an abstraction there would advertise a choice nobody has. Two things
/// earn this one:
///
/// 1. **More than one implementation is actually planned.** A drive today; a
///    share on the local network, or a folder in somebody's cloud storage
///    acting as a dumb courier, later. The whole point of
///    `MULTI_DEVICE_STATE.md` §8 is that a courier only ever moves opaque
///    files — so if this stays a file namespace and nothing more, every
///    courier is this one protocol and none of them can become load-bearing.
/// 2. **Damage is untestable otherwise.** The failures that matter here are a
///    drive pulled out mid-write, a volume mounted read-only, a file half
///    flushed. A test cannot pull out a drive; it can hand the code a store
///    that misbehaves on demand.
///
/// Kept small on purpose. Everything above it — where devices live, what a
/// segment is called, when to roll a new one — is ordinary code in `DriveSync`,
/// written once and shared by every transport, rather than something each one
/// gets to reinvent slightly differently.
///
/// It was four operations until checkpoints arrived, and the two that were added
/// each buy something a courier cannot fake: `size` so that deciding when to
/// write a checkpoint does not mean reading the whole log to measure it, and
/// `remove` so a checkpoint can retire the segments it covers. Without the
/// second, a drive synced for years only ever grows.
///
/// Paths are relative, `/`-separated, and always below the store's own root.
protocol SegmentStore {
    /// Names directly inside `directory`, in no guaranteed order. An absent
    /// directory is empty, not an error: a drive nobody has synced to yet is
    /// the ordinary first case.
    func list(_ directory: String) throws -> [String]

    /// The file's bytes, or nil when it is not there.
    func read(_ path: String) throws -> Data?

    /// How many bytes the file holds, without reading it. Nil when absent.
    func size(_ path: String) throws -> Int?

    /// Deletes a file, or a directory and everything in it. Absent is success:
    /// the caller's intent is that it be gone.
    ///
    /// **Only ever this device's own directory**, and only something a
    /// checkpoint has already made redundant. Nothing here deletes a photograph
    /// — this is the drive's sync bookkeeping, not the archive.
    func remove(_ path: String) throws

    /// Replaces a file's contents **atomically** — a reader sees the old bytes
    /// or the new ones, never a mixture. For the small whole-file documents:
    /// the manifest, a device's own record of itself.
    func writeAtomically(_ data: Data, to path: String) throws

    /// Adds to the end of a file, creating it if needed.
    ///
    /// Not atomic, and it does not need to be. Segments are append-only and
    /// every line carries its own checksum, so an interrupted append damages
    /// only the tail and a reader stops at the first bad line. Making this
    /// atomic would mean rewriting the whole segment for every sync.
    func append(_ data: Data, to path: String) throws
}

/// A `SegmentStore` backed by a real directory — a folder on a drive.
///
/// Everything here is ordinary file I/O. The interesting decisions are all in
/// the layer above; this exists to keep them there.
struct DirectorySegmentStore: SegmentStore {

    /// The `Sync` directory itself, not the drive root.
    let root: URL
    private let fileManager: FileManager

    init(root: URL, fileManager: FileManager = .default) {
        self.root = root
        self.fileManager = fileManager
    }

    private func url(for path: String) -> URL {
        path.split(separator: "/").reduce(root) { $0.appendingPathComponent(String($1)) }
    }

    func list(_ directory: String) throws -> [String] {
        let target = directory.isEmpty ? root : url(for: directory)
        guard fileManager.fileExists(atPath: target.path) else { return [] }
        return try fileManager.contentsOfDirectory(atPath: target.path)
            // Filesystems hand back `.DS_Store` and friends. Nothing here has
            // any business reading a file it did not write.
            .filter { !$0.hasPrefix(".") }
    }

    func read(_ path: String) throws -> Data? {
        let target = url(for: path)
        guard fileManager.fileExists(atPath: target.path) else { return nil }
        return try Data(contentsOf: target)
    }

    func size(_ path: String) throws -> Int? {
        let target = url(for: path)
        guard fileManager.fileExists(atPath: target.path) else { return nil }
        return (try fileManager.attributesOfItem(atPath: target.path)[.size] as? NSNumber)?.intValue
    }

    func remove(_ path: String) throws {
        let target = url(for: path)
        guard fileManager.fileExists(atPath: target.path) else { return }
        try fileManager.removeItem(at: target)
    }

    func writeAtomically(_ data: Data, to path: String) throws {
        let target = url(for: path)
        try fileManager.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try data.write(to: target, options: .atomic)
    }

    func append(_ data: Data, to path: String) throws {
        let target = url(for: path)
        try fileManager.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        guard fileManager.fileExists(atPath: target.path) else {
            try data.write(to: target, options: .atomic)
            return
        }
        let handle = try FileHandle(forWritingTo: target)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }
}
