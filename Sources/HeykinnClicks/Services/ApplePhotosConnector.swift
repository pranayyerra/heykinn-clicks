import Foundation
import Photos
import CryptoKit
import AppKit

/// The Apple Photos connector — the first real `CloudDomainVerifier`.
///
/// It reads the Photos library on this device. **Whether that library is
/// AppleCloud depends on iCloud Photos being enabled, and PhotoKit exposes no
/// API to check** — so the app asks once, at connect time, and treats the
/// answer as topology rather than as evidence about any photo. With sync off,
/// findings are recorded as a link to a local library, never as cloud presence.
///
/// Two strengths of finding, deliberately distinct:
///
/// - **Byte-identical originals** — the resource is streamed, SHA-256'd
///   (fetched from iCloud when only a preview is local) and compared to the
///   catalog's content hash. This is proof the same file is in both places,
///   and the only thing allowed to write `verified` presence, because it is
///   the only thing safe to reclaim against: an Apple original is usually
///   better than a Google re-encode, and releasing it for a degraded copy
///   would quietly cost quality.
/// - **A counterpart** — same capture second and pixel dimensions, with
///   filename only as a tie-breaker between bursts. Strong evidence of the
///   same *photograph*, which is what a user means by "I already have this",
///   but not of the same *file*. Recorded as a link, never as presence.
///
/// Why Apple first and not Google: since March 2025, Google's Library API
/// reads only app-created content, and it has never offered deletion. An
/// honest programmatic verifier for a pre-existing Google library cannot be
/// built; Google verification stays manual (a fresh Takeout diffed against
/// the catalog), and this connector is where the vision becomes executable.
enum ApplePhotosConnectionState: Equatable {
    /// This build cannot even ask: requesting Photos access without a usage
    /// description in Info.plist crashes the process outright.
    case unavailable(reason: String)
    case notDetermined
    case denied
    case connected
}

final class ApplePhotosVerifier: CloudDomainVerifier {
    let domain: ResidencyDomain = .appleCloud

    var isConnected: Bool { Self.connectionState == .connected }

    static var canRequestAccess: Bool {
        Bundle.main.object(forInfoDictionaryKey: "NSPhotoLibraryUsageDescription") != nil
    }

    static var connectionState: ApplePhotosConnectionState {
        guard canRequestAccess else {
            return .unavailable(reason: "This build has no Photos usage description, so macOS will not show the permission prompt. Run the app as a bundle that declares one.")
        }
        switch PHPhotoLibrary.authorizationStatus(for: .readWrite) {
        case .authorized: return .connected
        case .notDetermined: return .notDetermined
        default: return .denied
        }
    }

    static func requestAccess() async -> ApplePhotosConnectionState {
        guard canRequestAccess else { return connectionState }
        _ = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        return connectionState
    }

    /// Opens the pane rather than describing where it is.
    ///
    /// "System Settings → Privacy & Security → Photos" is four steps and a
    /// scroll, and it is being read by somebody who has just been told no by
    /// software they are trying to trust. macOS will not let an app grant
    /// itself anything, but taking someone to the switch is free.
    static func openPrivacySettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Photos"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    /// How many assets the connected library actually holds.
    ///
    /// Authorisation is not availability. A library that lives on a drive that
    /// is not plugged in — or one that was never created — authorises fine and
    /// then answers every query with nothing.
    static var libraryAssetCount: Int {
        guard connectionState == .connected else { return 0 }
        return PHAsset.fetchAssets(with: nil).count
    }

    /// One photo in the provider's library, described from metadata alone —
    /// no data fetched, nothing pulled from iCloud.
    struct LibraryItem: Equatable {
        var localIdentifier: String
        var filename: String
        var captureDate: Date?
        var pixelWidth: Int
        var pixelHeight: Int
        var kind: AssetKind
        var isMotionHalf: Bool
    }

    /// Enumerates the library from metadata only. Cheap enough to run over a
    /// whole library: no resource is read, so nothing downloads.
    static func indexLibrary() -> [LibraryItem] {
        guard connectionState == .connected else { return [] }
        let fetch = PHAsset.fetchAssets(with: nil)
        var items: [LibraryItem] = []
        items.reserveCapacity(fetch.count)
        fetch.enumerateObjects { asset, _, _ in
            let resources = PHAssetResource.assetResources(for: asset)
            let primary = resources.first { $0.type == .photo || $0.type == .video }
                ?? resources.first
            items.append(LibraryItem(
                localIdentifier: asset.localIdentifier,
                filename: primary?.originalFilename ?? "(unnamed)",
                captureDate: asset.creationDate,
                pixelWidth: asset.pixelWidth,
                pixelHeight: asset.pixelHeight,
                kind: asset.mediaType == .video
                    ? .video
                    : (asset.mediaSubtypes.contains(.photoLive) ? .livePhoto : .photo),
                isMotionHalf: false
            ))
        }
        return items
    }

