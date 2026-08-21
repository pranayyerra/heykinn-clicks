import XCTest
@testable import HeykinnClicks

/// Temporary probe: what does the folder row / sheet say AFTER a reclaim?
@MainActor
final class ZZProbeTests: XCTestCase {

    private func makeStore() throws -> AppStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("probe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return AppStore(environment: AppEnvironment(
            appDirectory: directory,
            defaults: UserDefaults(suiteName: "probe-\(UUID().uuidString)")!,
            runsBackgroundWork: false
        ))
    }

    private func makeFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("probefolder-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    @discardableResult
    private func write(_ text: String, named name: String, into folder: URL) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
    }

    private func describe(_ plan: SourceFolderReclaim.Plan, _ label: String) {
        print("""
        --- \(label)
            releasable:  \(plan.releasable.map(\.url.lastPathComponent))
            notImported: \(plan.notImported.map(\.url.lastPathComponent))
            blocked:     \(plan.blocked.map { "\($0.key.url.lastPathComponent)=\($0.value.rawValue)" })
            isEmpty:            \(plan.isEmpty)
            leavesFilesBehind:  \(plan.leavesFilesBehind)
        """)
    }

    /// The screenshot's shape: some releasable, some blocked.
    func testProbeAfterReclaimWithBlockedLeftOver() async throws {
        let store = try makeStore()
        let folder = try makeFolder()
        let safe = try write("safe photo", named: "safe.jpg", into: folder)
        let unread = try write("unread photo", named: "unread.jpg", into: folder)
        let archive = [
            try HashingService.sha256(of: safe): ProtectionState.fullyReplicated,
            try HashingService.sha256(of: unread): ProtectionState.awaitingFirstCheck,
        ]

        let before = await store.planFolderReclaim(at: folder.path, protectionByHash: archive)
        describe(before, "BEFORE reclaim")

        let n = await store.reclaimFolder(at: folder.path, protectionByHash: archive) {
            try FileManager.default.removeItem(at: $0)
        }
        print("    reclaimed: \(n)")

        let after = await store.planFolderReclaim(at: folder.path, protectionByHash: archive)
        describe(after, "AFTER reclaim (blocked left over)")
    }

    /// The worse shape: everything the app imported has gone, and what remains
    /// is only stuff the app never touched.
    func testProbeAfterReclaimWithOnlyNotImportedLeftOver() async throws {
        let store = try makeStore()
        let folder = try makeFolder()
        let safe = try write("safe photo", named: "safe.jpg", into: folder)
        try write("my notes", named: "notes.txt", into: folder)
        let archive = [try HashingService.sha256(of: safe): ProtectionState.fullyReplicated]

        let n = await store.reclaimFolder(at: folder.path, protectionByHash: archive) {
            try FileManager.default.removeItem(at: $0)
        }
        print("    reclaimed: \(n)")

        let after = await store.planFolderReclaim(at: folder.path, protectionByHash: archive)
        describe(after, "AFTER reclaim (only not-imported left)")
    }

    /// Everything went and the folder is now empty.
    func testProbeAfterReclaimLeavingAnEmptyFolder() async throws {
        let store = try makeStore()
        let folder = try makeFolder()
        let safe = try write("safe photo", named: "safe.jpg", into: folder)
        let archive = [try HashingService.sha256(of: safe): ProtectionState.fullyReplicated]

        let n = await store.reclaimFolder(at: folder.path, protectionByHash: archive) {
            try FileManager.default.removeItem(at: $0)
        }
        print("    reclaimed: \(n)")

        let after = await store.planFolderReclaim(at: folder.path, protectionByHash: archive)
        describe(after, "AFTER reclaim (folder now empty)")
    }
}
