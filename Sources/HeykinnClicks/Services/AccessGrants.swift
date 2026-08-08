import Foundation

/// What the user decided about a disk, remembered so they are not asked again.
///
/// The old behaviour stored one thing — a set of volume keys never to prompt
/// for — which answered "stop asking" and nothing else. Someone who chose
/// "scan it for Takeout archives" was asked the same question on every single
/// mount, because the *answer* was never written down, only the question's
/// absence. These are the answers.
enum VolumeDecision: String, Codable, CaseIterable, Hashable {
    /// Register it as managed Local storage the moment it appears.
    case manage
    /// Not a target, but sweep it for Google exports whenever it mounts.
    case scan
    /// Leave it alone entirely. The old "don't ask again for this drive".
    case ignore

    var displayName: String {
        switch self {
        case .manage: return "Used as storage for the archive"
        case .scan: return "Searched for Google downloads"
        case .ignore: return "Left alone"
        }
    }

    /// Written for the Access list, where the reader is deciding whether to
    /// take a grant back and needs to know what taking it back costs.
    var explanation: String {
        switch self {
        case .manage:
            return "Registered as one of the devices holding a copy. Forgetting the grant does not unregister it or delete anything."
        case .scan:
            return "Looked through for Google exports each time it is connected. Nothing on it is moved or changed."
        case .ignore:
            return "Not searched, not registered, and no longer asked about."
        }
    }

    var symbol: String {
        switch self {
        case .manage: return "externaldrive.fill.badge.checkmark"
        case .scan: return "magnifyingglass"
        case .ignore: return "minus.circle"
        }
    }
}

/// One disk the app has been given an answer about.
struct AccessGrant: Identifiable, Codable, Hashable {
    /// Volume UUID where the filesystem reports one, last mount path
    /// otherwise. Same key the prompt has always used, so grants written by
    /// the previous version keep matching the same disks.
    var volumeKey: String
    /// What it was called when the decision was made. Purely for the UI: a
    /// list of volume UUIDs is not something anybody can act on.
    var displayName: String
    var decision: VolumeDecision
    var decidedAt: Date
    /// Where it was mounted when the grant was made, so the Access list can
    /// name a place rather than only a disk.
    var lastKnownPath: String?
    /// Security-scoped bookmark to the volume root, base64 in preferences.
    /// Optional because a bookmark can fail to be created — and a decision
    /// remembered without one is still worth remembering.
    var bookmark: Data?

    var id: String { volumeKey }
}

/// Persists the answers, and re-acquires filesystem access on relaunch.
///
/// Two separate things get conflated when this goes wrong, so they are kept
/// apart here:
///
/// 1. **The app's own state** — what the user chose for a disk. That is these
///    grants, and this type owns it end to end.
/// 2. **macOS's permission** — whether the process may read the volume at all.
///    A bookmark is the app's lever on that, and this resolves one per grant
///    at launch. But the system's removable-volume grant is keyed to the code
///    signing identity, and an ad-hoc signature changes hash on every build,
///    so a development build *will* be re-prompted no matter what is stored
///    here. That is a signing problem and is documented as one; pretending a
///    bookmark fixes it would send someone looking in the wrong place.
@MainActor
final class AccessGrants: ObservableObject {

    @Published private(set) var grants: [AccessGrant] = []

    private let defaults: UserDefaults
    private static let storageKey = "volumeAccessGrants"
    /// Pre-existing key from the version that only remembered suppression.
    private static let legacyIgnoreKey = "ignoredVolumeKeys"

    /// Volumes whose bookmark this process is currently holding open. Balanced
    /// in `deinit`-equivalent teardown; the app holds one of these for its
    /// whole lifetime, so releasing per-call would defeat the point.
    private var accessing: [String: URL] = [:]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    // MARK: - Reading

    func grant(forKey key: String) -> AccessGrant? {
        grants.first { $0.volumeKey == key }
    }

    func decision(forKey key: String) -> VolumeDecision? {
        grant(forKey: key)?.decision
    }

    /// The key a volume is remembered under. One definition, so the prompt,
    /// the monitor, and the Access list cannot disagree about which disk a
    /// grant belongs to.
    static func key(forVolumeUUID uuid: String?, path: String) -> String {
        uuid ?? path
    }

    // MARK: - Writing

