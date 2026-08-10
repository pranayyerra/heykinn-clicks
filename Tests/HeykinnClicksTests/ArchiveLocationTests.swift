import XCTest
@testable import HeykinnClicks

/// One archive, however the app was installed.
///
/// A sandboxed build gets a container of its own, so without a shared location
/// somebody who installed both the App Store and the website build would own
/// two catalogs on one Mac — each describing an overlapping half of the same
/// photographs, and each screen quietly reporting the wrong total.
final class ArchiveLocationTests: XCTestCase {

    private let home = URL(fileURLWithPath: "/Users/someone", isDirectory: true)

    private func resolve(
        override: String? = nil,
        groupContainer: URL? = nil,
        existing: Set<String> = []
    ) -> ArchiveLocation.Resolution {
        ArchiveLocation.resolve(
            override: override,
            groupContainer: groupContainer,
            home: home,
            exists: { existing.contains($0.standardizedFileURL.path) }
        )
    }

    /// The override is how a test — and anybody looking at the app — avoids the
    /// real archive. It has to beat everything, including a group container
    /// that exists and would otherwise be preferred.
    func testTheOverrideWinsOverEverything() {
        let group = URL(fileURLWithPath: "/group", isDirectory: true)
        let resolution = resolve(override: "/tmp/scratch", groupContainer: group)
        XCTAssertEqual(resolution.kind, .overridden)
        XCTAssertEqual(resolution.url.path, "/tmp/scratch")
    }

    func testAnEmptyOverrideIsNotAnOverride() {
        XCTAssertEqual(resolve(override: "").kind, .legacy)
    }

    /// The entitled case: both builds ask the system and are given the same
    /// place.
    func testAnEntitledBuildUsesTheGroupContainer() {
        let group = URL(fileURLWithPath: "/Users/someone/Library/Group Containers/TEAM.app", isDirectory: true)
        let resolution = resolve(groupContainer: group)
        XCTAssertEqual(resolution.kind, .appGroup)
        XCTAssertEqual(resolution.url.lastPathComponent, ArchiveLocation.folderName)
        XCTAssertTrue(resolution.url.path.hasPrefix(group.path))
    }

    /// The case that stops a second archive appearing. `swift run` produces an
    /// unsigned binary that cannot ask for a group container — but it is not
    /// sandboxed either, so it can simply read the one that is there. Without
    /// this it would find the old location empty and start again.
    func testAnUnentitledBuildStillFindsAnExistingSharedArchive() {
        let shared = ArchiveLocation.groupContainerPath(home: home)
            .appendingPathComponent(ArchiveLocation.folderName, isDirectory: true)
        let resolution = resolve(groupContainer: nil, existing: [shared.standardizedFileURL.path])

        XCTAssertEqual(resolution.kind, .appGroupByPath)
        XCTAssertEqual(resolution.url.standardizedFileURL.path, shared.standardizedFileURL.path)
    }

    /// A first run of an unsigned build, with nothing anywhere: the pre-group
    /// location, which is where every archive written before this existed is.
    func testWithNothingSharedItFallsBackToTheOldLocation() {
        let resolution = resolve(groupContainer: nil, existing: [])
        XCTAssertEqual(resolution.kind, .legacy)
        XCTAssertEqual(resolution.url.standardizedFileURL.path, ArchiveLocation.legacyPath(home: home).standardizedFileURL.path)
    }

    /// macOS requires the team prefix on a macOS app group; without it the
    /// container is never granted and both builds silently keep their own.
    func testTheGroupIdentifierCarriesTheTeamPrefix() {
        XCTAssertTrue(
            ArchiveLocation.appGroupIdentifier.hasPrefix("344B87D3CV."),
            "macOS refuses an app group that is not team-prefixed"
        )
    }
}

/// Moving an existing archive into the shared container — done once, to
/// somebody's real photographs, so the interesting cases are the ones where it
/// declines to act.
final class ArchiveMigrationTests: XCTestCase {

    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("heykinn-move-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func makeArchive(at url: URL, marker: String) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try Data(marker.utf8).write(to: url.appendingPathComponent("catalog.sqlite"))
    }

