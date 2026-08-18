import XCTest
@testable import HeykinnClicks

/// What the app does when it meets a drive belonging to somebody else's
/// archive.
///
/// Written to check a claim rather than to state one, and the claim was wrong.
/// A stranger's drive is not distinguished from an unclaimed one at the moment
/// it is plugged in: both are simply "not one of mine", and the same prompt
/// appears for each. The protection is real but arrives a step later, when
/// somebody answers "use it as storage" — that is refused, and their ID file
/// survives.
///
/// Pinned here because the gap is in the first screen, not the second.
@MainActor
final class ForeignDriveTests: XCTestCase {

    private var suiteNames: [String] = []
    override func tearDown() {
        for n in suiteNames { UserDefaults.standard.removePersistentDomain(forName: n) }
        suiteNames = []
        super.tearDown()
    }

    private func makeDirectory(_ label: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("own-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func makeStore() throws -> AppStore {
        let dir = try makeDirectory("archive")
        let suite = "heykinn-own-\(UUID().uuidString)"
        suiteNames.append(suite)
        return AppStore(environment: AppEnvironment(
            appDirectory: dir, defaults: UserDefaults(suiteName: suite)!, runsBackgroundWork: false
        ))
    }

    private func volume(_ url: URL, name: String) -> VolumeInfo {
        VolumeInfo(url: url, name: name, volumeUUID: UUID().uuidString,
                   isRemovable: true, isReadOnly: false,
                   marker: TargetMonitor.readMarker(at: url))
    }

    /// Does the app tell a stranger's drive from an unclaimed one?
    func testWhatDistinguishesAForeignDriveFromABlankOne() throws {
        let store = try makeStore()

        let blank = try makeDirectory("blank")
        let foreign = try makeDirectory("foreign")
        try TargetMonitor.writeMarker(
            TargetMarker(targetID: UUID(), markerToken: UUID().uuidString, appName: "heykinn-clicks"),
            to: foreign
        )

        let blankInfo = volume(blank, name: "Blank Drive")
        let foreignInfo = volume(foreign, name: "Their Drive")

        // What the app knows before anybody is asked anything.
        let blankMatch = TargetMonitor.match(volume: blankInfo, against: store.targets)
        let foreignMatch = TargetMonitor.match(volume: foreignInfo, against: store.targets)

        print("""

        ── meeting a drive, today ─────────────────────────────
          blank drive   marker: \(blankInfo.marker == nil ? "none" : "present")   recognised: \(blankMatch == nil ? "no" : "yes")
          their drive   marker: \(foreignInfo.marker == nil ? "none" : "present")   recognised: \(foreignMatch == nil ? "no" : "yes")
        ───────────────────────────────────────────────────────

        """)

        XCTAssertNil(blankMatch)
        XCTAssertNil(foreignMatch, "a stranger's drive is 'not one of mine', same as a blank one")
    }

    /// And what happens if somebody answers "use it as storage" for each.
    func testWhatHappensWhenEachIsAcceptedAsStorage() throws {
        let store = try makeStore()

        let foreign = try makeDirectory("foreign")
        let theirs = TargetMarker(targetID: UUID(), markerToken: UUID().uuidString, appName: "heykinn-clicks")
        try TargetMonitor.writeMarker(theirs, to: foreign)

        let registered = store.registerVolumeTarget(volume: volume(foreign, name: "Their Drive"), name: "Their Drive")

        print("""

        ── answering "use as storage" for a stranger's drive ───
          registered              \(registered)
          warned first            \(store.markerConflict != nil)
          their ID file survived  \(TargetMonitor.readMarker(at: foreign) == theirs)
        ───────────────────────────────────────────────────────

        """)

        XCTAssertFalse(registered)
        XCTAssertNotNil(store.markerConflict)
    }
}
