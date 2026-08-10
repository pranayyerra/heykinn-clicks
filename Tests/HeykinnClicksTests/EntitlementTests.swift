import XCTest
@testable import HeykinnClicks

/// The entitlement files that ship, checked as source.
///
/// This exists because of a day spent looking in the wrong places. The app was
/// refused the Photos library on a clean account with no prompt and no entry in
/// System Settings, and the cause was a single missing key in the Developer ID
/// entitlements — `personal-information.photos-library`, which is a **Hardened
/// Runtime** entitlement as much as a sandbox one, and this app runs hardened
/// because notarisation requires it.
///
/// It hid for months because `swift run` produces a bare binary with no
/// hardened runtime, so development always worked. Only the bundled, signed,
/// notarised build — the one users get — was refused, and it was refused
/// silently, which is indistinguishable from somebody declining.
///
/// A unit test cannot check a signature. It can check that the file the signing
/// step reads still says the right thing, which is where the mistake was.
final class EntitlementTests: XCTestCase {

    private func entitlements(_ name: String) throws -> [String: Any] {
        // Tests run from the package root.
        let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Packaging/\(name)")
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: url.path),
            "not running from the package root"
        )
        let data = try Data(contentsOf: url)
        let parsed = try PropertyListSerialization.propertyList(from: data, format: nil)
        return try XCTUnwrap(parsed as? [String: Any])
    }

    private static let photosKey = "com.apple.security.personal-information.photos-library"

    /// Both builds read the Photos library, so both have to ask for it. The
    /// sandboxed one needs it for the sandbox; the other needs it for the
    /// hardened runtime. Same key, two reasons, and it was only ever in one.
    func testBothBuildsAskForThePhotosLibrary() throws {
        for file in ["HeykinnClicks.entitlements", "HeykinnClicks-AppStore.entitlements"] {
            let values = try entitlements(file)
            XCTAssertEqual(
                values[Self.photosKey] as? Bool, true,
                "\(file) does not ask for the Photos library. macOS will refuse it with no prompt, and the app will not appear under Privacy & Security → Photos."
            )
        }
    }

    /// One archive, however the app was installed. If either build stops
    /// declaring the group, that build quietly keeps a catalog of its own and
    /// somebody ends up owning two halves of one archive.
    func testBothBuildsJoinTheSameAppGroup() throws {
        let expected = ArchiveLocation.appGroupIdentifier
        for file in ["HeykinnClicks.entitlements", "HeykinnClicks-AppStore.entitlements"] {
            let values = try entitlements(file)
            let groups = values["com.apple.security.application-groups"] as? [String]
            XCTAssertEqual(
                groups, [expected],
                "\(file) must join \(expected), or it keeps an archive of its own"
            )
        }
    }

    /// The distinction the two files exist for.
    func testOnlyTheAppStoreBuildIsSandboxed() throws {
        XCTAssertEqual(
            try entitlements("HeykinnClicks.entitlements")["com.apple.security.app-sandbox"] as? Bool,
            false,
            "The Developer ID build must not be sandboxed; the drive sweep depends on it"
        )
        XCTAssertEqual(
            try entitlements("HeykinnClicks-AppStore.entitlements")["com.apple.security.app-sandbox"] as? Bool,
            true,
            "The App Store build must be sandboxed; Apple requires it"
        )
    }

    /// A sandboxed app reaches a drive only through something the user chose,
    /// and only keeps that reach across launches through a bookmark.
    func testTheSandboxedBuildCanKeepWhatTheUserPicks() throws {
        let values = try entitlements("HeykinnClicks-AppStore.entitlements")
        for key in [
            "com.apple.security.files.user-selected.read-write",
            "com.apple.security.files.bookmarks.app-scope",
        ] {
            XCTAssertEqual(
                values[key] as? Bool, true,
                "Without \(key) a registered drive has to be picked again on every launch"
            )
        }
    }
}
