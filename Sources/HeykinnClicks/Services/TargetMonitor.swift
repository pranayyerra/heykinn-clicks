import Foundation
import AppKit

/// Works out which replication targets are reachable right now.
///
/// The two kinds resolve differently, and neither resolves by path alone: a
/// removable volume is searched for among what is mounted and identified by its
/// marker file (volume UUID as fallback); a folder target is looked up at the
/// path the user registered, and counts as reachable only if the marker sitting
/// there still says it is the same target. A folder whose marker is missing or
/// belongs to another target is *not* silently adopted — that is how an archive
/// ends up written into a stranger's directory.
@MainActor
final class TargetMonitor: ObservableObject {
    /// Target ID → the path it is reachable at right now.
    @Published private(set) var reachablePaths: [UUID: URL] = [:]
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
        // macOS posts this *before* unmounting, which is the only chance to
        // stop reading from the volume and let the eject succeed. Without it,
        // ejecting from Finder while the app is hashing files fails with
        // "disk in use" — or the volume is yanked out from under open handles.
        let willUnmount = center.addObserver(
            forName: NSWorkspace.willUnmountNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let url = notification.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL
            Task { @MainActor in
                self?.volumeWillUnmount?(url)
            }
        }
        mountObservers.append(willUnmount)
    }

    deinit {
        let center = NSWorkspace.shared.notificationCenter
        for observer in mountObservers {
            center.removeObserver(observer)
        }
    }

    /// Set by AppStore so mount events trigger a rescan with the current registry.
    var rescanRequested: (() -> Void)?
    /// Called just before a volume unmounts, so work touching it can stop.
    var volumeWillUnmount: ((URL?) -> Void)?

    /// Seeds reachable state directly; used by tests to simulate a target that
    /// was already reachable before a rescan.
    func setReachablePathsForTesting(_ paths: [UUID: URL]) {
        reachablePaths = paths
    }

    func rescan(targets: [ReplicationTarget]) {
        let volumes = Self.enumerateVolumes()
        availableVolumes = volumes

        var reachable: [UUID: URL] = [:]

        for volume in volumes {
            if let match = Self.match(volume: volume, against: targets) {
                reachable[match.id] = volume.url
            }
        }

        for target in targets where target.kind == .hostDevice {
            if let url = Self.resolveFolder(target) {
                reachable[target.id] = url
            }
        }

        // A busy volume can transiently fail metadata reads (heavy I/O on
        // ExFAT/USB), which would otherwise read as an unplug and then a fresh
        // "connect" on the next tick — restarting connect-triggered work.
        // Keep a previously reachable target whose path is still on disk.
        for (targetID, previousPath) in reachablePaths where reachable[targetID] == nil {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: previousPath.path, isDirectory: &isDirectory),
               isDirectory.boolValue {
                reachable[targetID] = previousPath
            }
        }
        reachablePaths = reachable
    }

    /// A host-device target is reachable when its registered folder is a
    /// directory and the marker there still identifies this target.
    nonisolated static func resolveFolder(_ target: ReplicationTarget) -> URL? {
        guard target.kind == .hostDevice, let path = target.configuredPath else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }
        let url = URL(fileURLWithPath: path, isDirectory: true)
        guard let marker = readMarker(at: url),
              marker.targetID == target.id,
              marker.markerToken == target.markerToken else { return nil }
        return url
    }

    nonisolated static func match(volume: VolumeInfo, against targets: [ReplicationTarget]) -> ReplicationTarget? {
        let removable = targets.filter { $0.kind == .externalVolume }
        // Marker file is authoritative: it survives renames and re-mounts.
        if let marker = volume.marker,
           let target = removable.first(where: { $0.id == marker.targetID && $0.markerToken == marker.markerToken }) {
            return target
        }
        // Fallback: volume UUID (e.g. marker file deleted by accident).
        if let volumeUUID = volume.volumeUUID,
           let target = removable.first(where: { $0.volumeUUID == volumeUUID }) {
            return target
        }
        return nil
    }

    nonisolated static func enumerateVolumes() -> [VolumeInfo] {
        let keys: [URLResourceKey] = [
            .volumeNameKey, .volumeUUIDStringKey, .volumeIsRemovableKey,
            .volumeIsInternalKey, .volumeIsBrowsableKey,
        ]
        let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys,
            options: [.skipHiddenVolumes]
        ) ?? []

        return urls.compactMap { url -> VolumeInfo? in
            // The boot volume is not offered as a *volume* to register: a target
            // on the host's own disk is registered as a folder, so the archive
            // lands in a directory the user chose rather than at the root.
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

    nonisolated static func readMarker(at rootURL: URL) -> TargetMarker? {
        let markerURL = rootURL.appendingPathComponent(ReplicationTarget.markerFileName)
        guard let data = try? Data(contentsOf: markerURL) else { return nil }
        return try? JSONDecoder().decode(TargetMarker.self, from: data)
    }

    nonisolated static func writeMarker(_ marker: TargetMarker, to rootURL: URL) throws {
        let markerURL = rootURL.appendingPathComponent(ReplicationTarget.markerFileName)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(marker).write(to: markerURL, options: .atomic)
    }
}
