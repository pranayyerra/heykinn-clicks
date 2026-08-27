import XCTest
@testable import HeykinnClicks

/// Moving an export into the app's folder on the drive it already sits on.
///
/// Same volume, so every move is a rename. The risk is not the bytes — it is
/// the paths written down elsewhere that point at where the file used to be.
final class ExportRelocationTests: XCTestCase {

    private let mount = URL(fileURLWithPath: "/Volumes/My Passport", isDirectory: true)
    private let driveID = UUID()

    private var drive: ReplicationTarget {
        ReplicationTarget(
            id: driveID, name: "My Passport", volumeUUID: nil, markerToken: "token",
            registeredAt: Date(), lastSeenAt: nil,
            replicaRootComponent: ReplicationTarget.defaultReplicaRoot
        )
    }

    private func archive(_ part: Int, at path: String, on target: UUID? = nil) -> TakeoutArchive {
        TakeoutArchive(
            id: UUID(), path: path, kind: .zip, sizeBytes: 10_000_000_000,
            targetID: target ?? driveID, discoveredAt: Date(), importedAt: Date(),
            importBatchID: nil, importedAssetCount: 1, skippedDuplicateCount: 0,
            note: nil, exportSetID: "set", partNumber: part
        )
    }

    func testEveryPartOfTheExportIsPlannedIntoOneFolder() {
        let archives = (1...3).map {
            archive($0, at: "/Volumes/My Passport/Google_Photos_Backup_July2026/takeout-set-00\($0).zip")
        }
        let plan = ExportRelocation.plan(
            setID: "set", target: drive, mountURL: mount, archives: archives,
            zipMemberReplicasByDirectory: ["Google_Photos_Backup_July2026": 6482],
            occupied: { _ in false }
        )
        XCTAssertEqual(plan.moves.count, 3)
        XCTAssertEqual(plan.destinationDirectory, "/Volumes/My Passport/HeykinnClicks/Exports/set")
        XCTAssertTrue(plan.moves.allSatisfy { $0.to.hasPrefix(plan.destinationDirectory + "/") })
        XCTAssertEqual(plan.bytes, 30_000_000_000)
        XCTAssertEqual(
            plan.replicaPathsToRewrite, 6482,
            "the copies counted inside those zips record the folder they are in, and would be orphaned by a move that ignored them"
        )
    }

    /// Two files with one name is a question the app cannot answer by guessing.
    func testAFileAlreadyAtTheDestinationIsRefusedRatherThanOverwritten() {
        let archives = [
            archive(1, at: "/Volumes/My Passport/Downloads/takeout-set-001.zip"),
            archive(2, at: "/Volumes/My Passport/Downloads/takeout-set-002.zip"),
        ]
        let plan = ExportRelocation.plan(
            setID: "set", target: drive, mountURL: mount, archives: archives,
            zipMemberReplicasByDirectory: [:],
            occupied: { $0.hasSuffix("takeout-set-002.zip") }
        )
        XCTAssertEqual(plan.moves.map(\.displayName), ["takeout-set-001.zip"])
        XCTAssertEqual(plan.blocked, ["takeout-set-002.zip"])
    }

    /// A finished job must not look unfinished.
    func testAnExportAlreadyInPlaceHasNothingToDo() {
        let archives = [
            archive(1, at: "/Volumes/My Passport/HeykinnClicks/Exports/set/takeout-set-001.zip")
        ]
        let plan = ExportRelocation.plan(
            setID: "set", target: drive, mountURL: mount, archives: archives,
            zipMemberReplicasByDirectory: [:], occupied: { _ in false }
        )
        XCTAssertTrue(plan.isEmpty)
        XCTAssertTrue(plan.blocked.isEmpty)
    }

    func testOnlyThisExportOnThisDriveMoves() {
        let other = UUID()
        let archives = [
            archive(1, at: "/Volumes/My Passport/Downloads/takeout-set-001.zip"),
            archive(2, at: "/Volumes/Owner's Back/Owner/takeout-set-002.zip", on: other),
            {
                var elsewhere = archive(3, at: "/Volumes/My Passport/Downloads/takeout-other-001.zip")
                elsewhere.exportSetID = "another"
                return elsewhere
            }(),
        ]
        let plan = ExportRelocation.plan(
            setID: "set", target: drive, mountURL: mount, archives: archives,
            zipMemberReplicasByDirectory: [:], occupied: { _ in false }
        )
        XCTAssertEqual(
            plan.moves.map(\.displayName), ["takeout-set-001.zip"],
            "another drive's copy and another export are not this plan's business"
        )
    }

    /// The one that orphans thousands of copies if it is wrong.
    func testCopiesRecordedInsideAZipFollowItToItsNewFolder() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("heykinn-relocate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let catalog = try CatalogStore(
            databasePath: directory.appendingPathComponent("catalog.sqlite").path
        )

