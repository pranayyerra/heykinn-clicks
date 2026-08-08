import Foundation

/// Something a photo is called, as opposed to somewhere it is kept.
///
/// Many-to-many, and deliberately without behaviour. A photo is in as many
/// albums and has as many people in it as it has, and none of that decides
/// where its bytes live — which is the whole difference between this and
/// `StorageGroup`. A policy needs one answer per photo; "this is in three
/// albums naming three drives" has none, so storage is a partition and tags
/// are not.
///
/// Derived from `MetadataRecord`, and rebuilt rather than migrated whenever the
/// projection learns better. Nothing here is a fact the app was told directly:
/// it is all read back out of what the provider sent.
struct AssetTag: Hashable {

    enum Kind: String, Codable, CaseIterable, Hashable {
        /// A Google Photos album. Membership is expressed by directory
        /// placement in an export, never by a field.
        case album
        /// Somebody Google recognised in the picture.
        case person

        var displayName: String {
            switch self {
            case .album: return "Album"
            case .person: return "Person"
            }
        }
    }

    var assetID: UUID
    var kind: Kind
    var value: String
}
