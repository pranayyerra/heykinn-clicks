import Foundation
import AppKit

/// Watches mounted volumes and matches them to managed drives by marker file
/// (primary) or volume UUID (secondary). Mount path is never used as identity.
@MainActor
final class DriveMonitor: ObservableObject {
    /// Managed drive ID → current mount URL, for drives connected right now.
    @Published private(set) var connectedMounts: [UUID: URL] = [:]
    /// All candidate external volumes, for the registration UI.
    @Published private(set) var availableVolumes: [VolumeInfo] = []

    private var mountObservers: [NSObjectProtocol] = []

    init() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
            let observer = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.rescanRequested?()
                }
            }
            mountObservers.append(observer)
        }
    }

    deinit {
        let center = NSWorkspace.shared.notificationCenter
        for observer in mountObservers {
            center.removeObserver(observer)
        }
    }

    /// Set by AppStore so mount events trigger a rescan with current drive registry.
    var rescanRequested: (() -> Void)?

    /// Seeds connected state directly; used by tests to simulate a drive that
    /// was already connected before a rescan.
    func setConnectedMountsForTesting(_ mounts: [UUID: URL]) {
        connectedMounts = mounts
    }

    func rescan(managedDrives: [ManagedDrive]) {
        let volumes = Self.enumerateVolumes()
        availableVolumes = volumes

        var mounts: [UUID: URL] = [:]
        for volume in volumes {
            if let match = Self.match(volume: volume, against: managedDrives) {
                mounts[match.id] = volume.url
            }
        }
        // A busy volume can transiently fail metadata reads (heavy I/O on
        // ExFAT/USB), which would otherwise read as an unplug and then a fresh
        // "connect" on the next tick — restarting connect-triggered work.
        // Keep a previously connected drive whose mount point is still on disk.
        for (driveID, previousMount) in connectedMounts where mounts[driveID] == nil {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: previousMount.path, isDirectory: &isDirectory),
               isDirectory.boolValue {
                mounts[driveID] = previousMount
            }
        }
        connectedMounts = mounts
    }

    static func match(volume: VolumeInfo, against drives: [ManagedDrive]) -> ManagedDrive? {
        // Marker file is authoritative: it survives renames and re-mounts.
        if let marker = volume.marker,
           let drive = drives.first(where: { $0.id == marker.driveID && $0.markerToken == marker.markerToken }) {
            return drive
        }
        // Fallback: volume UUID (e.g. marker file deleted by accident).
        if let volumeUUID = volume.volumeUUID,
           let drive = drives.first(where: { $0.volumeUUID == volumeUUID }) {
            return drive
        }
        return nil
    }

    static func enumerateVolumes() -> [VolumeInfo] {
        let keys: [URLResourceKey] = [
            .volumeNameKey, .volumeUUIDStringKey, .volumeIsRemovableKey,
            .volumeIsInternalKey, .volumeIsBrowsableKey,
        ]
        let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys,
            options: [.skipHiddenVolumes]
        ) ?? []

        return urls.compactMap { url -> VolumeInfo? in
            // Skip the boot volume; managed replicas live on external volumes.
            // (Internal non-boot volumes are still listed so a test partition works.)
            if url.path == "/" { return nil }
            // A failed resourceValues read must not make the volume disappear:
            // fall back to path-derived values so identity matching still runs.
            let values = try? url.resourceValues(forKeys: Set(keys))
            let isInternal = values?.volumeIsInternal ?? false
            let isRemovable = values?.volumeIsRemovable ?? true
            return VolumeInfo(
                url: url,
                name: values?.volumeName ?? url.lastPathComponent,
                volumeUUID: values?.volumeUUIDString,
                isRemovable: isRemovable || !isInternal,
                marker: readMarker(at: url)
            )
        }
    }

    static func readMarker(at volumeURL: URL) -> DriveMarker? {
        let markerURL = volumeURL.appendingPathComponent(ManagedDrive.markerFileName)
        guard let data = try? Data(contentsOf: markerURL) else { return nil }
        return try? JSONDecoder().decode(DriveMarker.self, from: data)
    }

    static func writeMarker(_ marker: DriveMarker, to volumeURL: URL) throws {
        let markerURL = volumeURL.appendingPathComponent(ManagedDrive.markerFileName)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(marker).write(to: markerURL, options: .atomic)
    }
}