    /// What one library item is, as files on disk.
    ///
    /// A Live Photo is two files. Photos stores it as one asset carrying a
    /// still resource and a paired-video resource; the catalog stores it as two
    /// assets linked by `livePhotoStillID`, because the movie is real content
    /// that has to live somewhere and be checked like anything else. Exporting
    /// only the still would hand the archive a flattened photograph and quietly
    /// drop the motion — which, once the library is gone, is gone.
    struct ExportedOriginal {
        /// The photograph itself: the `.photo` resource, or `.video` for a movie.
        var still: URL
        /// The movie half of a Live Photo, when the item has one.
        var motion: URL?

        var all: [URL] { [still] + (motion.map { [$0] } ?? []) }
    }

    /// Writes an indexed item's originals out of the library to `directory`.
    ///
    /// This is what turns "the app can see this photo" into "the app can
    /// protect it". Network access is allowed because an original that lives
    /// only in iCloud has to come down before it can be copied to a drive —
    /// a preview is not the photograph.
    static func exportOriginal(localIdentifier: String, to directory: URL) async throws -> ExportedOriginal {
        guard connectionState == .connected else {
            throw CloudVerificationError.notConnected(.appleCloud)
        }
        guard let phAsset = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil).firstObject else {
            throw ExportError.assetGone
        }
        let resources = PHAssetResource.assetResources(for: phAsset)
        let wanted: PHAssetResourceType = phAsset.mediaType == .video ? .video : .photo
        guard let still = resources.first(where: { $0.type == wanted }) ?? resources.first else {
            throw ExportError.noOriginal
        }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stillURL = try await write(still, into: directory, avoiding: [])

        // `.pairedVideo` is the movie as shot. `.fullSizePairedVideo` is a
        // render of an edited Live Photo, so it is only the original when
        // there is no unedited half to take.
        let motionResource = resources.first { $0.type == .pairedVideo }
            ?? resources.first { $0.type == .fullSizePairedVideo }
        guard let motionResource else { return ExportedOriginal(still: stillURL, motion: nil) }

