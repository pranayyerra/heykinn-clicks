import Foundation

/// Where a batch of photos came from.
///
/// A source is *each thing the user added*: one folder they picked, one Google
/// export, one Apple Photos import. Not a category — "folders" is a heading on
/// a screen, whereas `~/Pictures/2019` is a thing with an opinion attached to
/// it. And not an import: pointing at the same folder twice is one source that
/// has been read twice, which is how a person thinks about it and what makes
/// "where do I keep my 2019 photos" answerable.
///
/// Provenance only, and immutable: what happened, not what should happen. How
/// many copies to keep and where they go is a decision that changes, and lives
/// on `StorageGroup`. The two were one row until it became clear that a group
/// made by hand — ten photos pulled out of an export — has policy but no
/// history, and that giving it a borrowed one would be a lie the app then
/// reasons with.
struct PhotoArchiveSource: Identifiable, Hashable {

    enum Kind: String, Codable, CaseIterable, Hashable {
        /// A folder on a disk somewhere, chosen with the file picker.
        case folder
        /// One Google Takeout export. Its zips and the folders they unpack
        /// into are one source, not two: they are the same photos, and
        /// splitting them would let a user place the zip on one drive and its
        /// contents on another and believe they had two copies.
        case takeoutExport
        case applePhotos
        /// Not built. Named so the enum documents where this is going and a
        /// switch over it fails to compile when the connector lands, rather
        /// than silently falling through a `default`.
        case googlePhotos

        var displayName: String {
            switch self {
            case .folder: return "Folder"
            case .takeoutExport: return "Google download"
            case .applePhotos: return "Photos library"
            case .googlePhotos: return "Google Photos"
            }
        }

        var symbol: String {
            switch self {
            case .folder: return "folder"
            case .takeoutExport: return "shippingbox"
            case .applePhotos: return "photo.on.rectangle.angled"
            case .googlePhotos: return "cloud"
            }
        }
    }

    let id: UUID
    var kind: Kind
    /// What to call it on screen — a folder's own name, an export's date.
    var label: String
    /// Where it physically is, when that means anything. Nil for Apple Photos,
    /// which is a library rather than a path.
    var originPath: String?
    /// The Google export this source *is*, for `kind == .takeoutExport`.
    ///
    /// An export's identity is its set id — the timestamp Google stamps across
    /// every part of one download — not a path: its zips can sit on three
    /// drives and be unpacked into folders beside them, and all of that is one
    /// export. Nil for every other kind.
    ///
    /// A field rather than a lookup through the assets, because the source has
    /// to be findable *before* the export has imported anything. Deriving it
    /// from an asset works only after the first photo lands, which is one chunk
    /// too late to claim that chunk.
    var exportSetID: String?
    var addedAt: Date

}

/// What changing a source's destinations would actually do.
///
/// Computed and shown before anything happens, because "move" is two
/// operations wearing one word. A copy the app wrote into its own replica
/// folder can be deleted once the new copy is verified. A file the *user* put
/// on that drive — the Takeout zip they downloaded there — can only stop being
/// counted; the app does not delete files it did not write, so a sheet that
/// said "frees 240 GB" over a set of the user's own zips would be promising
/// space it has no intention of reclaiming.
struct RetargetPlan {
    struct DeviceChange: Identifiable, Hashable {
        var targetID: UUID
        var name: String
        var isReachable: Bool
        /// Photos this device will receive.
        var toCopy: Int
        var bytesToCopy: Int64
        /// App-written copies that will be deleted after the new copies verify.
        var toDelete: Int
        var bytesFreed: Int64
        /// The user's own files here that will stop being counted and stay
        /// exactly where they are.
        var toRelease: Int

        var id: UUID { targetID }
    }

    var sourceID: UUID
    var sourceLabel: String
    /// Devices gaining copies.
    var arriving: [DeviceChange]
    /// Devices being dropped from the source.
    var departing: [DeviceChange]
    /// True when nothing would be deleted, so the confirmation can be milder.
    var isNonDestructive: Bool { departing.allSatisfy { $0.toDelete == 0 } }

    var totalToCopy: Int { arriving.reduce(0) { $0 + $1.toCopy } }
    var totalToDelete: Int { departing.reduce(0) { $0 + $1.toDelete } }

    var isEmpty: Bool { arriving.isEmpty && departing.isEmpty }
}
