import Foundation

/// Security-scoped bookmarks to the devices this archive is registered against.
///
/// Registered targets are found today by reading a marker file at the root of
/// every mounted volume. That is the right mechanism for an app that may look:
/// it survives a rename, a remount and a different mount path, and it needs
/// nothing remembered about where a disk was last time. **Under the App Store
/// sandbox an app may not look.** Reading the root of a volume nobody handed it
/// is exactly what the sandbox exists to prevent, so a bookmark — a token the
/// user's own choice produced — becomes the only way back to a drive.
///
/// So both mechanisms are kept, doing different jobs rather than competing:
/// the marker says *which* device this is, and the bookmark is permission to
/// look at all. Unsandboxed, the marker sweep finds everything and bookmarks
/// are a fast path. Sandboxed, the bookmark is the only path and the marker
/// confirms what it opened.
///
/// **Deliberately not stored in the catalog.** Snapshots are written to the
/// drives and can be restored onto a different Mac, and a bookmark is meaningful
/// only to the machine — and the code identity — that made it. Carrying one
/// across would be a pointer to nothing, presented as a way to reach a drive.
/// This is per-machine state and lives in preferences with the other
/// per-machine state.
@MainActor
final class TargetBookmarks: ObservableObject {

    private let defaults: UserDefaults
    private static let storageKey = "targetBookmarks"

    /// Bookmark data by target id, base64 through JSON in preferences.
    private var bookmarks: [UUID: Data] = [:]
    /// Targets whose security scope this process is currently holding open.
    /// The app holds these for its whole lifetime: releasing per call would
    /// mean re-acquiring on every read, which is the thing being avoided.
    private var accessing: [UUID: URL] = [:]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    /// Whether this process is sandboxed, which decides what kind of bookmark
    /// can be made at all.
    ///
    /// `.withSecurityScope` requires the sandbox entitlement; asking for one
    /// without it fails, and falling back to a plain bookmark keeps the
    /// unsandboxed build working rather than silently storing nothing.
    nonisolated static var isSandboxed: Bool {
        ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
    }

    private static var bookmarkOptions: URL.BookmarkCreationOptions {
        isSandboxed ? [.withSecurityScope] : []
    }

    private static var resolutionOptions: URL.BookmarkResolutionOptions {
        isSandboxed ? [.withSecurityScope] : []
    }

    // MARK: - Recording

    /// Takes a bookmark for a target the user has just pointed at.
    ///
    /// Best-effort by design. A bookmark that cannot be made is not a failed
    /// registration — unsandboxed the app can reach the volume without one, and
    /// the marker sweep will find it again regardless.
    @discardableResult
    func record(targetID: UUID, path: String) -> Bool {
        let url = URL(fileURLWithPath: path, isDirectory: true)
        guard FileManager.default.fileExists(atPath: path) else { return false }
        guard let data = try? url.bookmarkData(
            options: Self.bookmarkOptions,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) else { return false }
        bookmarks[targetID] = data
        persist()
        return true
    }

    /// Drops a target's bookmark and releases its scope. Called when a device is
    /// unregistered: keeping permission to a drive the archive no longer claims
    /// would be holding access nobody asked for.
    func forget(targetID: UUID) {
        if let url = accessing.removeValue(forKey: targetID) {
            url.stopAccessingSecurityScopedResource()
        }
        bookmarks.removeValue(forKey: targetID)
        persist()
    }

    func hasBookmark(for targetID: UUID) -> Bool { bookmarks[targetID] != nil }

    // MARK: - Resolving

    /// Where a target is right now, according to its bookmark, or nil when the
    /// disk is not attached.
    ///
    /// A bookmark that resolves stale is re-taken against the path it resolved
    /// to: the disk is present under a new mount, which is the ordinary case
    /// for removable storage and not a problem to report.
    func resolvedURL(for targetID: UUID) -> URL? {
        if let open = accessing[targetID] { return open }
        guard let data = bookmarks[targetID] else { return nil }

        var stale = false
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: Self.resolutionOptions,
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        ) else { return nil }

        // Unsandboxed there is no scope to start; the call answers false and
        // the URL is usable anyway, so the result is deliberately not gating.
        if Self.isSandboxed, !url.startAccessingSecurityScopedResource() { return nil }
        accessing[targetID] = url

        if stale { record(targetID: targetID, path: url.path) }
        return url
    }

    /// Where each of these devices is, for the ones with a resolvable
    /// bookmark. Handed to the monitor's rescan, which decides what to do with
    /// it — this type knows about permission and nothing about targets.
    func resolvedURLs(forTargets ids: [UUID]) -> [UUID: URL] {
        ids.reduce(into: [:]) { found, id in
            if let url = resolvedURL(for: id) { found[id] = url }
        }
    }

    /// Re-opens every stored bookmark, once, before the first mount sweep — so
    /// a disk already attached at launch is reachable without the user doing
    /// anything. Absent disks fail quietly: not being plugged in is not an
    /// error worth a message.
    func resumeAccess() {
        for targetID in bookmarks.keys where accessing[targetID] == nil {
            _ = resolvedURL(for: targetID)
        }
    }

    /// Releases every scope this process is holding. For teardown and for tests,
    /// which must not leave scopes open across cases.
    func releaseAll() {
        for (_, url) in accessing { url.stopAccessingSecurityScopedResource() }
        accessing.removeAll()
    }

    // MARK: - Persistence

    private func load() {
        guard let data = defaults.data(forKey: Self.storageKey),
              let decoded = try? JSONDecoder().decode([String: Data].self, from: data)
        else { return }
        bookmarks = decoded.reduce(into: [:]) { result, pair in
            guard let id = UUID(uuidString: pair.key) else { return }
            result[id] = pair.value
        }
    }

    private func persist() {
        let encodable = bookmarks.reduce(into: [String: Data]()) { $0[$1.key.uuidString] = $1.value }
        guard let data = try? JSONEncoder().encode(encodable) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}
