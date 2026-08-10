import XCTest
@testable import HeykinnClicks

/// One running app per archive.
///
/// Both builds share a catalog on purpose, so two copies of the app can be
/// pointed at the same files — which is exactly what somebody publishing to
/// both the App Store and a website does while testing. SQLite survives that;
/// the app does not, because every screen is drawn from state held in memory
/// and written back whole, so the second instance overwrites the first's work
/// without ever having seen it.
final class ArchiveLockTests: XCTestCase {

    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("heykinn-lock-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testTheFirstInstanceTakesTheArchive() throws {
        let directory = try makeDirectory()
        let lock = ArchiveLock(directory: directory)
        XCTAssertNotNil(lock)
        XCTAssertTrue(FileManager.default.fileExists(atPath: lock!.url.path))
    }

    func testASecondInstanceIsRefused() throws {
        let directory = try makeDirectory()
        let first = ArchiveLock(directory: directory)
        XCTAssertNotNil(first, "the premise: the first one gets it")

        XCTAssertNil(ArchiveLock(directory: directory), "A second app must not open the same archive")
        XCTAssertNotNil(first, "and the first one keeps it")
    }

    /// The lock is released when the holder goes away, so quitting one copy
    /// lets the other in. This is the ordinary case: somebody closes the App
    /// Store build and opens the other one.
    func testTheArchiveIsFreeAgainOnceTheHolderGoes() throws {
        let directory = try makeDirectory()

        do {
            let first = ArchiveLock(directory: directory)
            XCTAssertNotNil(first)
            XCTAssertNil(ArchiveLock(directory: directory))
        }  // first is released here

        XCTAssertNotNil(
            ArchiveLock(directory: directory),
            "A lock that outlived its holder would leave somebody locked out of their own archive"
        )
    }

    /// Two archives are two locks. A publisher testing both routes against
    /// separate directories must not be blocked by their own other instance —
    /// which is the whole reason the override exists.
    func testSeparateArchivesDoNotBlockEachOther() throws {
        let one = try makeDirectory()
        let other = try makeDirectory()

        let first = ArchiveLock(directory: one)
        let second = ArchiveLock(directory: other)

        XCTAssertNotNil(first)
        XCTAssertNotNil(second, "Different archives are independent")
    }

    func testAskingDoesNotTakeTheLock() throws {
        let directory = try makeDirectory()
        XCTAssertFalse(ArchiveLock.isHeldByAnotherProcess(directory: directory))
        // And having asked, it is still available.
        XCTAssertNotNil(ArchiveLock(directory: directory))
    }

    func testAHeldArchiveReportsAsHeld() throws {
        let directory = try makeDirectory()
        let held = ArchiveLock(directory: directory)
        XCTAssertNotNil(held)
        XCTAssertTrue(ArchiveLock.isHeldByAnotherProcess(directory: directory))
    }
}