    func testAnExistingArchiveMovesIntoTheSharedContainer() throws {
        let root = try makeDirectory()
        let legacy = root.appendingPathComponent("Application Support/HeykinnClicks", isDirectory: true)
        let shared = root.appendingPathComponent("Group Containers/TEAM.app/HeykinnClicks", isDirectory: true)
        try makeArchive(at: legacy, marker: "the real catalog")

        let result = ArchiveLocation.migrateIfNeeded(legacy: legacy, shared: shared)

        XCTAssertEqual(result, .moved(from: legacy, to: shared))
        XCTAssertEqual(
            try String(contentsOf: shared.appendingPathComponent("catalog.sqlite"), encoding: .utf8),
            "the real catalog"
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: legacy.path),
            "A move, not a copy: leaving the old one means the next unsigned build writes to it"
        )
    }

    /// The case worth being careful about. Two catalogs describing overlapping
    /// sets of photographs cannot be reconciled by moving files, and picking
    /// one silently would throw away whichever the user cared about.
    func testTwoArchivesAreReportedRatherThanMerged() throws {
        let root = try makeDirectory()
        let legacy = root.appendingPathComponent("legacy", isDirectory: true)
        let shared = root.appendingPathComponent("shared", isDirectory: true)
        try makeArchive(at: legacy, marker: "one")
        try makeArchive(at: shared, marker: "two")

        let result = ArchiveLocation.migrateIfNeeded(legacy: legacy, shared: shared)

        XCTAssertEqual(result, .refusedBothExist(legacy: legacy, shared: shared))
        // Both are exactly as they were.
        XCTAssertEqual(try String(contentsOf: legacy.appendingPathComponent("catalog.sqlite"), encoding: .utf8), "one")
        XCTAssertEqual(try String(contentsOf: shared.appendingPathComponent("catalog.sqlite"), encoding: .utf8), "two")
    }

    func testNothingToMoveIsNotAnEvent() throws {
        let root = try makeDirectory()
        let result = ArchiveLocation.migrateIfNeeded(
            legacy: root.appendingPathComponent("legacy", isDirectory: true),
            shared: root.appendingPathComponent("shared", isDirectory: true)
        )
        XCTAssertEqual(result, .notNeeded)
    }

    /// An empty directory at the old location is not an archive. Moving it
    /// would put an empty folder where the shared one goes and then refuse
    /// every later migration on the grounds that something is already there.
    func testAnEmptyOldFolderIsNotTreatedAsAnArchive() throws {
        let root = try makeDirectory()
        let legacy = root.appendingPathComponent("legacy", isDirectory: true)
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)

        let result = ArchiveLocation.migrateIfNeeded(
            legacy: legacy,
            shared: root.appendingPathComponent("shared", isDirectory: true)
        )
        XCTAssertEqual(result, .notNeeded)
    }
}

/// The throwaway archive, chosen inside the app rather than typed into a
/// terminal. Two copies of this app share one archive on purpose, so anybody
/// running both — which is what publishing to two places means — needs one of
/// them somewhere else.
final class TestArchiveResolutionTests: XCTestCase {

    private let home = URL(fileURLWithPath: "/Users/someone", isDirectory: true)

    private func resolve(
        override: String? = nil,
        groupContainer: URL? = nil,
        wantsTest: Bool,
        existing: Set<String> = []
    ) -> ArchiveLocation.Resolution {
        ArchiveLocation.resolve(
            override: override,
            groupContainer: groupContainer,
            home: home,
            wantsTestArchive: wantsTest,
            exists: { existing.contains($0.standardizedFileURL.path) }
        )
    }

    func testAskingForATestArchiveGetsOne() {
        let resolution = resolve(wantsTest: true)
        XCTAssertEqual(resolution.kind, .test)
        XCTAssertTrue(resolution.url.lastPathComponent.hasSuffix("-Test"))
    }

    /// The real archive must be unreachable from test mode — not merely a
    /// different folder, but not an ancestor either.
    func testTheTestArchiveIsBesideTheRealOneAndNeverInsideIt() {
        let real = resolve(wantsTest: false).url.standardizedFileURL.path
        let test = resolve(wantsTest: true).url.standardizedFileURL.path

        XCTAssertNotEqual(real, test)
        XCTAssertFalse(test.hasPrefix(real + "/"), "A test archive inside the real one would be swept and counted as content")
        XCTAssertFalse(real.hasPrefix(test + "/"))
    }

    /// Test mode is decided before the real archive is worked out at all, so
    /// nothing about it can touch the group container's contents.
    func testTestModeBeatsTheGroupContainer() {
        let group = URL(fileURLWithPath: "/Users/someone/Library/Group Containers/TEAM.app", isDirectory: true)
        XCTAssertEqual(resolve(groupContainer: group, wantsTest: true).kind, .test)
        XCTAssertEqual(resolve(groupContainer: group, wantsTest: false).kind, .appGroup)
    }

    /// An explicit override still wins, so a test suite pointed at its own
    /// directory is never diverted by a preference left on from somewhere else.
    func testAnOverrideStillBeatsTestMode() {
        let resolution = resolve(override: "/tmp/explicit", wantsTest: true)
        XCTAssertEqual(resolution.kind, .overridden)
        XCTAssertEqual(resolution.url.path, "/tmp/explicit")
    }

    /// Sandboxed, the container is the only place this copy may write — so the
    /// test archive has to land inside it rather than beside it on disk.
    func testASandboxedCopyKeepsItsTestArchiveInsideItsContainer() {
        let group = URL(fileURLWithPath: "/Users/someone/Library/Group Containers/TEAM.app", isDirectory: true)
        let resolution = resolve(groupContainer: group, wantsTest: true)
        XCTAssertTrue(
            resolution.url.path.hasPrefix(group.path + "/"),
            "Anywhere else is a path a sandboxed build cannot write to"
        )
    }
}
