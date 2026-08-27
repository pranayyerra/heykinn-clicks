import Foundation

/// Works out what a captured payload is about.
///
/// The capture layer stores what arrived and asks no questions, which is what
/// makes it safe to be wrong here. This is the layer that is allowed to be
/// wrong: everything it decides is derived, versioned, and thrown away and
/// recomputed the moment it learns better — see
/// `CatalogStore.currentProjectionVersion`.
///
/// Two jobs, both of which a filename alone cannot do.
enum MetadataProjection {

    /// Which photo a sidecar is about.
    ///
    /// Capture matches on filename and gives up where a name is shared, which
    /// on a real archive is most of the hard cases: well over a third of photos
    /// there had a name that some other photo also used, and `IMG_2905.HEIC`
    /// alone belonged to five different pictures.
    ///
    /// The payload settles it, but **not by exact agreement**. `photoTakenTime`
    /// is UTC; a photo whose date came from its own EXIF carries no timezone at
    /// all, and the two then differ by whatever offset the camera was set to.
    /// On a real archive that was most of them — well under half of the matched
    /// records agreed to the second, and `IMG_2891.HEIC` missed by exactly the
    /// hour and a half its clock was out.
    ///
    /// So the comparison allows any offset a timezone can account for. That is
    /// still a sharp key: photos sharing a name are typically years apart, and
    /// a day's tolerance separates them easily while refusing two taken the
    /// same afternoon.
    ///
    /// Still refuses when it cannot tell. Two pictures with one name and one
    /// day are genuinely indistinguishable from here, and attaching the
    /// description to whichever sorted first would be a guess wearing the
    /// clothes of a fact.
    static func resolveAsset(
        forSidecarNamed sidecarName: String,
        payload: String,
        candidates: [(id: UUID, filename: String, captureDate: Date?)]
    ) -> UUID? {
        let wanted = TakeoutMetadataBackfill.mediaFilename(forSidecar: sidecarName)
        let byName = candidates.filter { $0.filename == wanted }
        if byName.count == 1 { return byName[0].id }
        guard !byName.isEmpty, let taken = photoTakenTime(in: payload) else { return nil }

        let matching = byName.filter { candidate in
            guard let date = candidate.captureDate else { return false }
            return abs(date.timeIntervalSince1970 - taken.timeIntervalSince1970) <= timezoneTolerance
        }
        return matching.count == 1 ? matching[0].id : nil
    }

    /// How far apart two records of the same moment may sit and still be it.
    ///
    /// Fourteen hours is the widest offset any real timezone reaches (UTC+14,
    /// Kiribati), so anything within it is explicable as a clock rather than as
    /// a different photograph. Wider would start merging genuinely different
    /// pictures; narrower silently drops the ones this exists to catch.
    static let timezoneTolerance: TimeInterval = 14 * 3600

    /// When the photo was taken, according to the provider.
    ///
    /// Read out of the raw payload rather than a decoded struct: this layer
    /// deliberately reaches into what was stored, so a field the typed decoder
    /// does not know about is still available to a projection written later.
    static func photoTakenTime(in payload: String) -> Date? {
        guard let data = payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let taken = object["photoTakenTime"] as? [String: Any],
              let seconds = taken["timestamp"] as? String,
              let value = TimeInterval(seconds)
        else { return nil }
        return Date(timeIntervalSince1970: value)
    }

    /// What a photo is called, read back out of what the provider sent.
    ///
    /// **Album membership is not a field.** Google expresses it by putting the
    /// photo's sidecar in a directory, so the only way back to it is the path —
    /// which is why `origin_path` is captured and why capturing payloads alone
    /// would still have lost every album.
    ///
    /// Which directories are albums is answered by evidence rather than by
    /// guessing at names: an album folder is one Google wrote a `metadata.json`
    /// into, and that file's `title` is what the album is called. Reading the
    /// folder name instead would make `Photos from 2017` an album and would
    /// miss any album renamed since.
    static func tags(
        forRecordAt originPath: String,
        payload: String,
        assetID: UUID,
        albumTitlesByDirectory: [String: String]
    ) -> [AssetTag] {
        var tags: [AssetTag] = []

        let directory = (originPath as NSString).deletingLastPathComponent
        if let album = albumTitlesByDirectory[directory] {
            tags.append(AssetTag(assetID: assetID, kind: .album, value: album))
        }

        for name in peopleNames(in: payload) {
            tags.append(AssetTag(assetID: assetID, kind: .person, value: name))
        }
        return tags
    }

