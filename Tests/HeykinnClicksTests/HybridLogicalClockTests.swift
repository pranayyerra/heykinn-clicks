import XCTest
@testable import HeykinnClicks

/// The ordering primitive every conflict resolution will rest on.
///
/// Most of these cases are clocks behaving badly, because that is the entire
/// reason the type exists. A correct wall clock needs no hybrid logical clock.
final class HybridLogicalClockTests: XCTestCase {

    /// A clock whose reading the test drives directly.
    private final class FakeClock {
        var millis: Int64
        init(_ millis: Int64) { self.millis = millis }
        var read: () -> Int64 { { [unowned self] in self.millis } }
    }

    // MARK: - Encoding

    /// Fixed values, so another implementation can be held to them.
    func testEncodingIsFixedWidthAndExact() {
        let stamp = HLCTimestamp(wallMillis: 1_700_000_000_000, counter: 42, deviceID: "device-a")
        XCTAssertEqual(stamp.encoded, "001700000000000-000042-device-a")
    }

    func testEncodingRoundTrips() {
        let stamp = HLCTimestamp(wallMillis: 1_700_000_000_000, counter: 7, deviceID: UUID().uuidString)
        XCTAssertEqual(HLCTimestamp.decode(stamp.encoded), stamp)
    }

    /// A device id containing hyphens — every UUID does — must survive the
    /// split. This is the obvious way to get the parser wrong.
    func testDeviceIDsContainingHyphensSurvive() {
        let id = "9F3C1A20-4B77-4E0E-9B41-2C5D6E7F8A90"
        let stamp = HLCTimestamp(wallMillis: 1, counter: 2, deviceID: id)
        XCTAssertEqual(HLCTimestamp.decode(stamp.encoded)?.deviceID, id)
    }

    func testMalformedStampsDecodeToNil() {
        for text in [
            "",
            "not-a-stamp",
            "1700000000000-42-device",          // fields not padded
            "001700000000000-000042",        // no device id
            "001700000000000-000042-",       // empty device id
            "00170000000000x-000042-device",    // non-numeric wall time
        ] {
            XCTAssertNil(HLCTimestamp.decode(text), "\"\(text)\" should not parse")
        }
    }

    /// The encoding exists so that implementations which never parse it still
    /// sort it correctly. If text order ever diverges from `<`, that promise is
    /// broken.
    func testTextOrderMatchesValueOrder() {
        let stamps = [
            HLCTimestamp(wallMillis: 9, counter: 0, deviceID: "a"),
            HLCTimestamp(wallMillis: 10, counter: 0, deviceID: "a"),
            HLCTimestamp(wallMillis: 10, counter: 1, deviceID: "a"),
            HLCTimestamp(wallMillis: 10, counter: 1, deviceID: "b"),
            HLCTimestamp(wallMillis: 100, counter: 0, deviceID: "a"),
        ]
        XCTAssertEqual(stamps.sorted(), stamps, "Fixture is not in value order")
        XCTAssertEqual(stamps.map(\.encoded).sortedByBytes(), stamps.map(\.encoded))
    }

    // MARK: - Ordering

    func testTiesBreakOnDeviceID() {
        let a = HLCTimestamp(wallMillis: 5, counter: 1, deviceID: "device-a")
        let b = HLCTimestamp(wallMillis: 5, counter: 1, deviceID: "device-b")
        XCTAssertTrue(a < b)
        XCTAssertFalse(b < a)
    }

    /// Two devices must resolve an identical pair the same way round. If they
    /// disagree, "later wins" produces two different winners and the archives
    /// never converge.
    func testEveryDeviceBreaksATieIdentically() {
        let a = HLCTimestamp(wallMillis: 5, counter: 1, deviceID: "device-a")
        let b = HLCTimestamp(wallMillis: 5, counter: 1, deviceID: "device-b")
        XCTAssertEqual([a, b].max(), [b, a].max())
    }

    // MARK: - Issuing

    func testStampsAdvanceWhileTheClockStandsStill() {
        let clock = FakeClock(1000)
        let hlc = HybridLogicalClock(deviceID: "device-a", physicalNow: clock.read)

        let first = hlc.now()
        let second = hlc.now()
        let third = hlc.now()

        XCTAssertTrue(first < second)
        XCTAssertTrue(second < third)
        XCTAssertEqual(first.wallMillis, 1000)
        XCTAssertEqual([first, second, third].map(\.counter), [0, 1, 2])
    }

    /// NTP corrections, manual changes, dual boots. The stamp must not go
    /// backwards even though the device's clock did.
    func testStampsNeverGoBackwardsWhenTheClockDoes() {
        let clock = FakeClock(10_000)
        let hlc = HybridLogicalClock(deviceID: "device-a", physicalNow: clock.read)
        let before = hlc.now()

        clock.millis = 5_000
        let after = hlc.now()

        XCTAssertTrue(before < after, "A backwards clock must not produce a backwards stamp")
        XCTAssertEqual(after.wallMillis, 10_000, "Wall time holds until real time catches up")
    }

