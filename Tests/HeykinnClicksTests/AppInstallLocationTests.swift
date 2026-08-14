import XCTest
@testable import HeykinnClicks

/// Where the app is running from, which turns out to decide whether it can have
/// permission for anything.
///
/// Found on a clean account: opened straight from the mounted installer, the
/// app was refused Photos access with no prompt and never appeared in System
/// Settings. macOS translocates an app launched from a disk image — runs it
/// from a randomised read-only path — and refuses a translocated app every
/// grant there is. From inside the app that is indistinguishable from somebody
/// having declined, which is exactly what it used to say.
final class AppInstallLocationTests: XCTestCase {

    func testATranslocatedCopyIsRecognised() {
        let url = URL(fileURLWithPath: "/private/var/folders/xy/AppTranslocation/A1B2-C3/d/HeykinnClicks.app")
        XCTAssertEqual(AppInstallLocation.problem(bundleURL: url), .translocated)
    }

    /// The advice has to be the thing that actually helps. "Grant it in System
    /// Settings" is the one instruction guaranteed to fail here.
    func testTheAdviceIsToMoveTheAppNotToChangeASetting() {
        let problem = try? XCTUnwrap(
            AppInstallLocation.problem(
                bundleURL: URL(fileURLWithPath: "/private/var/folders/x/AppTranslocation/z/HeykinnClicks.app")
            )
        )
        let explanation = problem?.explanation ?? ""
        XCTAssertTrue(explanation.contains("Applications"), explanation)
        XCTAssertFalse(
            explanation.contains("System Settings"),
            "Sending somebody to a pane where nothing helps is what this replaces: \(explanation)"
        )
        XCTAssertTrue(
            problem?.headline.contains("Move") ?? false,
            "The headline is the instruction"
        )
    }

    /// An ordinary install is not a problem, and must not be reported as one.
    func testAnAppInApplicationsIsFine() throws {
        // /Applications is on the writable data volume.
        let applications = URL(fileURLWithPath: "/Applications", isDirectory: true)
        try XCTSkipUnless(FileManager.default.fileExists(atPath: applications.path))
        XCTAssertNil(AppInstallLocation.problem(bundleURL: applications))
    }

    /// Modern macOS mounts a read-only system volume at "/", and every app on
    /// the machine would otherwise be reported as unrunnable.
    func testTheReadOnlySystemVolumeIsNotMistakenForADiskImage() {
        XCTAssertNil(AppInstallLocation.problem(bundleURL: URL(fileURLWithPath: "/")))
    }

    /// A build running from the repository, which is where every test and every
    /// `swift run` happens.
    func testABuiltCopyInTheRepositoryIsFine() throws {
        let build = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        XCTAssertNil(AppInstallLocation.problem(bundleURL: build))
    }
}

/// A read-only volume cannot hold copies, so it cannot be a device — and the
/// app's own installer is a mounted read-only volume, sitting in the list at
/// the moment somebody first goes looking for a drive to register.
@MainActor
final class ReadOnlyTargetTests: XCTestCase {

    private var suiteNames: [String] = []

    override func tearDown() {
        for name in suiteNames { UserDefaults.standard.removePersistentDomain(forName: name) }
        suiteNames = []
        super.tearDown()
    }

    private func makeStore() throws -> AppStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("heykinn-ro-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let suiteName = "heykinn-tests-\(UUID().uuidString)"
        suiteNames.append(suiteName)
        return AppStore(environment: AppEnvironment(
            appDirectory: directory,
            defaults: UserDefaults(suiteName: suiteName)!,
            runsBackgroundWork: false
        ))
    }

    func testAReadOnlyVolumeIsRefusedBeforeAnythingIsWritten() throws {
        let store = try makeStore()
        let volume = VolumeInfo(
            url: URL(fileURLWithPath: "/Volumes/Heykinn Clicks", isDirectory: true),
            name: "Heykinn Clicks",
            volumeUUID: nil,
            isRemovable: true,
            isReadOnly: true,
            marker: nil
        )

        store.registerVolumeTarget(volume: volume, name: "Heykinn Clicks")

        let error = try XCTUnwrap(store.lastError)
        XCTAssertTrue(error.contains("read-only"), error)
        XCTAssertTrue(error.contains("eject"), "Must say what to do: \(error)")
        // The filesystem's own words are what this replaces — a message about
        // failing to save a dotfile, describing the symptom of a decision
        // nobody realised they had made.
        XCTAssertFalse(error.contains(".heykinn-clicks-drive.json"), error)
        XCTAssertTrue(store.targets.isEmpty, "Nothing was registered")
    }

    /// A failed action is not a remembered answer. Otherwise the next mount
    /// would stay silent even though the drive never became a target.
    func testAFailedManagedDecisionIsNotRemembered() throws {
        let store = try makeStore()
        let volume = VolumeInfo(
            url: URL(fileURLWithPath: "/Volumes/Read Only Review Drive", isDirectory: true),
            name: "Read Only Review Drive",
            volumeUUID: "READ-ONLY-REVIEW",
            isRemovable: true,
            isReadOnly: true,
            marker: nil
        )

        XCTAssertFalse(store.decide(.manage, for: volume, remember: true))
        XCTAssertNil(store.accessGrants.decision(forKey: "READ-ONLY-REVIEW"))
        XCTAssertTrue(store.targets.isEmpty)
    }

    func testAWritableVolumeIsNotRefusedForThisReason() throws {
        let store = try makeStore()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("heykinn-writable-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

        store.registerVolumeTarget(
            volume: VolumeInfo(
                url: directory, name: "Field Drive", volumeUUID: nil,
                isRemovable: true, isReadOnly: false, marker: nil
            ),
            name: "Field Drive"
        )

        XCTAssertFalse(
            store.lastError?.contains("read-only") ?? false,
            "A writable place must not be refused for being read-only: \(store.lastError ?? "")"
        )
        XCTAssertEqual(store.targets.count, 1, "A writable place registers")
        let targetID = try XCTUnwrap(store.targets.first?.id)
        XCTAssertTrue(
            store.targetBookmarks.hasBookmark(for: targetID),
            "Registration must persist the permission needed to find the target after relaunch"
        )
    }

    func testOnlyTheDriveRootSatisfiesARegistrationGrant() {
        let root = URL(fileURLWithPath: "/Volumes/Field Drive", isDirectory: true)
        let folder = root.appendingPathComponent("Pictures", isDirectory: true)

        XCTAssertTrue(AppStore.isSameVolumeRoot(root, root))
        XCTAssertFalse(
            AppStore.isSameVolumeRoot(folder, root),
            "Picking a folder on the drive does not grant the drive root or the replica folder beside it"
        )
    }
}
