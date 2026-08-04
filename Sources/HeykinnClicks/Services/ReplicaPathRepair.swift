import Foundation

/// Finds replicas whose recorded path no longer resolves, and works out where
/// the content moved to.
///
/// Renaming a folder on a target is an ordinary thing to do, and it invalidates
/// every path the catalog recorded beneath it at once. Nothing notices on its
/// own: no hash changed, so the trees still agree, and only reading the disk
/// would find it — which is exactly what the trees exist to avoid doing on a
/// timer. So the cheap check belongs here, at the front: a `stat` on the
/// directories the paths hang from costs microseconds and catches the whole
/// class.
///
/// Repair, not re-copy. The content is on the target already; treating it as
/// missing would write it a second time under a different name — the failure
/// the archive-backed replica rule exists to prevent.
enum ReplicaPathRepair {

    /// Recorded paths pointing into content the user manages, as opposed to
    /// files the app itself laid down under its replica root.
    static let volumePrefix = "volume:"

    struct Plan: Equatable {
        /// Prefix rewrites, longest first so the most specific match wins.
        var rewrites: [Rewrite] = []
        /// Directories that no longer resolve and whose content was not found
        /// anywhere on the target.
        var unplaceable: [String] = []

        var isEmpty: Bool { rewrites.isEmpty && unplaceable.isEmpty }
    }

    struct Rewrite: Equatable {
        var from: String
        var to: String
    }

    /// Groups recorded paths by the directory they hang from and checks each
    /// once. Twenty-four thousand replicas under one renamed folder cost one
    /// `stat`, not twenty-four thousand.
    static func plan(
        recordedPaths: [String],
        mountURL: URL,
        searchDepth: Int = 4
    ) -> Plan {
        var plan = Plan()
        var checked: [String: Bool] = [:]
        var resolved: [String: String?] = [:]

        for path in recordedPaths {
            guard path.hasPrefix(volumePrefix) else { continue }
            let relative = String(path.dropFirst(volumePrefix.count))
            // The anchor is the second component: deep enough to have a
            // distinctive name worth searching for, shallow enough that one
            // rewrite covers everything beneath it.
            guard let anchor = anchorPrefix(of: relative) else { continue }
            if checked[anchor] == nil {
                checked[anchor] = FileManager.default.fileExists(
                    atPath: mountURL.appendingPathComponent(anchor).path
                )
            }
            guard checked[anchor] == false else { continue }

            if resolved[anchor] == nil {
                resolved[anchor] = relocate(anchor: anchor, under: mountURL, depth: searchDepth)
            }
            if let replacement = resolved[anchor] ?? nil {
                let rewrite = Rewrite(from: volumePrefix + anchor, to: volumePrefix + replacement)
                if !plan.rewrites.contains(rewrite) { plan.rewrites.append(rewrite) }
            } else if !plan.unplaceable.contains(anchor) {
                plan.unplaceable.append(anchor)
            }
        }
        plan.rewrites.sort { $0.from.count > $1.from.count }
        return plan
    }

    /// `Owner/Backup_Google/takeout-…/Google Photos/x.jpg` anchors on
    /// `Owner/Backup_Google/takeout-…`. Renaming any ancestor breaks the
    /// anchor, and the leaf of the anchor is the part with a name distinctive
    /// enough to find again.
    /// Scans for the third separator rather than splitting the whole path:
    /// this runs once per replica on every catalog change, and building an
    /// array of components for fifty thousand paths to throw all but three
    /// away is work nothing needs.
    static func anchorPrefix(of relativePath: String) -> String? {
        guard !relativePath.isEmpty else { return nil }
        var separators = 0
        var index = relativePath.startIndex
        while index < relativePath.endIndex {
            if relativePath[index] == "/" {
                separators += 1
                if separators == 3 { return String(relativePath[..<index]) }
            }
            index = relativePath.index(after: index)
        }
        return relativePath
    }

    /// Looks for a directory with the anchor's own name somewhere else on the
    /// target. Only an unambiguous single match is accepted: two candidates
    /// mean the app cannot tell which one the catalog meant, and guessing would
    /// point the archive at the wrong content.
    private static func relocate(anchor: String, under mountURL: URL, depth: Int) -> String? {
        guard let name = anchor.split(separator: "/").last.map(String.init) else { return nil }
        var matches: [String] = []
        search(directory: mountURL, base: "", name: name, remaining: depth, into: &matches)
        guard matches.count == 1 else { return nil }
        return matches[0]
    }

    private static func search(
        directory: URL,
        base: String,
        name: String,
        remaining: Int,
        into matches: inout [String]
    ) {
        guard remaining > 0, matches.count < 2 else { return }
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        for entry in entries {
            guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            let relative = base.isEmpty ? entry.lastPathComponent : base + "/" + entry.lastPathComponent
            if entry.lastPathComponent == name {
                matches.append(relative)
                if matches.count >= 2 { return }
                continue
            }
            search(directory: entry, base: relative, name: name, remaining: remaining - 1, into: &matches)
        }
    }

    /// Applies the plan to one recorded path, returning nil when nothing
    /// matched. The caller must confirm the result resolves before committing
    /// it: a rewrite is a guess about where content went, and an unverified
    /// guess written into the catalog is worse than the broken path it
    /// replaces.
    static func apply(_ plan: Plan, to recordedPath: String) -> String? {
        for rewrite in plan.rewrites where recordedPath.hasPrefix(rewrite.from) {
            return rewrite.to + recordedPath.dropFirst(rewrite.from.count)
        }
        return nil
    }
}
