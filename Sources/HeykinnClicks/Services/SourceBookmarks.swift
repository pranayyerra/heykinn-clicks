import Foundation

/// Per-machine permission to return to folders the user selected as sources.
///
/// A Takeout search and a Takeout import are deliberately separate actions:
/// the search records what it finds, then the user chooses which parts to
/// import. In an App Store sandbox the Powerbox extension attached to the file
/// panel URL does not survive that gap. Keeping the path in the catalog is not
/// permission to read it later; a security-scoped bookmark is.
///
/// These bookmarks stay in preferences rather than the catalog for the same
/// reason target bookmarks do: a catalog snapshot can move to another Mac,
/// while a bookmark is meaningful only on the Mac and under the signing
/// identity that created it.
@MainActor
final class SourceBookmarks {

    private let defaults: UserDefaults
    private static let storageKey = "sourceBookmarks"

    /// Bookmark data keyed by the normalized root the user chose.
    private var bookmarks: [String: Data] = [:]
    /// Resolved roots whose security scopes remain open for this process.
    private var accessing: [String: URL] = [:]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    /// Records and immediately reopens a selected root.
    ///
    /// Reopening while the file-panel lease is still alive proves that the
    /// bookmark can carry the later import. In the sandbox, a bookmark that
    /// cannot be resumed is a failed selection rather than a best-effort hint:
    /// discovery would otherwise succeed and the later Import button would
    /// silently see an empty directory.
    @discardableResult
    func record(path: String) -> Bool {
        let key = Self.key(for: path)
        let url = URL(fileURLWithPath: key, isDirectory: true)
        guard FileManager.default.fileExists(atPath: key) else { return false }
        guard let data = try? url.bookmarkData(
            options: TargetBookmarks.isSandboxed ? [.withSecurityScope] : [],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) else { return false }

        bookmarks[key] = data
        persist()

        if accessing[key] != nil { return true }
        guard resolveAndHold(key: key, data: data) != nil else {
            bookmarks.removeValue(forKey: key)
            persist()
            return false
        }
        return true
    }

    func hasBookmark(forPath path: String) -> Bool {
        bookmarks[Self.key(for: path)] != nil
    }

    /// Reopens every selected source at launch so a discovered export can be
    /// imported without asking for the same folder again.
    func resumeAccess() {
        for (key, data) in bookmarks where accessing[key] == nil {
            _ = resolveAndHold(key: key, data: data)
        }
    }

    /// Whether an open selected root contains this path. Primarily useful for
    /// diagnostics and regression tests; ordinary callers can simply read the
    /// path once `resumeAccess` has run.
    func grantsAccess(to path: String) -> Bool {
        let wanted = URL(fileURLWithPath: path).standardizedFileURL.path
        return accessing.values.contains { root in
            let base = root.standardizedFileURL.path
            return wanted == base || wanted.hasPrefix(base + "/")
        }
    }

    func releaseAll() {
        for (_, url) in accessing where TargetBookmarks.isSandboxed {
            url.stopAccessingSecurityScopedResource()
        }
        accessing.removeAll()
    }

    private func resolveAndHold(key: String, data: Data) -> URL? {
        var stale = false
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: TargetBookmarks.isSandboxed ? [.withSecurityScope] : [],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        ) else { return nil }
        if TargetBookmarks.isSandboxed,
           !url.startAccessingSecurityScopedResource() { return nil }
        accessing[key] = url

        if stale,
           let refreshed = try? url.bookmarkData(
               options: TargetBookmarks.isSandboxed ? [.withSecurityScope] : [],
               includingResourceValuesForKeys: nil,
               relativeTo: nil
           ) {
            bookmarks[key] = refreshed
            persist()
        }
        return url
    }

    private static func key(for path: String) -> String {
        URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.path
    }

    private func load() {
        guard let data = defaults.data(forKey: Self.storageKey),
              let decoded = try? JSONDecoder().decode([String: Data].self, from: data)
        else { return }
        bookmarks = decoded
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(bookmarks) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}
