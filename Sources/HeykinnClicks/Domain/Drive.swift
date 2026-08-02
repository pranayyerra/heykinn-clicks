import Foundation

/// A registered external drive that acts as one replica of the Local domain.
/// Identity is anchored by a marker file written to the volume at registration
/// (plus the volume UUID as a secondary signal) — never by mount path alone.
struct ManagedDrive: Identifiable, Hashable {
    let id: UUID
    var name: String
    var volumeUUID: String?
    /// Random token stored both here and in the on-volume marker file.
    var markerToken: String
    var registeredAt: Date
    var lastSeenAt: Date?
    /// Where this drive was last mounted. Mount paths are never used as
    /// identity — that is what the marker file is for — but they let content
    /// recorded by path still be attributed to its drive while that drive is
    /// unplugged.
    var lastMountPath: String?
    /// Directory name at the volume root that holds this drive's replicas.
    var replicaRootComponent: String

    static let markerFileName = ".heykinn-clicks-drive.json"
    static let defaultReplicaRoot = "HeykinnClicksReplicas"
}

/// Contents of the marker file written to a managed volume.
struct DriveMarker: Codable, Hashable {
    var driveID: UUID
    var markerToken: String
    var appName: String
}

/// Runtime-only description of a mounted volume, used for registration UI and
/// for matching mounts to managed drives.
struct VolumeInfo: Identifiable, Hashable {
    var url: URL
    var name: String
    var volumeUUID: String?
    var isRemovable: Bool
    var marker: DriveMarker?

    var id: URL { url }
}
