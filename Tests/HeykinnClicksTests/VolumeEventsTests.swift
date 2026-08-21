import XCTest
@testable import HeykinnClicks

/// That drives being plugged in and pulled out reaches the app, without a
/// drive.
///
/// Before the seam this could only be exercised by attaching hardware:
/// `TargetMonitor` subscribed to `NSWorkspace` in its own initialiser, so there
/// was no way to say "a volume just mounted" from a test.
@MainActor
final class VolumeEventsTests: XCTestCase {

    /// Stands in for the platform, so a test can post the events.
    private final class Stub: VolumeEvents {
        var onVolumesChanged: (() -> Void)?
        var onVolumeWillUnmount: ((URL?) -> Void)?
        private(set) var started = false
        private(set) var stopped = false
        func start() { started = true }
        func stop() { stopped = true }
    }

    func testMountingSomethingAsksForARescan() async {
        let events = Stub()
        let monitor = TargetMonitor(events: events)
        XCTAssertTrue(events.started, "nothing subscribed, so nothing would ever be noticed")

        var rescans = 0
        monitor.rescanRequested = { rescans += 1 }
        events.onVolumesChanged?()
        await Task.yield()
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(rescans, 1)
    }

    /// **The warning that has no guaranteed equivalent elsewhere.** macOS says a
    /// volume is going *before* it goes, which is the only chance to stop
    /// reading and let the eject succeed. It has to reach the app with the
    /// volume's own URL, or work on some other drive would be stopped instead.
    func testTheApproachingUnmountArrivesWithTheVolume() async {
        let events = Stub()
        let monitor = TargetMonitor(events: events)

        var warnedAbout: [URL?] = []
        monitor.volumeWillUnmount = { warnedAbout.append($0) }
        let leaving = URL(fileURLWithPath: "/Volumes/Nina's Back")
        events.onVolumeWillUnmount?(leaving)
        await Task.yield()
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(warnedAbout, [leaving])
    }

    /// A platform that cannot say which volume is going may say nothing about
    /// it. That must not be mistaken for a named drive.
    func testAnUnnamedWarningIsPassedThroughAsUnknown() async {
        let events = Stub()
        let monitor = TargetMonitor(events: events)
        var warnedAbout: [URL?] = []
        monitor.volumeWillUnmount = { warnedAbout.append($0) }
        events.onVolumeWillUnmount?(nil)
        await Task.yield()
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(warnedAbout.count, 1)
        XCTAssertNil(warnedAbout.first ?? URL(fileURLWithPath: "/"))
    }
}
