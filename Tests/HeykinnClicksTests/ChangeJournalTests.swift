import XCTest
@testable import HeykinnClicks

/// Whether two archives can be made to agree.
///
/// These are the properties the whole multi-device design rests on, and every
/// one of them fails silently if it fails at all — the catalog stays perfectly
/// readable while describing something untrue. So they are stated as properties
/// (order does not matter, repetition does not matter, both sides end up equal)
/// rather than as examples of one merge going well.
final class ChangeJournalTests: XCTestCase {

    /// A separate directory per catalog, so each gets its own `DeviceIdentity`
    /// — two catalogs sharing a device id would tie-break against themselves
    /// and hide exactly the bugs these look for.
    private func makeCatalog(_ label: String) throws -> CatalogStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("heykinn-journal-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return try CatalogStore(databasePath: directory.appendingPathComponent("catalog.sqlite").path)
    }

    private func makeGroup(
        id: UUID = UUID(), label: String, copies: Int = 2
    ) -> StorageGroup {
        StorageGroup(
            id: id,
            label: label,
            desiredCopies: copies,
            destinationTargetIDs: [],
            createdAt: Date(timeIntervalSince1970: 1_000_000)
        )
    }

    /// One device handing everything it knows to another, the way a drive
    /// carrying a full log would.
    @discardableResult
    private func sync(
        from source: CatalogStore, to destination: CatalogStore
    ) throws -> MergeOutcome {
        let records = try source.journal.changes(since: nil)
        for record in records { try destination.journal.observe(record.stamp) }
        return try destination.journal.merge(records)
    }

    private func groups(_ catalog: CatalogStore) throws -> [String: StorageGroup] {
        Dictionary(uniqueKeysWithValues: try catalog.fetchStorageGroups().map { ($0.label, $0) })
    }

    // MARK: - The basic path

    func testAGroupCreatedOnOneDeviceArrivesOnTheOther() throws {
        let a = try makeCatalog("a")
        let b = try makeCatalog("b")
        try a.upsertStorageGroup(makeGroup(label: "Family", copies: 3))

        let outcome = try sync(from: a, to: b)

        XCTAssertTrue(outcome.rejected.isEmpty, "\(outcome.rejected)")
        let arrived = try XCTUnwrap(groups(b)["Family"])
        XCTAssertEqual(arrived.desiredCopies, 3)
    }

    func testEachDeviceKeepsItsOwnAndGainsTheOthers() throws {
        let a = try makeCatalog("a")
        let b = try makeCatalog("b")
        try a.upsertStorageGroup(makeGroup(label: "Family"))
        try b.upsertStorageGroup(makeGroup(label: "Work"))

        try sync(from: a, to: b)
        try sync(from: b, to: a)

        XCTAssertEqual(Set(try groups(a).keys), ["Family", "Work"])
        XCTAssertEqual(Set(try groups(b).keys), ["Family", "Work"])
    }

    // MARK: - Per-field, not per-row

    /// The case the whole per-field design exists for. Two devices edit
    /// *different* columns of one row; neither edit is in conflict with the
    /// other, and a row-scoped stamp would throw one of them away for nothing.
    func testEditsToDifferentColumnsBothSurvive() throws {
        let shared = UUID()
        let a = try makeCatalog("a")
        let b = try makeCatalog("b")
        try a.upsertStorageGroup(makeGroup(id: shared, label: "Family", copies: 2))
        try sync(from: a, to: b)

        // A renames it; B changes how many copies it wants.
        var onA = try XCTUnwrap(a.fetchStorageGroups().first)
        onA.label = "Family photos"
        try a.upsertStorageGroup(onA)

        var onB = try XCTUnwrap(b.fetchStorageGroups().first)
        onB.desiredCopies = 4
        try b.upsertStorageGroup(onB)

        try sync(from: a, to: b)
        try sync(from: b, to: a)

        for (name, catalog) in [("A", a), ("B", b)] {
            let group = try XCTUnwrap(catalog.fetchStorageGroups().first)
            XCTAssertEqual(group.label, "Family photos", "\(name) lost the rename")
            XCTAssertEqual(group.desiredCopies, 4, "\(name) lost the copy count")
        }
    }

    /// Same column on both sides is a genuine conflict. Exactly one wins, and
    /// — the part that matters — both devices pick the same one.
    func testTheSameColumnOnBothSidesResolvesIdenticallyEverywhere() throws {
        let shared = UUID()
        let a = try makeCatalog("a")
        let b = try makeCatalog("b")
        try a.upsertStorageGroup(makeGroup(id: shared, label: "Original"))
        try sync(from: a, to: b)

        var onA = try XCTUnwrap(a.fetchStorageGroups().first)
        onA.label = "Named by A"
        try a.upsertStorageGroup(onA)

        var onB = try XCTUnwrap(b.fetchStorageGroups().first)
        onB.label = "Named by B"
        try b.upsertStorageGroup(onB)

        try sync(from: a, to: b)
        try sync(from: b, to: a)

        let onAFinal = try XCTUnwrap(a.fetchStorageGroups().first).label
        let onBFinal = try XCTUnwrap(b.fetchStorageGroups().first).label
        XCTAssertEqual(onAFinal, onBFinal, "The two devices disagree, so they will never converge")
        XCTAssertTrue(["Named by A", "Named by B"].contains(onAFinal))
    }

