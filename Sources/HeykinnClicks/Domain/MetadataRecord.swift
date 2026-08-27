import Foundation

/// One piece of provider metadata, kept exactly as it arrived.
///
/// The point is that the zips become disposable. A Google export carries a JSON
/// sidecar per photo and a `metadata.json` per album, and the importer reads
/// four fields out of them — capture time, description, latitude, longitude —
/// and drops the rest on the floor. Everything dropped is only recoverable by
/// going back to the whole download, which is precisely what the archive exists
/// to stop depending on.
///
/// So the payload is stored **verbatim and unparsed**. A field Google adds next
/// year is saved before any code here knows it exists, and reading it later
/// costs a re-projection rather than a re-download. Swift's `Decodable` ignores
/// keys it does not know, so the typed decoder is unaffected either way.
///
/// This is deliberately its own table. It is never joined into `fetchAssets()`,
/// never loaded by `loadAll()`, and never `@Published`: one payload per photo
/// at 600-odd bytes is fine on disk and ruinous in a struct the Library
/// rebuilds while scrolling. It is read on asset detail, on search, and on
/// export.
struct MetadataRecord: Identifiable, Hashable {

    /// What the payload is about. An album's JSON describes a set, not a photo,
    /// so it hangs off the source with no asset at all.
    enum Scope: String, Codable, CaseIterable, Hashable {
        case asset
        case album
        case export
    }

    let id: UUID
    /// Nil for anything that is not about one photo.
    var assetID: UUID?
    /// The source this came in with. Always present: a payload with no
    /// provenance is a payload nobody can explain later.
    var sourceID: UUID
    var scope: Scope
    /// Who produced it — `google`, and later others. A string rather than an
    /// enum: a provider the app has never heard of should still be storable,
    /// which is the whole point.
    var provider: String
    /// Where it sat inside the export.
    ///
    /// Load-bearing, not decoration. **Album membership is not a field.** In a
    /// Takeout export it is expressed by directory placement — `Kodaikanal` and
    /// `Paro, Bhutan` are albums, `Photos from 2017` is a year bucket, and
    /// `Failed Videos` is Google's marker for what it could not process. Store
    /// the payloads alone and album membership is still lost, so the path is
    /// the only way to project it back.
    var originPath: String
    var capturedAt: Date
    /// Hash of the payload's sorted top-level key set — see `fingerprint(of:)`.
    var schemaFingerprint: String
    /// The JSON exactly as it was on disk.
    ///
    /// Text, not a blob, and uncompressed. These payloads ride in every catalog
    /// snapshot — three per drive — and a sidecar per photo runs to megabytes,
    /// small enough that squeezing it would buy little and cost the one
    /// property worth more than the bytes: the archive is meant to outlive the
    /// app, and `sqlite3 catalog.sqlite 'select payload …'` should show a
    /// person their own data without a decoder.
    var payload: String

    /// The shape of a payload, as a short stable string.
    ///
    /// Keys only, sorted, never values: two photos with different descriptions
    /// have the same shape, and a photo carrying a key nobody has seen before
    /// does not. That makes an unrecognised fingerprint a *reportable event* —
    /// "Google changed the format" stops being silent data loss and becomes a
    /// row in `metadata_schemas` with a count and one example path.
    ///
    /// Top level only. Nesting changes inside `geoData` are not caught, which
    /// is a known limit rather than an oversight: going deeper makes the
    /// fingerprint churn on optional sub-objects and turns a signal into noise.
    static func fingerprint(of payload: String) -> String {
        guard
            let data = payload.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data),
            let dictionary = object as? [String: Any]
        else {
            // Not an object at all. Still fingerprinted, so it is counted and
            // surfaced rather than silently grouped with everything else.
            return "unparsed"
        }
        // Bytewise, not Swift's `<`: this fingerprint is stored and compared,
        // and provider keys are not guaranteed to be ASCII. Two platforms
        // ordering the same key set differently would fingerprint one schema as
        // two. See `ByteOrdering`.
        let keys = dictionary.keys.sortedByBytes().joined(separator: ",")
        let digest = Digest256.hash(Data(keys.utf8))
        return Digest256.hex(digest).prefix(16).description
    }
}

/// A payload shape the app has seen, and how often.
///
/// Exists so that a format change is discovered by looking at a list rather
/// than by noticing, years later, that something is missing.
struct MetadataSchema: Identifiable, Hashable {
    var fingerprint: String
    var provider: String
    var scope: MetadataRecord.Scope
    /// Sorted key names, so an unfamiliar fingerprint can be read at a glance
    /// without opening a payload.
    var keys: [String]
    var recordCount: Int
    /// One path carrying this shape, to go and look at.
    var examplePath: String
    /// One whole payload of this shape, kept forever.
    ///
    /// The path alone goes stale when a drive is reorganised, and then the
    /// census can say a shape exists but not what it looked like. This is a few
    /// KB per shape and is the permanent record of every format the app has
    /// met.
    var examplePayload: String
    var firstSeenAt: Date

    var id: String { fingerprint }
}