    /// Records a decision, replacing any earlier one for the same disk.
    ///
    /// `remember` is the checkbox: when it is off the decision still happens,
    /// it is simply not written down, and the disk is asked about again next
    /// time. That is the honest reading of an unchecked "remember this" — not
    /// a silent grant with a shorter lifetime.
    func record(
        decision: VolumeDecision,
        forVolumeUUID uuid: String?,
        path: String,
        displayName: String,
        remember: Bool = true
    ) {
        guard remember else { return }
        let key = Self.key(forVolumeUUID: uuid, path: path)
        let grant = AccessGrant(
            volumeKey: key,
            displayName: displayName,
            decision: decision,
            decidedAt: Date(),
            lastKnownPath: path,
            bookmark: Self.makeBookmark(forPath: path)
        )
        grants.removeAll { $0.volumeKey == key }
        grants.append(grant)
        persist()
    }

    /// Forgets one disk's decision. Deletes nothing on the disk and does not
    /// unregister a target — a grant is a record of an answer, and taking it
    /// back only means the question gets asked again.
    func revoke(_ key: String) {
        if let url = accessing.removeValue(forKey: key) {
            url.stopAccessingSecurityScopedResource()
        }
        grants.removeAll { $0.volumeKey == key }
        persist()
    }

    func revokeAll() {
        for (_, url) in accessing { url.stopAccessingSecurityScopedResource() }
        accessing.removeAll()
        grants.removeAll()
        persist()
    }

    /// Refreshes the display name and path of a grant whose disk has appeared
    /// at a new mount point. The decision and its date are untouched: this is
    /// the same answer about the same disk, just somewhere else.
    func noteSeen(key: String, displayName: String, path: String) {
        guard let index = grants.firstIndex(where: { $0.volumeKey == key }) else { return }
        var grant = grants[index]
        guard grant.lastKnownPath != path || grant.displayName != displayName else { return }
        grant.lastKnownPath = path
        grant.displayName = displayName
        // The old bookmark points at the old mount. Re-take it rather than
        // keeping one that will resolve stale on the next launch.
        grant.bookmark = Self.makeBookmark(forPath: path) ?? grant.bookmark
        grants[index] = grant
        persist()
    }

    // MARK: - Bookmarks

    /// Re-opens every stored bookmark. Called once at launch, before the first
    /// mount sweep, so a disk that is already attached is readable without the
    /// user doing anything.
    ///
    /// A bookmark that will not resolve is not an error worth surfacing: the
    /// disk is usually just not plugged in. It is dropped from the in-memory
    /// set and re-taken the next time that volume is seen.
    func resumeAccess() {
        for grant in grants {
            guard let data = grant.bookmark, accessing[grant.volumeKey] == nil else { continue }
            var stale = false
            guard let url = try? URL(
                resolvingBookmarkData: data,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            ) else { continue }
            guard url.startAccessingSecurityScopedResource() else { continue }
            accessing[grant.volumeKey] = url
        }
    }

    /// Best-effort. A volume that is not mounted, or one the process has no
    /// permission for yet, yields nil — and a grant without a bookmark is
    /// still a grant, so the caller does not treat this as a failure.
    private static func makeBookmark(forPath path: String) -> Data? {
        let url = URL(fileURLWithPath: path, isDirectory: true)
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        return try? url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    // MARK: - Persistence

    private func load() {
        if let data = defaults.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode([AccessGrant].self, from: data) {
            grants = decoded
        }

        // Carry forward the keys written by the version that could only
        // suppress. Those users said "don't ask about this drive" and meant
        // it; dropping the keys would start asking again, and the whole point
        // of this change is that an answer given once stands.
        if let legacy = defaults.stringArray(forKey: Self.legacyIgnoreKey), !legacy.isEmpty {
            for key in legacy where !grants.contains(where: { $0.volumeKey == key }) {
                grants.append(AccessGrant(
                    volumeKey: key,
                    displayName: (key as NSString).lastPathComponent,
                    decision: .ignore,
                    decidedAt: Date(),
                    lastKnownPath: key.hasPrefix("/") ? key : nil,
                    bookmark: nil
                ))
            }
            defaults.removeObject(forKey: Self.legacyIgnoreKey)
            persist()
        }
    }

    private func persist() {
        grants.sort { $0.decidedAt > $1.decidedAt }
        guard let data = try? JSONEncoder().encode(grants) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}
