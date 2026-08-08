import XCTest
@testable import HeykinnClicks

/// Keeping everything the provider sent, so the zips become disposable.
///
/// The payloads here are the real shape from `takeout-20260710T081521Z-2-001`,
/// not an invention: the newer `*.jpg.supplemental-metadata.json` naming, and
/// the fields an actual export carries.
final class MetadataCaptureTests: XCTestCase {

    private var roots: [URL] = []

    override func tearDown() {
        for url in roots { try? FileManager.default.removeItem(at: url) }
        roots = []
        super.tearDown()
    }

    private func makeCatalog() throws -> CatalogStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("heykinn-meta-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        roots.append(directory)
        return try CatalogStore(databasePath: directory.appendingPathComponent("catalog.sqlite").path)
    }

    /// A real asset sidecar, as Google writes it.
    private let assetPayload = """
    {"title":"IMG_0001_o.jpg","description":"","imageViews":"10",\
    "creationTime":{"timestamp":"1501424012","formatted":"Jul 30, 2017"},\
    "photoTakenTime":{"timestamp":"1500986614","formatted":"Jul 25, 2017"},\
    "geoData":{"latitude":0.0,"longitude":0.0,"altitude":0.0,"latitudeSpan":0.0,"longitudeSpan":0.0},\
    "url":"https://photos.google.com/photo/AF1Qip","googlePhotosOrigin":{"webUpload":{"computerUpload":{}}}}
    """

    /// A real album `metadata.json`.
    private let albumPayload = """
    {"title":"Kodaikanal","description":"","access":"protected",\
    "date":{"timestamp":"1501424012","formatted":"Jul 30, 2017"}}
    """

    private func record(
        payload: String,
        assetID: UUID? = UUID(),
        sourceID: UUID,
        scope: MetadataRecord.Scope = .asset,
        path: String = "Takeout/Google Photos/Photos from 2017/IMG_0001.jpg.supplemental-metadata.json"
    ) -> MetadataRecord {
        MetadataRecord(
            id: UUID(),
            assetID: assetID,
            sourceID: sourceID,
            scope: scope,
            provider: "google",
            originPath: path,
            capturedAt: Date(),
            schemaFingerprint: MetadataRecord.fingerprint(of: payload),
            payload: payload
        )
    }

    // MARK: - Kept verbatim

