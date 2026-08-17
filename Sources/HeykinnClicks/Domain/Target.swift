import Foundation

/// Which device a target's copy lives on. A target *is* a device: the kind says
/// whether that device is the device running the app or a drive attached to
/// it, and that difference is why availability works differently for each.
enum TargetKind: String, Codable, CaseIterable, Hashable {
    /// A drive with its own identity, found among mounted volumes by its
    /// marker, present only while it is attached.
    case externalVolume
    /// The device the app runs on, holding its copy in a folder the user
    /// chose. The folder is where the copy goes; the device is what the target
    /// is — so a folder that resolves onto an external volume is that volume,
    /// and must be registered as one instead.
    case hostDevice

    var displayName: String {
        switch self {
        case .externalVolume: return "External drive"
        case .hostDevice: return "This device"
        }
    }
}

/// One registered place that can hold a copy of the Local domain.
///
/// How many targets exist and what they are is the user's configuration, not
/// the design: nothing may assume a count, assume a target is removable, or
/// assume any particular one is present. Identity is anchored by a marker file
/// token written at registration — never by path, because a path says where a
/// target was last seen, and two targets can occupy the same path at different
/// times.
struct ReplicationTarget: Identifiable, Hashable {
    let id: UUID
    var name: String
    /// Defaulted because everything written before targets existed was an
    /// external drive — the only thing the app could register at the time.
    /// Registration always passes it explicitly.
    var kind: TargetKind = .externalVolume
    /// Removable targets only: secondary identity if the marker file is lost.
    var volumeUUID: String?
    /// Random token stored both here and in the on-target marker file.
    var markerToken: String
    var registeredAt: Date
    var lastSeenAt: Date?
    /// Where this target was last reachable. Never identity — but content
    /// recorded by path while the target was attached is still attributed to it
    /// once it is gone, and without this that content would count towards no
    /// target at all.
    var lastKnownPath: String?
    /// Host-device targets: the folder the user registered. Nil for external
    /// volumes, which are found rather than looked up.
    var configuredPath: String?
    /// Directory name at the target root that holds this target's replicas.
    var replicaRootComponent: String

    /// Deliberately still says "drive": marker files written by earlier
    /// versions are sitting on users' volumes right now, and renaming the file
    /// would orphan every target already registered.
    static let markerFileName = ".heykinn-clicks-drive.json"

    /// The one directory the app writes into on a target. Everything the app
    /// puts on a drive that is not the user's own content lives under here —
    /// one folder, so the user can see at a glance what is the app's and what
    /// is theirs.
    static let appFolderName = "HeykinnClicks"
    static let defaultReplicaRoot = appFolderName + "/Replicas"

    /// A folder target is expected at a fixed path; a removable one is wherever
    /// it happens to be mounted.
    var expectedPath: String? {
        switch kind {
        case .hostDevice: return configuredPath
        case .externalVolume: return nil
        }
    }
}

/// The storage a path actually sits on.
///
/// Registration is about devices, not paths: two folders can look unrelated and
/// share one disk, and a copy in each is one copy, not two. Redundancy is about
/// surviving a device failing, so this is what registration has to compare.
struct TargetStorage: Equatable {
    var volumeURL: URL
    var volumeUUID: String?
    var isInternal: Bool
    var isRemovable: Bool

    /// The device's own storage: internal, and not something you unplug.
    var isHostDevice: Bool { isInternal && !isRemovable }

    /// Same physical place. Volume UUID when the filesystem reports one, volume
    /// root otherwise — weaker evidence, but it still catches the case that
    /// matters: two folders on one disk.
    func isSamePlace(as other: TargetStorage) -> Bool {
        if let mine = volumeUUID, let theirs = other.volumeUUID { return mine == theirs }
        return volumeURL.standardizedFileURL == other.volumeURL.standardizedFileURL
    }

    static func of(_ url: URL) -> TargetStorage? {
        let keys: Set<URLResourceKey> = [
            .volumeURLKey, .volumeUUIDStringKey, .volumeIsInternalKey, .volumeIsRemovableKey,
        ]
        guard let values = try? url.resourceValues(forKeys: keys),
              let volumeURL = values.volume else { return nil }
        return TargetStorage(
            volumeURL: volumeURL,
            volumeUUID: values.volumeUUIDString,
            isInternal: values.volumeIsInternal ?? false,
            isRemovable: values.volumeIsRemovable ?? false
        )
    }
}

/// Contents of the marker file written to a registered target. This is what
/// makes identity survive a rename, a remount, or a different mount path.
struct TargetMarker: Codable, Hashable {
    var targetID: UUID
    var markerToken: String
    var appName: String
}

/// A folder chosen for import that sits on a drive the app could manage but
/// does not.
///
/// Worth stopping for, because the two outcomes differ by a whole copy of the
/// content. Registering first costs nothing and the files are credited where
/// they already are; importing first copies all of them onto the device, and the
/// decision cannot be revisited later without reading every byte again. The
/// moment to ask is the only moment the answer is free.
struct UnmanagedSourceOffer: Identifiable {
    let id = UUID()
    var volume: VolumeInfo
    var urls: [URL]

    var name: String { volume.name }
}

/// Runtime-only description of a mounted volume, used for registration UI and
/// for matching mounts to removable targets.
struct VolumeInfo: Identifiable, Hashable {
    var url: URL
    var name: String
    var volumeUUID: String?
    var isRemovable: Bool
    /// A mounted disk image, a locked volume, an optical disc. Nothing can be
    /// copied onto one, so it cannot be a device the archive keeps copies on —
    /// and the app's own installer is one of these, mounted, at the moment
    /// somebody is first looking for drives to register.
    var isReadOnly: Bool = false
    var marker: TargetMarker?

    var id: URL { url }
}