    // MARK: - Deletion

    /// A row deleted here and absent there is indistinguishable from one never
    /// seen. Without a tombstone the next merge hands it straight back.
    func testADeletedGroupIsNotResurrectedByTheOtherDevice() throws {
        let shared = UUID()
        let a = try makeCatalog("a")
        let b = try makeCatalog("b")
        try a.upsertStorageGroup(makeGroup(id: shared, label: "Temporary"))
        try sync(from: a, to: b)
        XCTAssertEqual(try b.fetchStorageGroups().count, 1)

        try a.deleteStorageGroup(id: shared)
        try sync(from: a, to: b)
        XCTAssertTrue(try b.fetchStorageGroups().isEmpty, "The deletion did not travel")

        // B now tells A everything it knows, including the row it used to hold.
        try sync(from: b, to: a)
        XCTAssertTrue(try a.fetchStorageGroups().isEmpty, "The group came back from the dead")
    }

    /// A write *after* a deletion is a legitimate re-creation and must win.
    func testAWriteAfterADeletionBringsTheRowBack() throws {
        let shared = UUID()
        let a = try makeCatalog("a")
        let b = try makeCatalog("b")
        try a.upsertStorageGroup(makeGroup(id: shared, label: "First"))
        try sync(from: a, to: b)
        try a.deleteStorageGroup(id: shared)
        try sync(from: a, to: b)

        // Made again, deliberately reusing the id.
        try a.upsertStorageGroup(makeGroup(id: shared, label: "Second"))
        try sync(from: a, to: b)

        XCTAssertEqual(try groups(b).keys.sorted(), ["Second"])
    }

    // MARK: - Properties

    /// Re-reading a drive is expected — the same segments will be seen again
    /// and again. A merge that is not idempotent is a merge that cannot be
    /// retried.
    func testMergingTheSameChangesTwiceChangesNothing() throws {
        let a = try makeCatalog("a")
        let b = try makeCatalog("b")
        try a.upsertStorageGroup(makeGroup(label: "Family", copies: 3))

        let records = try a.journal.changes(since: nil)
        try b.journal.merge(records)
        let afterFirst = try b.fetchStorageGroups()

        let second = try b.journal.merge(records)

        XCTAssertEqual(try b.fetchStorageGroups(), afterFirst)
        XCTAssertEqual(second.applied, 0, "A repeat merge applied something")
        XCTAssertTrue(second.superseded > 0)
    }

    /// Drives deliver in whatever order they are read. If the outcome depended
    /// on that order, two devices given the same facts would end up different.
    func testTheOrderRecordsArriveInDoesNotChangeTheResult() throws {
        let source = try makeCatalog("source")
        let first = UUID()
        try source.upsertStorageGroup(makeGroup(id: first, label: "Family", copies: 2))
        try source.upsertStorageGroup(makeGroup(label: "Work", copies: 5))
        var renamed = try XCTUnwrap(source.fetchStorageGroups().first { $0.id == first })
        renamed.label = "Family photos"
        try source.upsertStorageGroup(renamed)
        let records = try source.journal.changes(since: nil)

        var seen: [[StorageGroup]] = []
        for attempt in 0..<8 {
            let destination = try makeCatalog("shuffled-\(attempt)")
            try destination.journal.merge(records.shuffled())
            seen.append(try destination.fetchStorageGroups().sorted { $0.id.uuidString < $1.id.uuidString })
        }

        for result in seen {
            XCTAssertEqual(result, seen[0], "Merge outcome depended on arrival order")
        }
        XCTAssertEqual(seen[0].count, 2)
        XCTAssertTrue(seen[0].contains { $0.label == "Family photos" })
    }

    // MARK: - Untrusted input

    /// Records arrive from a file on a removable drive. A table name in one is
    /// input, never instruction.
    func testRecordsNamingUnknownOrForbiddenTablesAreRejected() throws {
        let catalog = try makeCatalog("a")
        let stamp = try catalog.journal.stamp()

        let outcome = try catalog.journal.merge([
            .set(table: "no_such_table", rowID: "x", column: "a", value: .text("y"), stamp: stamp),
            // A device-local table must never be written by another device.
            .set(table: "import_scan_memo", rowID: "x", column: "size", value: .integer(1), stamp: stamp),
            .set(table: "drive_local_state", rowID: "x", column: "last_mount_path",
                 value: .text("/Volumes/Elsewhere"), stamp: stamp),
        ])

        XCTAssertEqual(outcome.applied, 0)
        XCTAssertEqual(outcome.rejected.count, 3)
    }

