import SQLite3
import XCTest
@testable import HeykinnClicks

/// **Whether a reader that is not this app can answer "are my photos safe".**
///
/// Step 9's first tier is a status client on another platform: what exists,
/// where the copies are, what is at risk. It needs SQLite and the schema and
/// none of the kernel — a claim now enforced for the *layers*
/// (`DocumentedRulesTests`) but never actually exercised. This exercises it: an
/// archive is built with the app, then re-read through raw SQL with no app type
/// involved, and the two have to agree.
///
/// It is the cheapest possible stand-in for a second implementation. If a
/// column is renamed, if the residency spelling changes, if copies stop being
/// countable from `replica_states` alone, this fails here rather than in a
/// client nobody has written yet.
@MainActor
final class StatusReaderConformanceTests: XCTestCase {

    private var suiteNames: [String] = []

    override func tearDown() {
        for name in suiteNames { UserDefaults.standard.removePersistentDomain(forName: name) }
        suiteNames = []
        super.tearDown()
    }

    // MARK: - A reader with nothing but SQLite

    /// Deliberately written the way a port would be: open the file, run SQL,
    /// read columns by name. No `CatalogStore`, no `Asset`, no enum.
    private struct ForeignReader {
        let handle: OpaquePointer

        init(path: String) throws {
            var db: OpaquePointer?
            guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
                throw NSError(domain: "reader", code: 1)
            }
            handle = db
        }

        func close() { sqlite3_close(handle) }

        func number(_ sql: String) -> Int {
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK,
                  sqlite3_step(statement) == SQLITE_ROW else { return -1 }
            return Int(sqlite3_column_int64(statement, 0))
        }

        /// How many photographs the archive keeps, and how many places hold the
        /// least-held one. The whole of the status answer, in two queries a
        /// port can copy.
        var photographs: Int { number("SELECT count(*) FROM assets WHERE residency = 'local'") }

        var fewestPlacesAnyPhotoIsIn: Int {
            number("""
            SELECT min(held) FROM (
              SELECT a.id, (
                SELECT count(*) FROM replica_states r
                 WHERE r.asset_id = a.id AND r.state = 'present'
              ) AS held
              FROM assets a WHERE a.residency = 'local'
            )
            """)
        }

        var drives: Int { number("SELECT count(*) FROM drives") }
    }

    // MARK: -

    private func makeArchive() throws -> (store: AppStore, catalogPath: String) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("foreign-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let suiteName = "heykinn-foreign-\(UUID().uuidString)"
        suiteNames.append(suiteName)
        let store = AppStore(environment: AppEnvironment(
            appDirectory: directory,
            defaults: UserDefaults(suiteName: suiteName)!,
            runsBackgroundWork: false
        ))
        return (store, directory.appendingPathComponent("catalog.sqlite").path)
    }

    private func addPhoto(_ store: AppStore, _ name: String) throws -> Asset {
        let asset = Asset(
            id: UUID(), kind: .photo, originalFilename: name, importOrigin: .localFolder,
            captureDate: nil, importDate: Date(), updatedDate: Date(), fileSize: 10,
            pixelWidth: nil, pixelHeight: nil, contentHash: UUID().uuidString,
            residency: .local, residencySource: .importDefault, presence: .localOnly,
            stagingRelativePath: nil, importBatchID: nil, exifSummary: [:]
        )
        try store.catalog.upsertAsset(asset)
        return asset
    }

    private func addDrive(_ store: AppStore, _ name: String) throws -> UUID {
        let id = UUID()
        try store.catalog.upsertTarget(ReplicationTarget(
            id: id, name: name, kind: .externalVolume, volumeUUID: UUID().uuidString,
            markerToken: UUID().uuidString, registeredAt: Date(), lastSeenAt: Date(),
            lastKnownPath: "/Volumes/\(name)", configuredPath: nil,
            replicaRootComponent: ReplicationTarget.defaultReplicaRoot,
            lastKnownFreeBytes: 500_000_000_000
        ))
        return id
    }

    /// **The whole point.** Two copies each, and a reader with nothing but
    /// SQLite reaches the same answer the app puts on its own front screen.
    func testAForeignReaderCountsTheSamePlacesTheAppDoes() throws {
        let (store, path) = try makeArchive()
        let a = try addDrive(store, "Nina's Back")
        let b = try addDrive(store, "My Passport")
        for name in ["one.jpg", "two.jpg", "three.jpg"] {
            let asset = try addPhoto(store, name)
            for drive in [a, b] {
                try store.catalog.upsertReplicaState(TargetReplicaState(
                    assetID: asset.id, targetID: drive, state: .present,
                    relativePath: "x/\(name)", lastVerifiedAt: Date()
                ))
            }
        }
        store.loadAll()

        let reader = try ForeignReader(path: path)
        defer { reader.close() }

        XCTAssertEqual(reader.photographs, 3)
        XCTAssertEqual(reader.drives, 2)
        XCTAssertEqual(
            reader.fewestPlacesAnyPhotoIsIn, store.leastCopiesAnywhere,
            "the app and a plain SQLite reader disagree about how safe the archive is"
        )
        XCTAssertEqual(reader.fewestPlacesAnyPhotoIsIn, 2)
    }

    /// And it sees risk, which is the other half of a status client's job: one
    /// photograph held in fewer places drags the answer down for everybody.
    func testAForeignReaderSeesThePhotographThatIsShort() throws {
        let (store, path) = try makeArchive()
        let a = try addDrive(store, "Nina's Back")
        let b = try addDrive(store, "My Passport")

        let safe = try addPhoto(store, "safe.jpg")
        for drive in [a, b] {
            try store.catalog.upsertReplicaState(TargetReplicaState(
                assetID: safe.id, targetID: drive, state: .present,
                relativePath: "x/safe.jpg", lastVerifiedAt: Date()
            ))
        }
        let exposed = try addPhoto(store, "exposed.jpg")
        try store.catalog.upsertReplicaState(TargetReplicaState(
            assetID: exposed.id, targetID: a, state: .present,
            relativePath: "x/exposed.jpg", lastVerifiedAt: Date()
        ))
        store.loadAll()

        let reader = try ForeignReader(path: path)
        defer { reader.close() }
        XCTAssertEqual(reader.fewestPlacesAnyPhotoIsIn, 1)
        XCTAssertEqual(reader.fewestPlacesAnyPhotoIsIn, store.leastCopiesAnywhere)
    }

    /// A copy recorded but not present is not a copy. A reader that counted
    /// rows instead of present ones would call the archive safe.
    func testARecordedButAbsentCopyIsNotCounted() throws {
        let (store, path) = try makeArchive()
        let a = try addDrive(store, "Nina's Back")
        let b = try addDrive(store, "My Passport")
        let asset = try addPhoto(store, "one.jpg")
        try store.catalog.upsertReplicaState(TargetReplicaState(
            assetID: asset.id, targetID: a, state: .present,
            relativePath: "x/one.jpg", lastVerifiedAt: Date()
        ))
        try store.catalog.upsertReplicaState(TargetReplicaState(
            assetID: asset.id, targetID: b, state: .missing, relativePath: nil, lastVerifiedAt: nil
        ))
        store.loadAll()

        let reader = try ForeignReader(path: path)
        defer { reader.close() }
        XCTAssertEqual(reader.fewestPlacesAnyPhotoIsIn, 1, "an absent copy was counted as a place")
    }
}