    /// The whole point: what the importer ignores is still there afterwards.
    /// `imageViews`, `url` and `googlePhotosOrigin` are read by nothing and
    /// must survive anyway — recovering them otherwise means the 127 GB
    /// download the archive exists to stop depending on.
    func testEverythingTheImporterIgnoresIsStillThere() throws {
        let catalog = try makeCatalog()
        let sourceID = UUID()
        let stored = record(payload: assetPayload, sourceID: sourceID)

        try catalog.upsertMetadataRecord(stored)

        let assetID = try XCTUnwrap(stored.assetID)
        let read = try XCTUnwrap(try catalog.fetchMetadataRecords(forAsset: assetID).first)
        XCTAssertEqual(read.payload, assetPayload, "byte for byte, unparsed")

        let json = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(read.payload.utf8)) as? [String: Any]
        )
        XCTAssertEqual(json["imageViews"] as? String, "10")
        XCTAssertNotNil(json["url"], "dropped by the importer, kept here")
        XCTAssertNotNil(json["googlePhotosOrigin"])
        XCTAssertNotNil(json["creationTime"], "upload time, distinct from capture time")
    }

    /// Album membership is not a field — it is the directory a file sits in.
    /// Storing payloads without their path would still lose it.
    func testTheOriginPathIsKeptBecauseAlbumMembershipLivesInIt() throws {
        let catalog = try makeCatalog()
        let sourceID = UUID()
        let path = "Takeout/Google Photos/Kodaikanal/metadata.json"

        try catalog.upsertMetadataRecord(record(
            payload: albumPayload, assetID: nil, sourceID: sourceID, scope: .album, path: path
        ))

        let albums = try catalog.fetchMetadataRecords(forSource: sourceID, scope: .album)
        XCTAssertEqual(albums.count, 1)
        XCTAssertEqual(albums[0].originPath, path)
        XCTAssertNil(albums[0].assetID, "an album is about a set, not a photo")
    }

    /// Re-reading an export you already have replaces each payload rather than
    /// piling a second copy beside it.
    func testReadingTheSameExportTwiceDoesNotDoubleIt() throws {
        let catalog = try makeCatalog()
        let sourceID = UUID()
        let path = "Takeout/Google Photos/Photos from 2017/IMG_0001.jpg.supplemental-metadata.json"

        try catalog.upsertMetadataRecord(record(payload: assetPayload, sourceID: sourceID, path: path))
        let revised = assetPayload.replacingOccurrences(of: "\"imageViews\":\"10\"", with: "\"imageViews\":\"11\"")
        try catalog.upsertMetadataRecord(record(payload: revised, sourceID: sourceID, path: path))

        XCTAssertEqual(try catalog.metadataRecordCount(), 1)
        let all = try catalog.fetchMetadataRecords(forSource: sourceID)
        XCTAssertEqual(all.count, 1)
        XCTAssertTrue(all[0].payload.contains("\"imageViews\":\"11\""), "the newer read wins")
    }

    /// Two exports can hold the same relative path without colliding.
    func testTwoSourcesMayHoldTheSamePath() throws {
        let catalog = try makeCatalog()
        let first = UUID(), second = UUID()
        let path = "Takeout/Google Photos/Photos from 2017/IMG_0001.jpg.supplemental-metadata.json"

        try catalog.upsertMetadataRecord(record(payload: assetPayload, sourceID: first, path: path))
        try catalog.upsertMetadataRecord(record(payload: assetPayload, sourceID: second, path: path))

        XCTAssertEqual(try catalog.metadataRecordCount(), 2)
    }

    // MARK: - Noticing a format change

    /// Same keys, different values — one shape. Otherwise every photo would be
    /// its own "format" and the census would say nothing.
    func testPayloadsWithTheSameKeysShareAFingerprint() {
        let other = assetPayload
            .replacingOccurrences(of: "IMG_0001_o.jpg", with: "IMG_0002_o.jpg")
            .replacingOccurrences(of: "\"imageViews\":\"10\"", with: "\"imageViews\":\"4823\"")
        XCTAssertEqual(
            MetadataRecord.fingerprint(of: assetPayload),
            MetadataRecord.fingerprint(of: other)
        )
    }

    /// A key nobody has seen is a different shape, which is what makes it
    /// reportable rather than silent.
    func testANewKeyIsANewFingerprint() {
        let withNewKey = assetPayload.replacingOccurrences(
            of: "{\"title\"", with: "{\"favorited\":true,\"title\""
        )
        XCTAssertNotEqual(
            MetadataRecord.fingerprint(of: assetPayload),
            MetadataRecord.fingerprint(of: withNewKey)
        )
    }

    /// The census counts shapes and keeps one path per shape to go and look at.
    func testTheCensusCountsShapesAndKeepsAnExample() throws {
        let catalog = try makeCatalog()
        let sourceID = UUID()

        for index in 0..<3 {
            try catalog.upsertMetadataRecord(record(
                payload: assetPayload, sourceID: sourceID,
                path: "Takeout/Google Photos/Photos from 2017/IMG_000\(index).json"
            ))
        }
        let withNewKey = assetPayload.replacingOccurrences(
            of: "{\"title\"", with: "{\"favorited\":true,\"title\""
        )
        try catalog.upsertMetadataRecord(record(
            payload: withNewKey, sourceID: sourceID,
            path: "Takeout/Google Photos/Photos from 2019/IMG_9999.json"
        ))

        let schemas = try catalog.fetchMetadataSchemas()
        XCTAssertEqual(schemas.count, 2, "two shapes seen")
        XCTAssertEqual(schemas[0].recordCount, 3, "commonest first")
        XCTAssertEqual(schemas[1].recordCount, 1)
        XCTAssertTrue(schemas[1].keys.contains("favorited"), "the unfamiliar shape names its keys")
        XCTAssertEqual(
            schemas[1].examplePath,
            "Takeout/Google Photos/Photos from 2019/IMG_9999.json",
            "with somewhere to go and look"
        )
    }

    /// Something that is not an object at all is still stored and still
    /// counted, rather than being dropped or silently lumped in.
    func testAPayloadThatIsNotAnObjectIsStillKept() throws {
        let catalog = try makeCatalog()
        let sourceID = UUID()
        try catalog.upsertMetadataRecord(record(
            payload: "[1,2,3]", sourceID: sourceID, path: "Takeout/odd.json"
        ))

        XCTAssertEqual(try catalog.metadataRecordCount(), 1)
        let schemas = try catalog.fetchMetadataSchemas()
        XCTAssertEqual(schemas.first?.fingerprint, "unparsed")
    }

    /// The census keeps a whole payload per shape, not just a path — a path
    /// goes stale when a drive is reorganised, and then it can say a shape
    /// exists but not what it looked like.
    func testTheCensusKeepsOnePayloadPerShapeForever() throws {
        let catalog = try makeCatalog()
        let sourceID = UUID()
        try catalog.upsertMetadataRecord(record(payload: assetPayload, sourceID: sourceID))

        let schema = try XCTUnwrap(try catalog.fetchMetadataSchemas().first)
        XCTAssertEqual(schema.examplePayload, assetPayload)
        XCTAssertTrue(schema.examplePayload.contains("googlePhotosOrigin"))
    }

    // MARK: - Being wrong about interpretation, cheaply

    /// The property the whole design rests on: payloads the current projection
    /// logic has not read are findable, so learning something new about the
    /// format is a re-run rather than a re-download.
    func testPayloadsAwaitingProjectionAreFindable() throws {
        let catalog = try makeCatalog()
        let sourceID = UUID()
        for index in 0..<3 {
            try catalog.upsertMetadataRecord(record(
                payload: assetPayload, sourceID: sourceID,
                path: "Takeout/Google Photos/Photos from 2017/IMG_000\(index).json"
            ))
        }

        XCTAssertEqual(try catalog.metadataRecordsAwaitingProjection(), 3, "nothing read yet")
        let batch = try catalog.fetchMetadataRecordsNeedingProjection()
        XCTAssertEqual(batch.count, 3)

        try catalog.markProjected(batch.map(\.id))
        XCTAssertEqual(try catalog.metadataRecordsAwaitingProjection(), 0)
        XCTAssertTrue(try catalog.fetchMetadataRecordsNeedingProjection().isEmpty)
    }

    /// And bumping the version makes every payload stale again — one number
    /// changed, and 24,639 rows queue themselves for re-reading.
    func testBumpingTheVersionRequeuesEverything() throws {
        let catalog = try makeCatalog()
        let sourceID = UUID()
        try catalog.upsertMetadataRecord(record(payload: assetPayload, sourceID: sourceID))
        let batch = try catalog.fetchMetadataRecordsNeedingProjection()
        try catalog.markProjected(batch.map(\.id))
        XCTAssertEqual(try catalog.metadataRecordsAwaitingProjection(), 0)

        let next = CatalogStore.currentProjectionVersion + 1
        XCTAssertEqual(try catalog.metadataRecordsAwaitingProjection(below: next), 1)
        XCTAssertEqual(try catalog.fetchMetadataRecordsNeedingProjection(below: next).count, 1)
    }

    /// Re-reading an export must not silently mark its payloads as already
    /// projected — a fresh payload has not been read by anything.
    func testAReplacedPayloadIsQueuedAgain() throws {
        let catalog = try makeCatalog()
        let sourceID = UUID()
        let path = "Takeout/Google Photos/Photos from 2017/IMG_0001.json"
        try catalog.upsertMetadataRecord(record(payload: assetPayload, sourceID: sourceID, path: path))
        try catalog.markProjected(try catalog.fetchMetadataRecordsNeedingProjection().map(\.id))
        XCTAssertEqual(try catalog.metadataRecordsAwaitingProjection(), 0)

        let revised = assetPayload.replacingOccurrences(of: "\"imageViews\":\"10\"", with: "\"imageViews\":\"11\"")
        try catalog.upsertMetadataRecord(record(payload: revised, sourceID: sourceID, path: path))

        XCTAssertEqual(
            try catalog.metadataRecordsAwaitingProjection(), 1,
            "new bytes have been read by nothing"
        )
    }

    /// The census count is taken from the records, so it cannot drift from
    /// them. A tally kept alongside would over-count the moment a payload was
    /// replaced rather than added.
    func testTheCensusCountCannotDriftFromTheRecords() throws {
        let catalog = try makeCatalog()
        let sourceID = UUID()
        let path = "Takeout/Google Photos/Photos from 2017/IMG_0001.json"

        // Same path, read three times — one record, not three.
        for views in ["10", "11", "12"] {
            let payload = assetPayload.replacingOccurrences(
                of: "\"imageViews\":\"10\"", with: "\"imageViews\":\"\(views)\""
            )
            try catalog.upsertMetadataRecord(record(payload: payload, sourceID: sourceID, path: path))
        }

        XCTAssertEqual(try catalog.metadataRecordCount(), 1)
        let schema = try XCTUnwrap(try catalog.fetchMetadataSchemas().first)
        XCTAssertEqual(schema.recordCount, 1, "counted from the records themselves")
    }

    // MARK: - Staying out of the way

    /// It must not be reachable from the bulk asset read. ~24,600 payloads in
    /// the struct the Library rebuilds while scrolling is the difference
    /// between an archive that opens and one that does not.
    func testPayloadsAreNotLoadedWithAssets() throws {
        let catalog = try makeCatalog()
        let sourceID = UUID()
        let asset = Asset(
            id: UUID(), kind: .photo, originalFilename: "p.jpg", importOrigin: .googleTakeout,
            captureDate: nil, importDate: Date(), updatedDate: Date(), fileSize: 1,
            pixelWidth: nil, pixelHeight: nil, contentHash: UUID().uuidString,
            residency: .local, residencySource: .importDefault, presence: .localOnly,
            stagingRelativePath: nil, importBatchID: nil, exifSummary: [:]
        )
        try catalog.upsertAsset(asset)
        try catalog.upsertMetadataRecord(record(
            payload: assetPayload, assetID: asset.id, sourceID: sourceID
        ))

        // The bulk read returns the asset and nothing about its metadata; the
        // payload is only there when asked for by name.
        let assets = try catalog.fetchAssets()
        XCTAssertEqual(assets.count, 1)
        XCTAssertEqual(try catalog.fetchMetadataRecords(forAsset: asset.id).count, 1)
    }

    /// Payloads are text, so a person with `sqlite3` and no decoder can read
    /// their own data. The archive is meant to outlive the app.
    func testPayloadsAreStoredAsReadableText() throws {
        let catalog = try makeCatalog()
        let sourceID = UUID()
        try catalog.upsertMetadataRecord(record(payload: assetPayload, sourceID: sourceID))

        let raw = try catalog.database.query(
            "SELECT payload FROM metadata_records;"
        ) { $0.text(0) }
        XCTAssertEqual(raw.first, assetPayload)
        XCTAssertTrue(raw.first?.hasPrefix("{\"title\"") ?? false, "plain JSON, not encoded")
    }
}