    func testAnUnknownColumnIsRejectedRatherThanInterpolated() throws {
        let catalog = try makeCatalog("a")
        let group = makeGroup(label: "Family")
        try catalog.upsertStorageGroup(group)
        let stamp = try catalog.journal.stamp()

        let outcome = try catalog.journal.merge([
            .set(
                table: "storage_groups", rowID: ChangeJournal.rowID([group.id.uuidString]),
                column: "label\" = '', \"desired_copies", value: .text("nope"), stamp: stamp
            ),
        ])

        XCTAssertEqual(outcome.applied, 0)
        XCTAssertEqual(outcome.rejected.count, 1)
        // And nothing was damaged on the way to refusing.
        XCTAssertEqual(try catalog.fetchStorageGroups().first?.label, "Family")
    }

    // MARK: - Creating a row from what arrived

    /// A row that arrives without every NOT NULL column cannot be built. Half a
    /// row would be worse than none, so it is refused and counted.
    func testAnIncompleteRowIsRefusedRatherThanPartlyCreated() throws {
        let catalog = try makeCatalog("a")
        let stamp = try catalog.journal.stamp()

        let outcome = try catalog.journal.merge([
            .set(
                table: "storage_groups", rowID: ChangeJournal.rowID([UUID().uuidString]),
                column: "label", value: .text("Orphan"), stamp: stamp
            ),
        ])

        XCTAssertEqual(outcome.applied, 0)
        XCTAssertEqual(outcome.rejected.count, 1)
        XCTAssertTrue(try catalog.fetchStorageGroups().isEmpty)
    }

    /// A row id whose component count does not match the table's key is
    /// refused. It arrives from a file, so this is input rather than a bug.
    func testARowIDThatDoesNotMatchTheKeyIsRejected() throws {
        let catalog = try makeCatalog("a")
        let stamp = try catalog.journal.stamp()

        let outcome = try catalog.journal.merge([
            .set(
                table: "storage_groups", rowID: ChangeJournal.rowID(["one", "two"]),
                column: "label", value: .text("nope"), stamp: stamp
            ),
            .set(
                table: "storage_groups", rowID: "not-length-prefixed",
                column: "label", value: .text("nope"), stamp: stamp
            ),
        ])

        XCTAssertEqual(outcome.applied, 0)
        XCTAssertEqual(outcome.rejected.count, 2)
    }

    // MARK: - Row id encoding

    func testRowIDsRoundTrip() {
        for components in [
            ["single"],
            ["a", "b"],
            ["9F3C1A20-4B77-4E0E-9B41-2C5D6E7F8A90", "3"],
            [""],
            ["", ""],
        ] {
            XCTAssertEqual(
                ChangeJournal.rowComponents(ChangeJournal.rowID(components)), components,
                "\(components) did not survive"
            )
        }
    }

    /// The reason for length-prefixing rather than a separator. A key component
    /// is arbitrary text — a filename, a tag value — so any delimiter can occur
    /// inside one, and two components must never be confusable with one.
    func testComponentsContainingTheSeparatorAreUnambiguous() {
        let awkward = ["3:not-a-length", "a:b:c", "12:", ""]
        XCTAssertEqual(ChangeJournal.rowComponents(ChangeJournal.rowID(awkward)), awkward)

        // And two different splits cannot collide.
        XCTAssertNotEqual(ChangeJournal.rowID(["ab", "c"]), ChangeJournal.rowID(["a", "bc"]))
    }

    /// Lengths are in UTF-8 bytes, so the count does not depend on how a
    /// language defines a character — the thing that would silently differ
    /// between Swift, Kotlin and C#.
    func testLengthsAreCountedInBytes() {
        XCTAssertEqual(ChangeJournal.rowID(["é"]), "2:é")
        XCTAssertEqual(ChangeJournal.rowID(["📷"]), "4:📷")
        XCTAssertEqual(ChangeJournal.rowComponents("4:📷"), ["📷"])
    }

    func testMalformedRowIDsDecodeToNil() {
        for text in ["5:abc", "abc", ":", "-1:a", "3"] {
            XCTAssertNil(ChangeJournal.rowComponents(text), "\"\(text)\" should not parse")
        }
    }

    // MARK: - The clock

    /// The journal's clock has to survive a relaunch, or a stamp already used
    /// can be issued again — and two changes sharing one stamp is the single
    /// thing the ordering cannot absorb.
    func testTheClockResumesAcrossReopening() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("heykinn-clock-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("catalog.sqlite").path

        let first = try CatalogStore(databasePath: path)
        let before = try first.journal.stamp()
        first.database.close()

        let reopened = try CatalogStore(databasePath: path)
        let after = try reopened.journal.stamp()

        XCTAssertTrue(before < after)
        XCTAssertEqual(reopened.journal.device.id, first.journal.device.id, "Same install, same device")
    }

    /// The identity must not be inside the catalog: a snapshot restored onto
    /// another device would otherwise have it issuing changes as the device
    /// that wrote the snapshot.
    func testTwoArchivesInDifferentPlacesAreDifferentDevices() throws {
        let a = try makeCatalog("a")
        let b = try makeCatalog("b")
        XCTAssertNotEqual(a.journal.device.id, b.journal.device.id)
    }
}
