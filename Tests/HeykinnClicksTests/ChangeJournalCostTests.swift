import XCTest
@testable import HeykinnClicks

/// What the journal costs on the path that matters.
///
/// `storage_groups` has six columns and a handful of rows, so stamping it is
/// free by inspection. `assets` has twenty-nine, and a reference archive of
/// 20,000 of them is written in one go during an import — the one path a user
/// actually waits for.
///
/// These were written before the code they measure, and twice earned it. The
/// first run said a per-column stamp cost 16× and 29 rows per asset, which is
/// why creations are recorded as one whole-row entry. The first-sync case said a
/// new device meeting that archive would take **over five minutes**, which is
/// how the missing transaction and a quadratic scan in the merge were found.
///
/// Kept as absolute seconds against a real archive size rather than as ratios,
/// so they fail when a person would notice rather than when a number moves.
final class ChangeJournalCostTests: XCTestCase {

    private func makeCatalog(_ label: String) throws -> CatalogStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("heykinn-cost-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return try CatalogStore(databasePath: directory.appendingPathComponent("catalog.sqlite").path)
    }

    private func makeAsset() -> Asset {
        Asset(
            id: UUID(), kind: .photo, originalFilename: "IMG_0001.HEIC",
            importOrigin: .googleTakeout, captureDate: Date(), importDate: Date(),
            updatedDate: Date(), fileSize: 3_400_000, pixelWidth: 4032, pixelHeight: 3024,
            contentHash: UUID().uuidString, residency: .local, residencySource: .importDefault,
            presence: .localOnly, stagingRelativePath: "2026/08/IMG_0001.HEIC",
            importBatchID: UUID(), exifSummary: ["Make": "Apple", "Model": "iPhone 15 Pro"]
        )
    }

    /// The same insert `upsertAsset` performs, with no journal involvement, so
    /// the comparison is journalling against not journalling.
    private func insertWithoutJournalling(_ asset: Asset, into catalog: CatalogStore) throws {
        try catalog.database.run("""
        INSERT INTO assets (id, kind, original_filename, import_origin, capture_date,
            import_date, updated_date, file_size, pixel_width, pixel_height, content_hash,
            residency, residency_source, presence_local, presence_apple, presence_google,
            staging_relpath, import_batch_id, exif_json)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?);
        """, [
            .text(asset.id.uuidString), .text(asset.kind.rawValue),
            .text(asset.originalFilename), .text(asset.importOrigin.rawValue),
            .date(asset.captureDate), .date(asset.importDate), .date(asset.updatedDate),
            .int(asset.fileSize), .optionalInt(asset.pixelWidth.map(Int64.init)),
            .optionalInt(asset.pixelHeight.map(Int64.init)), .text(asset.contentHash),
            .text(asset.residency.rawValue), .text(asset.residencySource.rawValue),
            .bool(asset.presence.local), .bool(asset.presence.appleCloud), .bool(asset.presence.googleCloud),
            .optionalText(asset.stagingRelativePath),
            .optionalText(asset.importBatchID?.uuidString), .text("{}"),
        ])
    }

    private func time(_ body: () throws -> Void) rethrows -> TimeInterval {
        let started = Date()
        try body()
        return Date().timeIntervalSince(started)
    }

    /// Not an assertion about wall-clock speed — CI devices vary too much for
    /// that to mean anything. It reports the ratio and the row count, and fails
    /// only on a result bad enough to be a design problem rather than a
    /// slowdown.
    func testStampingEveryColumnOfAFreshImport() throws {
        let count = 2_000

        let assets = (0..<count).map { _ in makeAsset() }

        // The baseline has to go around `upsertAsset`, because that is itself
        // journalled now — wrapping it again would measure double bookkeeping
        // against single, which is a number about this test rather than about
        // the app. This writes the same row with the same statement and no
        // stamping at all.
        let plain = try makeCatalog("plain")
        let baseline = try time {
            try plain.transaction {
                for asset in assets { try insertWithoutJournalling(asset, into: plain) }
            }
        }

        let journaled = try makeCatalog("journaled")
        let withJournal = try time {
            try journaled.transaction {
                for asset in assets { try journaled.upsertAsset(asset) }
            }
        }

        let stampRows = try journaled.database.query(
            "SELECT count(*) FROM change_field_versions;"
        ) { $0.int(0) }.first ?? 0
        let ratio = withJournal / max(baseline, 0.0001)

        print("""

        ── journal cost, \(count) fresh assets ──────────────────────
          without journal : \(String(format: "%.3f", baseline))s
          with journal    : \(String(format: "%.3f", withJournal))s  (\(String(format: "%.1f", ratio))×)
          stamp rows      : \(stampRows)  (\(stampRows / Int64(count)) per asset)
          extrapolated to 20,000 assets: \
        \(String(format: "%.1f", withJournal / Double(count) * 20_000))s, \
        \(stampRows / Int64(count) * 20_000) stamp rows
        ────────────────────────────────────────────────────────────

        """)

        XCTAssertGreaterThan(stampRows, 0, "Nothing was stamped, so this measured nothing")
        // One entry per new row, not one per column. Stamping each column
        // separately measured 16× and 29 rows per asset; this is the whole
        // reason `ChangeJournal.wholeRow` exists, so a regression here is a
        // regression in that, not a number to re-tune.
        XCTAssertEqual(stampRows, Int64(count), "A new row should cost exactly one stamp entry")

        // Asserted in seconds, not as a multiple.
        //
        // The ratio is reported because it is interesting, but it is a poor
        // threshold: the baseline is a bare INSERT at about ten microseconds, so
        // any bookkeeping at all looks like a large multiple of it while costing
        // a user nothing. What a person actually experiences is the extra
        // seconds on an import they asked for, so that is what this holds to.
        XCTAssertLessThan(
            withJournal / Double(count) * 20_000, 15.0,
            "Journalling would add real time to an import of this archive"
        )
    }