    /// Who the provider says is in the picture — `[{"name":"…"}]`.
    static func peopleNames(in payload: String) -> [String] {
        guard let data = payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let people = object["people"] as? [[String: Any]]
        else { return [] }
        return people.compactMap { $0["name"] as? String }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// The title an album `metadata.json` gives itself.
    static func albumTitle(in payload: String) -> String? {
        guard let data = payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let title = (object["title"] as? String)?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty
        else { return nil }
        return title
    }

    /// Everything an album says about itself.
    ///
    /// Google nests its places two levels deep inside `enrichments`, in a shape
    /// that exists to be extended — `locationEnrichment` is one kind among
    /// however many it grows. Anything that is not a location is skipped rather
    /// than guessed at, and stays in the payload for a later projection.
    static func albumDetail(in payload: String) -> AlbumDetail? {
        guard let title = albumTitle(in: payload),
              let data = payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        var date: Date?
        if let stamp = (object["date"] as? [String: Any])?["timestamp"] as? String,
           let seconds = TimeInterval(stamp) {
            date = Date(timeIntervalSince1970: seconds)
        }
        let description = (object["description"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        var places: [AlbumDetail.Place] = []
        var journeys: [AlbumDetail.Journey] = []
        for enrichment in object["enrichments"] as? [[String: Any]] ?? [] {
            if let locations = (enrichment["locationEnrichment"] as? [String: Any])?["location"] {
                places.append(contentsOf: self.places(in: locations))
            }
            if let map = enrichment["mapEnrichment"] as? [String: Any],
               let from = self.places(in: map["origin"] as Any).first,
               let to = self.places(in: map["destination"] as Any).first {
                journeys.append(AlbumDetail.Journey(from: from, to: to))
            }
        }

        // A place named twice is one place. A real album listed "Fernwood,
        // Northshire" and "Highvale, Northshire" twice each, which reads as a
        // stutter rather than as a longer trip. Order is the order Google gave
        // them, which is roughly the order they were visited.
        var seen: Set<AlbumDetail.Place> = []

        return AlbumDetail(
            title: title,
            date: date,
            description: (description?.isEmpty ?? true) ? nil : description,
            places: places.filter { seen.insert($0).inserted },
            journeys: journeys
        )
    }

    /// Google's location list, wherever it appears — an enrichment's
    /// `location`, a map's `origin`, a map's `destination` all share the shape.
    private static func places(in value: Any) -> [AlbumDetail.Place] {
        guard let locations = value as? [[String: Any]] else { return [] }
        return locations.compactMap { location in
            guard let name = (location["name"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty
            else { return nil }
            let locality = (location["description"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return AlbumDetail.Place(
                name: name, locality: (locality?.isEmpty ?? true) ? nil : locality
            )
        }
    }

    /// What a payload is about, once it is clear it is about no photo.
    ///
    /// An export carries files that describe the export rather than anything in
    /// it — `user-generated-memory-titles.json`, `shared_album_comments.json`.
    /// Capture files them as asset payloads because at that point the only
    /// evidence is a name, and telling them apart from the older `IMG_0001.json`
    /// sidecar form needs to know whether any photo answers to them.
    ///
    /// Classification is therefore a projection, and revisable like the rest.
    static func scope(
        forSidecarNamed sidecarName: String,
        resolvedAsset: UUID?,
        currentScope: MetadataRecord.Scope
    ) -> MetadataRecord.Scope {
        if currentScope == .album { return .album }
        if resolvedAsset != nil { return .asset }
        // No photo answers to it, and its name carries no media extension: it
        // is about the export. A sidecar whose photo is simply missing keeps
        // `asset`, because it *is* about a photo — one this archive does not
        // hold.
        let media = TakeoutMetadataBackfill.mediaFilename(forSidecar: sidecarName)
        let hasMediaExtension = media != (sidecarName as NSString).deletingPathExtension
            || MetadataExtractor.kind(forFileExtension: (media as NSString).pathExtension) != .unknown
        return hasMediaExtension ? .asset : .export
    }
}