        do {
            let motionURL = try await write(motionResource, into: directory, avoiding: [stillURL])
            return ExportedOriginal(still: stillURL, motion: motionURL)
        } catch {
            // The still is real content already on disk; failing the whole
            // item because its motion half would not come down would leave the
            // photograph unprotected too. The pair is reported as unpaired,
            // never as complete.
            return ExportedOriginal(still: stillURL, motion: nil)
        }
    }

    /// Writes one resource out, under its own filename unless that name is
    /// already taken by another half of the same item.
    private static func write(
        _ resource: PHAssetResource, into directory: URL, avoiding taken: [URL]
    ) async throws -> URL {
        var destination = directory.appendingPathComponent(resource.originalFilename)
        if taken.contains(where: { $0.lastPathComponent == destination.lastPathComponent }) {
            let name = destination.deletingPathExtension().lastPathComponent
            let ext = destination.pathExtension
            destination = directory.appendingPathComponent(
                ext.isEmpty ? "\(name)-motion" : "\(name)-motion.\(ext)"
            )
        }
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }

        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHAssetResourceManager.default().writeData(for: resource, toFile: destination, options: options) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
        return destination
    }

    enum ExportError: Error, LocalizedError {
        case assetGone
        case noOriginal

        var errorDescription: String? {
            switch self {
            case .assetGone:
                return "That photo is no longer in the Photos library."
            case .noOriginal:
                return "Photos holds no original for that item — only a derivative, which is not the photograph."
            }
        }
    }

    /// A thumbnail for an indexed photo. Served from the provider's own
    /// cache — `isNetworkAccessAllowed` stays off, because a grid scrolling
    /// past a thousand photos must never trigger a thousand downloads.
    static func thumbnail(forLocalIdentifier id: String, size: CGFloat = 320) async -> NSImage? {
        guard connectionState == .connected else { return nil }
        guard let phAsset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject else { return nil }
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = false
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        return await withCheckedContinuation { continuation in
            var resumed = false
            PHImageManager.default().requestImage(
                for: phAsset,
                targetSize: CGSize(width: size, height: size),
                contentMode: .aspectFill,
                options: options
            ) { image, info in
                // Opportunistic delivery can call back twice (degraded, then
                // full); a continuation may only be resumed once.
                guard !resumed else { return }
                let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                guard !isDegraded || image != nil else { return }
                if isDegraded { return }
                resumed = true
                continuation.resume(returning: image)
            }
        }
    }

    /// Whether a library item and a catalog asset could be the same
    /// photograph, on capture instant and pixel dimensions.
    ///
    /// Filename is deliberately *not* required. Takeout hands back UUID
    /// filenames for much of an export — `4DC2E0F6-…-5CA1B883C344.jpg` for
    /// what Photos calls `IMG_2380.HEIC` — so demanding a name match missed
    /// most real matches, and the app then exported originals only to
    /// discover by hashing that it already held them.
    static func metadataMatches(_ item: LibraryItem, _ asset: Asset) -> Bool {
        guard let itemDate = item.captureDate, let assetDate = asset.captureDate else { return false }
        guard abs(itemDate.timeIntervalSince(assetDate)) < 1 else { return false }
        guard let width = asset.pixelWidth, let height = asset.pixelHeight else { return false }
        return item.pixelWidth == width && item.pixelHeight == height
    }

    /// The archive photo a library item corresponds to, or nil when that
    /// cannot be settled from metadata alone.
    ///
    /// A burst is several frames sharing one capture second and one set of
    /// dimensions, so a lone metadata match is trusted while an ambiguous one
    /// is broken by filename — and if even that cannot separate them, nothing
    /// is linked. Guessing here would attach the archive to the wrong picture;
    /// declining leaves it to the byte comparison, which cannot be wrong.
    static func counterpart(for item: LibraryItem, among candidates: [Asset]) -> Asset? {
        let matches = candidates.filter { metadataMatches(item, $0) }
        if matches.count == 1 { return matches[0] }
        guard matches.count > 1 else { return nil }
        let byName = matches.filter { stem($0.originalFilename) == stem(item.filename) }
        return byName.count == 1 ? byName[0] : nil
    }

    private static func stem(_ filename: String) -> String {
        (filename as NSString).deletingPathExtension.lowercased()
    }

    /// Result may omit assets it could not search for (no capture date to
    /// anchor a candidate fetch). Omission means "could not check", which is a
    /// different statement from `false` — and the difference matters, because
    /// `false` gets recorded.
    func verifyPresence(of assets: [Asset]) async throws -> [UUID: Bool] {
        guard isConnected else { throw CloudVerificationError.notConnected(domain) }
        // An empty library cannot answer "is this photo here?" — every reply
        // would be a negative that only means "there is nothing to look in".
        // Recording those as checked absences is claiming more than was
        // checked, so refuse instead.
        guard Self.libraryAssetCount > 0 else {
            throw CloudVerificationError.libraryUnavailable(domain)
        }
        var results: [UUID: Bool] = [:]
        for asset in assets {
            guard let capture = asset.captureDate else { continue }
            let candidates = Self.candidates(around: capture)
            var present = false
            var unreadable = false
            for candidate in candidates {
                do {
                    if try await Self.originalMatches(candidate, asset: asset) {
                        present = true
                        break
                    }
                } catch {
                    // The original is not on this device and could not be
                    // fetched — the ordinary state of an optimised library
                    // once iCloud Photos is switched off. There are no bytes
                    // to compare, so this asset was not checked. Saying
                    // "not present" here would be reporting a missing file as
                    // a missing photo.
                    unreadable = true
                }
            }
            if present {
                results[asset.id] = true
            } else if !unreadable {
                results[asset.id] = false
            }
        }
        return results
    }

    // MARK: - Matching

    private static func candidates(around capture: Date) -> [PHAsset] {
        let options = PHFetchOptions()
        // ±2s: Takeout and Photos both round capture times, and a too-narrow
        // window silently misses; the hash comparison makes wide windows safe.
        options.predicate = NSPredicate(
            format: "creationDate >= %@ AND creationDate <= %@",
            capture.addingTimeInterval(-2) as NSDate,
            capture.addingTimeInterval(2) as NSDate
        )
        let fetch = PHAsset.fetchAssets(with: options)
        var out: [PHAsset] = []
        fetch.enumerateObjects { asset, _, _ in out.append(asset) }
        return out
    }

    private static func originalMatches(_ phAsset: PHAsset, asset: Asset) async throws -> Bool {
        let resources = PHAssetResource.assetResources(for: phAsset)
        // Our catalog stores a Live Photo as two assets; Photos stores one
        // asset with two resources. Pick the resource that corresponds.
        let wanted: PHAssetResourceType = asset.isLivePhotoMotion
            ? .pairedVideo
            : (asset.kind == .video ? .video : .photo)
        guard let resource = resources.first(where: { $0.type == wanted }) else { return false }
        return try await sha256(of: resource) == asset.contentHash
    }

    private static func sha256(of resource: PHAssetResource) async throws -> String {
        let options = PHAssetResourceRequestOptions()
        // The whole point: if only a preview is local, pull the original from
        // iCloud — hashing a derivative would compare the wrong bytes.
        options.isNetworkAccessAllowed = true
        return try await withCheckedThrowingContinuation { continuation in
            var hasher = SHA256()
            PHAssetResourceManager.default().requestData(for: resource, options: options) { chunk in
                hasher.update(data: chunk)
            } completionHandler: { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: hasher.finalize().map { String(format: "%02x", $0) }.joined())
                }
            }
        }
    }
}
