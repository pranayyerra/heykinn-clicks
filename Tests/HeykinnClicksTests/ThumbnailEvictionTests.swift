import XCTest
@testable import HeykinnClicks

/// What gets thrown away when the thumbnail tier outgrows its budget.
///
/// One sentence of rule, and it had no test: exercising it meant writing real
/// JPEGs to a real directory and measuring what survived.
final class ThumbnailEvictionTests: XCTestCase {

    private func entry(_ name: String, _ size: Int64, daysOld: Double) -> ThumbnailEviction.Entry {
        ThumbnailEviction.Entry(
            url: URL(fileURLWithPath: "/cache/\(name).jpg"),
            size: size,
            lastUsed: Date(timeIntervalSince1970: 1_700_000_000 - daysOld * 86_400)
        )
    }

    func testNothingGoesWhileItFits() {
        let entries = [entry("a", 40, daysOld: 9), entry("b", 40, daysOld: 1)]
        XCTAssertEqual(ThumbnailEviction.choose(from: entries, budget: 100), [])
    }

    /// **Exactly at the limit is not over it.** A cache sitting on its budget is
    /// working; evicting there would shed a thumbnail every time one was added,
    /// for ever.
    func testSittingExactlyOnTheBudgetIsNotOverflowing() {
        let entries = [entry("a", 50, daysOld: 9), entry("b", 50, daysOld: 1)]
        XCTAssertEqual(ThumbnailEviction.choose(from: entries, budget: 100), [])
    }

    /// Oldest first, and it stops the moment the rest fit — the other way to
    /// get this wrong is to keep going and empty the cache.
    func testTheOldestGoFirstAndOnlyUntilItFits() {
        let entries = [
            entry("newest", 40, daysOld: 1),
            entry("oldest", 40, daysOld: 30),
            entry("middle", 40, daysOld: 10),
        ]
        let chosen = ThumbnailEviction.choose(from: entries, budget: 100)
        XCTAssertEqual(chosen.map(\.url.lastPathComponent), ["oldest.jpg"])
    }

    func testItKeepsGoingWhileStillOver() {
        let entries = [
            entry("newest", 40, daysOld: 1),
            entry("oldest", 40, daysOld: 30),
            entry("middle", 40, daysOld: 10),
        ]
        let chosen = ThumbnailEviction.choose(from: entries, budget: 45)
        XCTAssertEqual(chosen.map(\.url.lastPathComponent), ["oldest.jpg", "middle.jpg"])
    }

    /// Two files stamped in the same second must not evict in whatever order
    /// the filesystem happened to list them: the same archive should shed the
    /// same thumbnails twice.
    func testTiesBreakTheSameWayEveryTime() {
        let same = Date(timeIntervalSince1970: 1_700_000_000)
        let entries = ["c", "a", "b"].map {
            ThumbnailEviction.Entry(url: URL(fileURLWithPath: "/cache/\($0).jpg"), size: 40, lastUsed: same)
        }
        let first = ThumbnailEviction.choose(from: entries, budget: 50)
        let again = ThumbnailEviction.choose(from: entries.reversed(), budget: 50)
        XCTAssertEqual(first, again)
        XCTAssertEqual(first.map(\.url.lastPathComponent), ["a.jpg", "b.jpg"])
    }

    /// A budget of nothing means keep nothing — used when the cache is being
    /// cleared outright.
    func testAZeroBudgetEmptiesIt() {
        let entries = [entry("a", 40, daysOld: 9), entry("b", 40, daysOld: 1)]
        XCTAssertEqual(ThumbnailEviction.choose(from: entries, budget: 0).count, 2)
    }

    func testAnEmptyCacheIsFine() {
        XCTAssertEqual(ThumbnailEviction.choose(from: [], budget: 100), [])
        XCTAssertEqual(ThumbnailEviction.choose(from: [], budget: 0), [])
    }
}
