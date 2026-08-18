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

    // MARK: - Telling whose it is

    func testTheAppCanSayWhoseDriveItIs() throws {
        let store = try makeStore()

        let blank = try makeDirectory("blank")
        let foreign = try makeDirectory("foreign")
        try TargetMonitor.writeMarker(
            TargetMarker(targetID: UUID(), markerToken: UUID().uuidString, appName: "heykinn-clicks"),
            to: foreign
        )
        let mine = try makeDirectory("mine")

        XCTAssertFalse(
            store.driveBelongsToSomebodyElse(volume(blank, name: "Blank")),
            "an unclaimed drive is nobody's, not somebody else's"
        )
        XCTAssertTrue(store.driveBelongsToSomebodyElse(volume(foreign, name: "Theirs")))

        // Register one properly, and it stops reading as somebody else's.
        XCTAssertTrue(
            store.registerVolumeTarget(volume: volume(mine, name: "Mine"), name: "Mine"),
            "\(store.lastError ?? "no error reported")"
        )
        XCTAssertFalse(
            store.driveBelongsToSomebodyElse(volume(mine, name: "Mine")),
            "a drive this archive registered is its own"
        )
    }

    /// Taking somebody else's drive is the one thing here that changes what is
    /// on it, so it never happens on a single click.
    func testMakingItMineAlwaysAsksFirst() throws {
        let store = try makeStore()
        let foreign = try makeDirectory("foreign")
        let theirs = TargetMarker(
            targetID: UUID(), markerToken: UUID().uuidString, appName: "heykinn-clicks"
        )
        try TargetMonitor.writeMarker(theirs, to: foreign)
        let info = volume(foreign, name: "Their Drive")

        // Choosing it from the connect prompt goes through the same
        // confirmation as choosing it anywhere else. It reports *not* done,
        // because nothing has been registered yet — the question has been
        // handed to the confirmation rather than answered.
        XCTAssertFalse(store.decide(.manage, for: info, remember: false))
        XCTAssertNotNil(store.markerConflict, "it was taken without asking")
        XCTAssertEqual(TargetMonitor.readMarker(at: foreign), theirs, "their ID was replaced without asking")
        XCTAssertTrue(store.targets.isEmpty)

        // And confirming does what it says.
        let conflict = try XCTUnwrap(store.markerConflict)
        XCTAssertTrue(store.takeOverDrive(conflict))
        XCTAssertEqual(store.targets.count, 1)
        XCTAssertNotEqual(TargetMonitor.readMarker(at: foreign), theirs)
    }

    /// The words on these two screens are the only ones a person sees about
    /// this, and they may not be ours.
    func testNeitherScreenUsesAWordTheAppInvented() throws {
        let ui = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/HeykinnClicks/UI", isDirectory: true)

        for name in ["DriveConnectPrompt.swift", "DriveMarkerConflictPrompt.swift"] {
            let text = try String(contentsOf: ui.appendingPathComponent(name), encoding: .utf8)
            for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
                // Comments carry our vocabulary on purpose; the screen may not.
                guard !line.trimmingCharacters(in: .whitespaces).hasPrefix("//"),
                      !line.trimmingCharacters(in: .whitespaces).hasPrefix("///") else { continue }
                for quoted in line.split(separator: "\"").enumerated()
                    .filter({ $0.offset % 2 == 1 }).map(\.element) where quoted.count > 12 {
                    for invented in ["archive", "target", "replica", "marker", "registered", "managed"] {
                        XCTAssertFalse(
                            quoted.lowercased().contains(invented),
                            "\(name) says \"\(invented)\" to the reader: \(quoted)"
                        )
                    }
                }
            }
        }
    }

    // MARK: - What a person is actually asked

    /// Closing the prompt is a real answer and is remembered, which is why
    /// there is no longer a "remember this" toggle: the question does not come
    /// back, so there is nothing to opt into.
    ///
    /// The wiring above this — skipping the prompt entirely for somebody
    /// else's drive — reads real mounted volumes and is checked by running the
    /// app rather than here.
    func testClosingThePromptIsRememberedAsNo() throws {
        let store = try makeStore()
        let blank = try makeDirectory("blank")
        let info = volume(blank, name: "New Drive")

        XCTAssertTrue(store.decide(.ignore, for: info, remember: true))

        let key = AccessGrants.key(forVolumeUUID: info.volumeUUID, path: info.url.path)
        XCTAssertEqual(
            store.accessGrantList.first(where: { $0.volumeKey == key })?.decision, .ignore,
            "closing did not record an answer, so the drive would be asked about again"
        )
        XCTAssertTrue(store.targets.isEmpty)
    }
}