        let asset = UUID(), other = UUID()
        let entry = "Takeout/Google Photos/Photos from 2019/IMG_1.jpg"
        try catalog.upsertReplicaState(TargetReplicaState(
            assetID: asset, targetID: driveID, state: .present,
            relativePath: ReplicationService.zipMemberPrefix
                + "Google_Photos_Backup_July2026/takeout-set-001.zip!" + entry,
            lastVerifiedAt: Date()
        ))
        // A copy on another drive, in a folder of the same name, must not be
        // dragged along by a move that is not about it.
        try catalog.upsertReplicaState(TargetReplicaState(
            assetID: other, targetID: UUID(), state: .present,
            relativePath: ReplicationService.zipMemberPrefix
                + "Google_Photos_Backup_July2026/takeout-set-001.zip!" + entry,
            lastVerifiedAt: Date()
        ))

        let counts = try catalog.zipMemberReplicaCountsByDirectory(onTarget: driveID)
        XCTAssertEqual(counts["Google_Photos_Backup_July2026"], 1)

        let repointed = try catalog.repointZipMembers(
            onTarget: driveID,
            from: "Google_Photos_Backup_July2026",
            to: "HeykinnClicks/Exports/set"
        )
        XCTAssertEqual(repointed, 1)

        let paths = try catalog.fetchReplicaStates()
            .reduce(into: [UUID: String]()) { $0[$1.assetID] = $1.relativePath }
        XCTAssertEqual(
            paths[asset],
            ReplicationService.zipMemberPrefix
                + "HeykinnClicks/Exports/set/takeout-set-001.zip!" + entry,
            "the location changed and the entry inside the zip did not"
        )
        XCTAssertEqual(
            paths[other],
            ReplicationService.zipMemberPrefix
                + "Google_Photos_Backup_July2026/takeout-set-001.zip!" + entry,
            "the other drive's copy is untouched"
        )
    }

    /// A prefix swap, not a search and replace: the folder's name can occur
    /// again further along, after the `!`, inside the zip's own entry list.
    func testTheFolderNameIsOnlyReplacedWhereItIsTheFolder() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("heykinn-relocate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let catalog = try CatalogStore(
            databasePath: directory.appendingPathComponent("catalog.sqlite").path
        )
        let asset = UUID()
        let awkward = "Takeout/Google Photos/Downloads/photo.jpg"
        try catalog.upsertReplicaState(TargetReplicaState(
            assetID: asset, targetID: driveID, state: .present,
            relativePath: ReplicationService.zipMemberPrefix + "Downloads/takeout-set-001.zip!" + awkward,
            lastVerifiedAt: Date()
        ))
        try catalog.repointZipMembers(onTarget: driveID, from: "Downloads", to: "HeykinnClicks/Exports/set")

        XCTAssertEqual(
            try catalog.fetchReplicaStates().first?.relativePath,
            ReplicationService.zipMemberPrefix + "HeykinnClicks/Exports/set/takeout-set-001.zip!" + awkward,
            "the album called Downloads inside the export is still called Downloads"
        )
    }
}

/// Where an export set is considered to live on a drive.
///
/// Relocation created a case this had never seen: an export that is
/// deliberately inside the app's folder. The old rule excluded that folder
/// wholesale, so a home chosen on purpose read as no home at all.
final class ExportHomeAfterRelocationTests: XCTestCase {

    private let mount = URL(fileURLWithPath: "/Volumes/Owner's Back", isDirectory: true)

    private func archive(_ part: Int, at path: String) -> TakeoutArchive {
        TakeoutArchive(
            id: UUID(), path: path, kind: .zip, sizeBytes: 1, targetID: UUID(),
            discoveredAt: Date(), importedAt: Date(), importBatchID: nil,
            importedAssetCount: 1, skippedDuplicateCount: 0, note: nil,
            exportSetID: "set", partNumber: part
        )
    }

    func testARelocatedExportIsAHome() {
        let archives = (1...3).map {
            archive($0, at: "/Volumes/Owner's Back/HeykinnClicks/Exports/set/takeout-set-00\($0).zip")
        }
        XCTAssertEqual(
            ExportSetLayout.home(forSet: "set", onMount: mount, archives: archives)?.path,
            "/Volumes/Owner's Back/HeykinnClicks/Exports/set",
            "a part delivered later has somewhere to be put beside its siblings"
        )
    }

    /// The rule that was always meant: a part parked in transit must not decide
    /// where the export lives.
    func testTheWaitingRoomIsStillNeverAHome() {
        let archives = [
            archive(1, at: "/Volumes/Owner's Back/" + ExportPartRelay.onDriveDirectoryName + "/takeout-set-001.zip")
        ]
        XCTAssertNil(ExportSetLayout.home(forSet: "set", onMount: mount, archives: archives))
    }

    /// And a real home still beats the waiting room when both hold parts.
    func testSomewhereChosenBeatsSomewhereParked() {
        let archives = [
            archive(1, at: "/Volumes/Owner's Back/Owner/takeout-set-001.zip"),
            archive(2, at: "/Volumes/Owner's Back/Owner/takeout-set-002.zip"),
            archive(3, at: "/Volumes/Owner's Back/" + ExportPartRelay.onDriveDirectoryName + "/takeout-set-003.zip"),
        ]
        XCTAssertEqual(
            ExportSetLayout.home(forSet: "set", onMount: mount, archives: archives)?.path,
            "/Volumes/Owner's Back/Owner"
        )
    }
}
