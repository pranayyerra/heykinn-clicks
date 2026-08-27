import Foundation

/// Reads the metadata Google wrote beside the photos, out of exports already
/// imported.
///
/// Capture only started when it was built, so every photo imported before then
/// has its description sitting in a zip and nowhere else. This is the pass that
/// changes that — and it is the last piece that depends on the zips still
/// existing, which is why it is worth running while they do.
///
/// Deliberately shallow. It stores payloads and where they sat; it does not
/// interpret them. Working out what a field means is a projection, versioned
/// and re-runnable, and doing it here would tie a whole-archive read to
/// whatever the app happened to understand on the day it ran.
enum TakeoutMetadataBackfill {

    /// What one part yielded.
    struct PartResult {
        var captured: [MetadataRecord] = []
        /// Sidecars skipped because they were already held.
        var alreadyHeld = 0
        /// Entries that were JSON but could not be read.
        var unreadable = 0
    }

    /// Reads one part's sidecars without extracting the media.
    ///
    /// - Parameters:
    ///   - skipping: origin paths already captured, so a re-run does the work
    ///     it has not done rather than all of it again. A read of this size is
    ///     not something anybody can promise not to interrupt.
    ///   - assetIDsByFilename: photos of this source, by filename, used only
    ///     where a name identifies exactly one. Roughly a sixth of a real
    ///     archive's filenames repeat, and the catalog does not record which
    ///     folder inside the export each photo came from — so an ambiguous name
    ///     is left unlinked rather than guessed at. The payload and its path
    ///     are still kept, which is what lets a later projection settle it with
    ///     better evidence than a filename.
    static func capture(
        fromZip zipURL: URL,
        sourceID: UUID,
        skipping: Set<String> = [],
        assetIDsByFilename: [String: UUID] = [:],
        workspace: URL,
        now: Date = Date()
    ) -> PartResult {
        var result = PartResult()
        let scratch = workspace.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        do {
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        } catch {
            return result
        }

        // Only the JSON. One process for the whole part: a part holds ~2,000
        // sidecars of a few hundred bytes, so a process each would be tens of
        // thousands of spawns and a re-seek of a 10 GB archive every time.
        let entries = ZipTools.extractEntries(matching: "*.json", inZip: zipURL, to: scratch)

        for entry in entries {
            // The path inside the archive, which is the only record of album
            // membership — Google writes no album field, only a directory.
            guard !skipping.contains(entry) else {
                result.alreadyHeld += 1
                continue
            }
            guard let payload = try? String(
                contentsOf: scratch.appendingPathComponent(entry), encoding: .utf8
            ) else {
                result.unreadable += 1
                continue
            }

            let filename = (entry as NSString).lastPathComponent
            let isAlbum = filename.caseInsensitiveCompare("metadata.json") == .orderedSame
            result.captured.append(MetadataRecord(
                id: UUID(),
                assetID: isAlbum ? nil : assetIDsByFilename[mediaFilename(forSidecar: filename)],
                sourceID: sourceID,
                scope: isAlbum ? .album : .asset,
                provider: "google",
                originPath: entry,
                capturedAt: now,
                schemaFingerprint: MetadataRecord.fingerprint(of: payload),
                payload: payload
            ))
        }
        return result
    }

    /// The media file a sidecar is about, from its own name.
    ///
    /// Google has used several spellings across export vintages, and a
    /// truncated `supplemental-metadata` is common because the whole name is
    /// capped in length:
    ///
    ///     IMG_0001.jpg.json
    ///     IMG_0001.jpg.supplemental-metadata.json
    ///     IMG_0001.jpg.supplemen.json
    ///     IMG_0001.json
    ///
    /// All of them are about `IMG_0001.jpg`, so everything after the media
    /// extension is dropped rather than matched exactly — a new suffix next
    /// year should not silently stop resolving.
    static func mediaFilename(forSidecar sidecar: String) -> String {
        var name = sidecar
        guard name.lowercased().hasSuffix(".json") else { return name }
        name = String(name.dropLast(5))
        // `IMG_0001.jpg.supplemental-metadata` → `IMG_0001.jpg`, by finding the
        // last component that still looks like a media extension.
        let parts = name.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count > 1 else { return name }
        for index in stride(from: parts.count - 1, through: 1, by: -1) {
            if MetadataExtractor.kind(forFileExtension: parts[index]) != .unknown {
                return parts[0...index].joined(separator: ".")
            }
        }
        // No recognisable extension anywhere: `IMG_0001.json` names
        // `IMG_0001`, whose real extension the caller resolves by lookup.
        return parts[0]
    }
}