    /// The path nobody has measured: a new device meeting a full archive for
    /// the first time.
    ///
    /// Importing is slow once, on a device the user is sitting in front of
    /// having just asked for it. A first sync is slow on a device that has
    /// just had a drive plugged into it, and one asset is roughly 29 records,
    /// so this is the merge doing hundreds of thousands of small pieces of work.
    func testFirstSyncOntoAFreshDevice() throws {
        let count = 2_000

        let source = try makeCatalog("source")
        try source.transaction {
            for _ in 0..<count { try source.upsertAsset(makeAsset()) }
        }
        let records = try source.journal.changes(since: nil)

        let destination = try makeCatalog("destination")
        let elapsed = try time {
            try destination.journal.merge(records)
        }

        print("""

        ── first sync, \(count) assets ──────────────────────────────
          records         : \(records.count)
          merge           : \(String(format: "%.3f", elapsed))s
          extrapolated to 20,000 assets: \
        \(String(format: "%.1f", elapsed / Double(count) * 20_000))s
        ────────────────────────────────────────────────────────────

        """)

        XCTAssertEqual(try destination.fetchAssets().count, count, "The archive did not arrive")
        XCTAssertLessThan(
            elapsed / Double(count) * 20_000, 60.0,
            "A first sync of this archive would take over a minute"
        )
    }

    /// The other half of the picture: updating one column of an existing row
    /// must stamp one field, not twenty-seven. If this regresses, the journal
    /// has quietly gone back to row-scoped stamping.
    func testUpdatingOneColumnStampsOneField() throws {
        let catalog = try makeCatalog("update")
        var asset = makeAsset()
        try catalog.journal.recordingWrite(
            table: "assets", rowID: ChangeJournal.rowID([asset.id.uuidString])
        ) {
            try catalog.upsertAsset(asset)
        }

        asset.residency = .appleCloud
        try catalog.journal.recordingWrite(
            table: "assets", rowID: ChangeJournal.rowID([asset.id.uuidString])
        ) {
            try catalog.upsertAsset(asset)
        }

        // One stamp is newer than the rest: the column that moved.
        let stamps = try catalog.database.query(
            "SELECT column_name, hlc FROM change_field_versions WHERE table_name = 'assets';"
        ) { (column: $0.text(0), hlc: $0.text(1)) }
        let newest = stamps.map(\.hlc).max()
        let movedColumns = stamps.filter { $0.hlc == newest }.map(\.column).sorted()

        XCTAssertEqual(
            movedColumns, ["residency"],
            "An update stamped \(movedColumns.count) columns; only `residency` changed"
        )
    }

    /// A re-import that changes nothing must produce no news at all. Otherwise
    /// every routine rescan would look to every other device like the whole
    /// archive had been rewritten.
    func testRewritingAnUnchangedRowStampsNothingNew() throws {
        let catalog = try makeCatalog("noop")
        let asset = makeAsset()
        let rowID = ChangeJournal.rowID([asset.id.uuidString])
        try catalog.journal.recordingWrite(table: "assets", rowID: rowID) {
            try catalog.upsertAsset(asset)
        }
        let before = try catalog.journal.changes(since: nil).map(\.stamp).max()

        try catalog.journal.recordingWrite(table: "assets", rowID: rowID) {
            try catalog.upsertAsset(asset)
        }
        let after = try catalog.journal.changes(since: nil).map(\.stamp).max()

        XCTAssertEqual(before, after, "An unchanged rewrite produced a new stamp")
    }
}