    /// A generator that forgets its state can reissue a stamp it has already
    /// used, which is the one thing the order cannot survive. Resuming is how
    /// that is avoided across a relaunch.
    func testResumingFromStoredStateDoesNotReissueAStamp() {
        let clock = FakeClock(10_000)
        let first = HybridLogicalClock(deviceID: "device-a", physicalNow: clock.read)
        let issued = first.now()

        // Relaunch, with the device's clock now reading earlier.
        clock.millis = 9_000
        let resumed = HybridLogicalClock(
            deviceID: "device-a", resuming: first.persistedState, physicalNow: clock.read
        )

        XCTAssertTrue(issued < resumed.now())
    }

    func testTheCounterCarriesRatherThanWrappingAtItsLimit() {
        let clock = FakeClock(1000)
        let limit = UInt32(999_999)
        let hlc = HybridLogicalClock(
            deviceID: "device-a",
            resuming: HLCTimestamp(wallMillis: 1000, counter: limit, deviceID: "device-a"),
            physicalNow: clock.read
        )

        let next = hlc.now()

        XCTAssertEqual(next.wallMillis, 1001, "Overflow carries into the wall time")
        XCTAssertEqual(next.counter, 0)
    }

    // MARK: - Observing another device

    /// The property that makes the order causal: after seeing a remote change,
    /// everything this device does sorts after it, whatever the clocks say.
    func testAStampIssuedAfterObservingSortsAfterWhatWasObserved() {
        let clock = FakeClock(1000)
        let hlc = HybridLogicalClock(deviceID: "device-a", physicalNow: clock.read)

        // A drive delivers something written when this device's clock was well
        // behind — the ordinary case for metadata carried on a drive.
        let remote = HLCTimestamp(wallMillis: 50_000, counter: 3, deviceID: "device-b")
        let mine = hlc.observe(remote)

        XCTAssertTrue(remote < mine)
        XCTAssertEqual(mine.wallMillis, 50_000)
        XCTAssertEqual(mine.deviceID, "device-a", "Observing never adopts the other device's identity")
    }

    /// A change written weeks ago is normal here, not an anomaly, and must not
    /// drag this device's clock backwards.
    func testObservingAnOldStampDoesNotMoveTheClockBackwards() {
        let clock = FakeClock(1_000_000)
        let hlc = HybridLogicalClock(deviceID: "device-a", physicalNow: clock.read)
        let ancient = HLCTimestamp(wallMillis: 1000, counter: 0, deviceID: "device-b")

        let mine = hlc.observe(ancient)

        XCTAssertEqual(mine.wallMillis, 1_000_000)
        XCTAssertTrue(ancient < mine)
    }

    /// The bound that stops one broken clock capturing the archive. Without it
    /// every device would advance to 2099 and stay there, and every later
    /// conflict would resolve in favour of whoever was wrong.
    func testAStampFromTheFarFutureIsRefused() {
        let clock = FakeClock(1_000_000)
        let hlc = HybridLogicalClock(deviceID: "device-a", physicalNow: clock.read)
        let wrong = HLCTimestamp(
            wallMillis: 1_000_000 + HybridLogicalClock.maximumDriftMillis + 1,
            counter: 0,
            deviceID: "device-broken"
        )

        let mine = hlc.observe(wrong)

        XCTAssertEqual(mine.wallMillis, 1_000_000, "This device's clock must not be dragged forward")
        XCTAssertEqual(hlc.refusedFutureStamps, [wrong], "And it has to be reportable, not silent")
    }

    /// Inside the bound, a modestly-fast peer is believed — that is ordinary
    /// drift, not a broken clock.
    func testAStampInsideTheDriftBoundIsAccepted() {
        let clock = FakeClock(1_000_000)
        let hlc = HybridLogicalClock(deviceID: "device-a", physicalNow: clock.read)
        let slightlyAhead = HLCTimestamp(wallMillis: 1_060_000, counter: 0, deviceID: "device-b")

        let mine = hlc.observe(slightlyAhead)

        XCTAssertEqual(mine.wallMillis, 1_060_000)
        XCTAssertTrue(hlc.refusedFutureStamps.isEmpty)
    }

    // MARK: - Convergence

    /// Two devices exchanging stamps through a drive, repeatedly, must keep a
    /// strictly increasing order with no duplicates — which is the whole
    /// contract.
    func testTwoDevicesTradingStampsNeverCollide() {
        let clockA = FakeClock(1000)
        let clockB = FakeClock(900)   // deliberately behind
        let a = HybridLogicalClock(deviceID: "device-a", physicalNow: clockA.read)
        let b = HybridLogicalClock(deviceID: "device-b", physicalNow: clockB.read)

        var issued: [HLCTimestamp] = []
        for round in 0..<50 {
            issued.append(a.now())
            issued.append(b.observe(issued.last!))
            issued.append(b.now())
            issued.append(a.observe(issued.last!))
            // The clocks drift independently and sometimes stand still.
            clockA.millis += Int64(round % 3)
            clockB.millis += Int64(round % 2)
        }

        XCTAssertEqual(Set(issued).count, issued.count, "A stamp was issued twice")
        XCTAssertEqual(issued.sorted(), issued, "Stamps were not issued in increasing order")
    }
}
