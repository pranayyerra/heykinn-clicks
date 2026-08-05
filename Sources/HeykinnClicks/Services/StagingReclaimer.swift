import Foundation

/// Decides which staged files the archive no longer needs to keep.
///
/// Staging is described everywhere in this app as transit — the place content
/// waits until a target holds it. It was never actually emptied. `StagingStore`
/// has had a `remove` since it was written and nothing has ever called it, so
/// every photo imported from anywhere the app does not manage left a permanent
/// second copy on the boot disk, still there long after both drives held
/// verified copies of it. On an archive of any size that is the largest single
/// waste in the system, and it is invisible: the Drives screen reports the
/// number and offers nothing to do about it.
///
/// The bar for releasing one is the bar the rest of the app already uses for
/// saying an asset is safe, and not a weaker one invented here: the redundancy
/// policy is satisfied, every copy counted towards it was read back and matched,
/// and none of those reads is old enough to have gone stale. That is
/// `ProtectionEvaluator`'s `.fullyReplicated`, so this asks it rather than
/// reimplementing the question — a second definition of "safe" that drifted
/// from the first is exactly how a cleanup deletes something it should not.
enum StagingReclaimer {

    struct Plan: Equatable {
        /// Asset ID → the staging path that can go.
        var releasable: [UUID: String] = [:]
        /// Total bytes those files occupy, as the catalog records them.
        var bytes: Int64 = 0

        var isEmpty: Bool { releasable.isEmpty }
    }

    /// What can be released right now.
    ///
    /// `protectionStates` is passed in rather than recomputed: the store keeps
    /// it, the UI draws from it, and a reclaimer working from its own parallel
    /// copy could delete on the strength of a verdict the user was never shown.
    static func plan(
        assets: [Asset],
        protectionStates: [UUID: ProtectionState]
    ) -> Plan {
        var plan = Plan()
        for asset in assets {
            guard let relativePath = asset.stagingRelativePath else { continue }
            guard protectionStates[asset.id] == .fullyReplicated else { continue }
            plan.releasable[asset.id] = relativePath
            plan.bytes += asset.fileSize
        }
        return plan
    }

    /// Staged files no asset claims any more.
    ///
    /// Releasing a copy is two writes — the file goes and the catalog stops
    /// naming it — and nothing makes them one operation. Whichever order they
    /// are done in, a crash between them leaves a mismatch: a path recorded
    /// with no file, which `localFileURL` already tolerates because it checks
    /// before trusting, or a file nobody names, which is invisible waste and
    /// would otherwise sit there forever. This finds the second kind.
    static func orphans(in staging: StagingStore, claimedBy assets: [Asset]) -> [String] {
        let claimed = Set(assets.compactMap(\.stagingRelativePath))
        guard let enumerator = FileManager.default.enumerator(
            at: staging.rootURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        let rootPath = staging.rootURL.standardizedFileURL.path
        var found: [String] = []
        for case let url as URL in enumerator {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
            else { continue }
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(rootPath + "/") else { continue }
            let relative = String(path.dropFirst(rootPath.count + 1))
            if !claimed.contains(relative) { found.append(relative) }
        }
        return found
    }
}
