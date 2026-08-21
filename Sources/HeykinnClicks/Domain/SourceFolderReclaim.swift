import Foundation

/// Whether a folder you imported from is now holding photographs the archive
/// already keeps, and what removing it would and would not touch.
///
/// **The one place the app would delete something that is yours.** Everything
/// else it deletes is its own: the working copy in staging, a spare form of an
/// export it put on a drive. A folder you pointed it at is read and never
/// written, and that promise is printed on the Add photos screen — so this
/// cannot be a thing that happens when a condition is met. It is an offer, and
/// it has to be able to refuse itself.
///
/// **Identified by content, not by path.** An asset records the name of the
/// file it came from and the hash of its bytes, not where that file was. Hash
/// is the better key anyway: it survives a rename, and a file edited since it
/// was imported no longer matches, so it is quietly left alone rather than
/// deleted on the strength of a path that still lines up.
///
/// **The bar is the app's own record, taken at face value.** Copies exist, they
/// meet what the photograph's set asks for, and at least one has been read back.
/// No freshness window: a reading thirty-one days old is still a reading, and
/// `verificationOverdue` already counts as meeting policy everywhere else in
/// the app — it steers the background reader rather than deciding whether
/// photographs are safe. What is excluded is `awaitingFirstCheck`, where copies
/// were written and nothing has ever read one: that is the app believing itself,
/// which is not evidence.
enum SourceFolderReclaim {

    /// A file sitting in the folder right now.
    struct File: Equatable, Hashable {
        var url: URL
        var contentHash: String
        var size: Int64
    }

    /// Why a file the app *did* import still cannot go.
    enum Blocker: String, CaseIterable, Equatable, Hashable {
        /// Fewer copies than the photograph's set asks for.
        case notEnoughCopies
        /// Copies exist, but nothing has read one back yet.
        case neverReadBack
        /// A copy no longer matches what was recorded.
        case damagedCopy
    }

    struct Plan: Equatable {
        /// Files the archive already holds, to the bar above.
        var releasable: [File] = []
        var releasableBytes: Int64 = 0
        /// Files in the folder the app never imported. Named separately and
        /// never deleted: "remove the folder" must not mean "remove things
        /// nobody looked at", and a folder almost always has some.
        var notImported: [File] = []
        var notImportedBytes: Int64 = 0
        /// Imported files that are not safe to release yet, and why.
        var blocked: [File: Blocker] = [:]

        var isEmpty: Bool { releasable.isEmpty }
        /// Whether removing everything releasable would leave the folder there.
        var leavesFilesBehind: Bool { !notImported.isEmpty || !blocked.isEmpty }

        /// Nothing visible in the folder at all — which is what a folder looks
        /// like after a reclaim took everything it could.
        ///
        /// `isEmpty` alone cannot tell that apart from a folder where every
        /// file is blocked, and the two need opposite things said about them:
        /// one is finished, the other is waiting. Asking a plan "is there
        /// nothing to do?" and answering "then the copies must still be
        /// unread" is how an empty folder ended up being described as one of
        /// the places your photographs are kept.
        var isFolderEmpty: Bool {
            releasable.isEmpty && notImported.isEmpty && blocked.isEmpty
        }

        /// Nothing here is spare, and nothing is being waited on either — what
        /// remains is only ever files the app did not import.
        var holdsOnlyFilesTheAppNeverTookIn: Bool {
            releasable.isEmpty && blocked.isEmpty && !notImported.isEmpty
        }
    }

    /// - Parameters:
    ///   - files: what is in the folder now, already hashed.
    ///   - protectionByHash: the protection state of the photograph the archive
    ///     holds for that content, if it holds one at all.
    static func plan(
        files: [File],
        protectionByHash: [String: ProtectionState]
    ) -> Plan {
        var plan = Plan()
        for file in files {
            guard let protection = protectionByHash[file.contentHash] else {
                plan.notImported.append(file)
                plan.notImportedBytes += file.size
                continue
            }
            switch protection {
            case .fullyReplicated, .verificationOverdue:
                plan.releasable.append(file)
                plan.releasableBytes += file.size
            case .awaitingFirstCheck:
                plan.blocked[file] = .neverReadBack
            case .driftDetected:
                plan.blocked[file] = .damagedCopy
            case .stagedOnly, .replicatedToOneDrive:
                plan.blocked[file] = .notEnoughCopies
            case .notApplicable:
                // Not a photograph the archive keeps locally, so the archive is
                // not holding a copy of it and this file is not spare.
                plan.notImported.append(file)
                plan.notImportedBytes += file.size
            }
        }
        return plan
    }
}
