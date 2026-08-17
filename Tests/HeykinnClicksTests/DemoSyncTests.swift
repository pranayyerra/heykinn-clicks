import XCTest
@testable import HeykinnClicks

/// A narrated run of the whole thing, for watching rather than asserting.
final class DemoSyncTests: XCTestCase {

    /// Skipped unless asked for, so a normal `swift test` stays readable:
    ///
    ///     HEYKINN_DEMO=1 swift test --filter DemoSyncTests
    func testTwoMacsAndADrive() throws {
        try XCTSkipIf(
            ProcessInfo.processInfo.environment["HEYKINN_DEMO"] == nil,
            "Set HEYKINN_DEMO=1 to watch a narrated run"
        )
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("heykinn-demo-\(UUID().uuidString)", isDirectory: true)
        func dir(_ name: String) throws -> URL {
            let url = base.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }
        addTeardownBlock { try? FileManager.default.removeItem(at: base) }

        let deviceA = try CatalogStore(databasePath: try dir("MacA").appendingPathComponent("catalog.sqlite").path)
        let deviceB = try CatalogStore(databasePath: try dir("MacB").appendingPathComponent("catalog.sqlite").path)
        let driveMount = try dir("MyPassport")
        let drive = DirectorySegmentStore(
            root: driveMount.appendingPathComponent("HeykinnClicks/Sync", isDirectory: true)
        )

        func show(_ step: String) { print("\n\u{2500}\u{2500} \(step) \u{2500}\u{2500}") }
        func groups(_ c: CatalogStore, _ who: String) throws {
            let labels = try c.fetchStorageGroups().map(\.label).sorted()
            print("   \(who): \(labels.isEmpty ? "(nothing)" : labels.joined(separator: ", "))")
        }

        print("""

        ════════════════════════════════════════════════════════════
          Two devices, one drive carried between them
          Device A device id: \(deviceA.journal.device.id)
          Device B device id: \(deviceB.journal.device.id)
        ════════════════════════════════════════════════════════════
        """)

        show("1. On Device A, make a group called 'Family'")
        let family = StorageGroup(id: UUID(), label: "Family", desiredCopies: 2,
                                  destinationTargetIDs: [], createdAt: Date())
        try deviceA.upsertStorageGroup(family)
        try groups(deviceA, "Device A"); try groups(deviceB, "Device B")

        show("2. Plug the drive into Device A")
        let pub = try DriveSync.publish(from: deviceA, to: drive)
        print("   wrote \(pub.recordsWritten) changes to the drive")

        show("3. Carry the drive to Device B and plug it in")
        let got = try DriveSync.merge(into: deviceB, from: drive)
        print("   received \(got.outcome.applied) changes from \(got.peersRead) other device(s)")
        try groups(deviceA, "Device A"); try groups(deviceB, "Device B")

        show("4. Both devices edit the SAME group, neither having seen the other")
        var onA = try XCTUnwrap(deviceA.fetchStorageGroups().first)
        onA.label = "Family photos"
        try deviceA.upsertStorageGroup(onA)
        var onB = try XCTUnwrap(deviceB.fetchStorageGroups().first)
        onB.desiredCopies = 4
        try deviceB.upsertStorageGroup(onB)
        print("   Device A renamed it; Device B changed copies to 4")

        show("5. The drive goes A → B → A")
        try DriveSync.synchronise(deviceA, with: drive)
        try DriveSync.synchronise(deviceB, with: drive)
        try DriveSync.synchronise(deviceA, with: drive)
        for (who, c) in [("Device A", deviceA), ("Device B", deviceB)] {
            let g = try XCTUnwrap(c.fetchStorageGroups().first)
            print("   \(who): \"\(g.label)\", \(g.desiredCopies) copies")
        }
        print("   ↑ both edits survived, and both devices agree")

        show("6. Someone yanks the drive mid-write")
        let segment = DriveSync.segmentPath(deviceA.journal.device.id, index: 1)
        // Measure the log *before* the new group, so the cut lands inside the
        // batch that follows. Chopping a few bytes off the very end only clips
        // one of a row's several records, and the row still arrives from its
        // siblings — which would make this step a demonstration of nothing.
        let intact = try XCTUnwrap(try drive.read(segment)).count
        try deviceA.upsertStorageGroup(StorageGroup(id: UUID(), label: "Holiday", desiredCopies: 2,
                                                 destinationTargetIDs: [], createdAt: Date()))
        try DriveSync.publish(from: deviceA, to: drive)
        let whole = try XCTUnwrap(try drive.read(segment))
        try drive.writeAtomically(whole.prefix(intact + 20), to: segment)
        print("   cut the log off 20 bytes into the batch holding 'Holiday'")
        print("   (\(whole.count - intact - 20) bytes lost)")

        let damaged = try DriveSync.merge(into: deviceB, from: drive)
        print("   Device B noticed damage from \(damaged.truncatedPeers.count) device(s)")
        try groups(deviceB, "Device B")
        print("   ↑ 'Holiday' did not make it — the drive was pulled first")

        show("7. Plug it back into Device A, then Device B")
        try DriveSync.publish(from: deviceA, to: drive)
        try DriveSync.merge(into: deviceB, from: drive)
        try groups(deviceB, "Device B")
        print("   ↑ 'Holiday' was lost to the damage above, and came back on its own")

        show("8. Delete on Device A")
        try deviceA.deleteStorageGroup(id: family.id)
        try DriveSync.synchronise(deviceA, with: drive)
        try DriveSync.synchronise(deviceB, with: drive)
        try DriveSync.synchronise(deviceA, with: drive)
        try groups(deviceA, "Device A"); try groups(deviceB, "Device B")
        print("   ↑ the deletion travelled and did not come back\n")
    }
}
