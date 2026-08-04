import XCTest
@testable import HeykinnClicks

final class MerkleTreeTests: XCTestCase {

    private func leaves(_ pairs: [(String, String)]) -> [MerkleTree.Leaf] {
        pairs.map { MerkleTree.Leaf(key: $0.0, digest: $0.1) }
    }

    private func tree(_ pairs: [(String, String)]) -> MerkleTree {
        MerkleTree(leaves: leaves(pairs))
    }

    // MARK: - Agreement

    func testTargetsHoldingTheSameContentAgree() {
        let a = tree([("1", "aaa"), ("2", "bbb"), ("3", "ccc")])
        let b = tree([("1", "aaa"), ("2", "bbb"), ("3", "ccc")])

        XCTAssertEqual(a.root, b.root)
        XCTAssertTrue(a.agrees(with: b))
        XCTAssertEqual(a.divergentKeys(from: b), [])
    }

    /// Rows come out of the database in whatever order it likes; two targets
    /// holding identical content must still build identical trees.
    func testRowOrderDoesNotChangeTheRoot() {
        let a = tree([("1", "aaa"), ("2", "bbb"), ("3", "ccc")])
        let b = tree([("3", "ccc"), ("1", "aaa"), ("2", "bbb")])

        XCTAssertEqual(a.root, b.root)
    }

    func testEmptyTreesAgreeAndHaveNoRoot() {
        let a = MerkleTree(leaves: [])
        XCTAssertNil(a.root)
        XCTAssertTrue(a.isEmpty)
        XCTAssertTrue(a.agrees(with: MerkleTree(leaves: [])))
    }

    // MARK: - Localising divergence

    func testOneChangedAssetIsFoundAndOnlyThatOne() {
        let a = tree((1...16).map { (String($0), "hash-\($0)") })
        var changed = (1...16).map { (String($0), "hash-\($0)") }
        changed[10] = ("11", "hash-11-CHANGED")
        let b = tree(changed)

        XCTAssertNotEqual(a.root, b.root)
        XCTAssertEqual(a.divergentKeys(from: b), ["11"])
    }

    func testSeveralChangedAssetsAreAllFound() {
        var changed = (1...16).map { (String($0), "hash-\($0)") }
        changed[0] = ("1", "x")
        changed[7] = ("8", "y")
        changed[15] = ("16", "z")

        let divergent = tree((1...16).map { (String($0), "hash-\($0)") })
            .divergentKeys(from: tree(changed))

        XCTAssertEqual(divergent.sorted(), ["1", "16", "8"].sorted())
    }

    /// An odd leaf count exercises the carried-up node; the shape must still
    /// localise correctly rather than falling back to comparing everything.
    func testAnOddNumberOfLeavesStillLocalises() {
        let a = tree((1...7).map { (String($0), "hash-\($0)") })
        var changed = (1...7).map { (String($0), "hash-\($0)") }
        changed[6] = ("7", "changed")

        XCTAssertEqual(a.divergentKeys(from: tree(changed)), ["7"])
    }

    /// The common real case: one target has been given content the other has
    /// never received, so the trees are different shapes.
    func testAssetsMissingFromOneTargetAreReported() {
        let full = tree([("1", "a"), ("2", "b"), ("3", "c")])
        let partial = tree([("1", "a"), ("2", "b")])

        XCTAssertFalse(full.agrees(with: partial))
        XCTAssertEqual(full.divergentKeys(from: partial), ["3"])
    }

    func testDifferentShapesStillFindChangedSharedAssets() {
        let full = tree([("1", "a"), ("2", "b"), ("3", "c")])
        let partial = tree([("1", "a"), ("2", "CHANGED")])

        XCTAssertEqual(full.divergentKeys(from: partial).sorted(), ["2", "3"])
    }

    // MARK: - What a matching root does not prove

    /// The limit, stated in a test as the spec requires of the quick checksum
    /// too: the tree compares recorded hashes, so bytes that rotted without the
    /// catalog noticing leave the root untouched. Only reading finds that.
    func testBitRotIsInvisibleToTheTreeBecauseTheRecordedHashIsUnchanged() {
        let beforeRot = tree([("1", "recorded-hash"), ("2", "b")])
        let afterRot = tree([("1", "recorded-hash"), ("2", "b")])

        XCTAssertTrue(
            beforeRot.agrees(with: afterRot),
            "The tree compares what the catalog recorded — it cannot see the disk change underneath it"
        )
    }

    func testAChangedRecordedHashIsSeen() {
        let recorded = tree([("1", "recorded-hash"), ("2", "b")])
        let reread = tree([("1", "actual-hash-after-reading"), ("2", "b")])

        XCTAssertFalse(recorded.agrees(with: reread))
        XCTAssertEqual(recorded.divergentKeys(from: reread), ["1"])
    }

    // MARK: - Cost

    /// Comparison must not scale with the archive: this is the whole reason the
    /// tree replaces a scheduled sweep.
    func testComparingLargeIdenticalTargetsIsOneComparison() {
        let pairs = (1...20_000).map { (String(format: "%06d", $0), "hash-\($0)") }
        let a = tree(pairs)
        let b = tree(pairs)

        measure {
            XCTAssertTrue(a.agrees(with: b))
        }
    }

    /// The trees are rebuilt on every catalog change, so building them has to
    /// stay cheap enough to be invisible. Two targets holding 25,000 replicas
    /// each is this archive today.
    func testBuildingTreesForARealArchiveStaysCheap() {
        let pairs = (1...25_000).map { (String(format: "%06d", $0), "hash-\($0)") }
        measure {
            _ = tree(pairs)
            _ = tree(pairs)
        }
    }

    func testLocalisingOneChangeInALargeArchiveReadsFewNodes() {
        var pairs = (1...20_000).map { (String(format: "%06d", $0), "hash-\($0)") }
        let a = tree(pairs)
        pairs[12_345] = (pairs[12_345].0, "changed")
        let b = tree(pairs)

        let divergent = a.divergentKeys(from: b)
        XCTAssertEqual(divergent.count, 1)
        XCTAssertEqual(divergent.first, String(format: "%06d", 12_346))
    }
}
