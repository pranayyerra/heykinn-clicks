import Foundation

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


    /// Set by AppStore so mount events trigger a rescan with the current registry.
    var rescanRequested: (() -> Void)?
    /// Called just before a volume unmounts, so work touching it can stop.
    var volumeWillUnmount: ((URL?) -> Void)?

    /// Where mount and unmount events come from. Injected so the rest of this
    /// class — matching volumes to drives, reading markers, resolving folders —
    /// is Foundation and portable, which it already was apart from the four
    /// lines that subscribed.
    private let events: VolumeEvents

    init(events: VolumeEvents = AppleVolumeEvents()) {
        self.events = events
        events.onVolumesChanged = { [weak self] in
            Task { @MainActor in self?.rescanRequested?() }
        }
        events.onVolumeWillUnmount = { [weak self] url in
            Task { @MainActor in self?.volumeWillUnmount?(url) }
        }
        events.start()
    }

    deinit {
        events.stop()
    }

    func setReachablePathsForTesting(_ paths: [UUID: URL]) {
        reachablePaths = paths
    }

    /// `bookmarked` is where each registered device's bookmark says it is, for
    /// the devices that have one. Supplied by the caller rather than resolved
    /// here because bookmark storage and lifetime belong to the permission
    /// service; the monitor only chooses the sandbox-safe discovery route.
    func rescan(targets: [ReplicationTarget], bookmarked: [UUID: URL] = [:]) {
        // A sandboxed process may enumerate mount names, but it has no right to
        // open every root and read a marker. Apart from being denied, that read
        // can wait on a privacy gate and hold the whole scan hostage. The
        // explicit Add Drive picker is how new devices enter; bookmarks are
        // how registered ones return.
        if TargetBookmarks.isSandboxed {
            apply(volumes: [], targets: targets, bookmarked: bookmarked)
            return
        }
        apply(volumes: Self.enumerateVolumes(), targets: targets, bookmarked: bookmarked)
    }

    /// Resolves only paths explicitly supplied by the caller. Test and offline
    /// archives use this so exercising registration cannot enumerate — much
    /// less block on — the user's real removable drives.
    func rescanKnownLocations(targets: [ReplicationTarget], bookmarked: [UUID: URL] = [:]) {
        apply(volumes: [], targets: targets, bookmarked: bookmarked)
    }

    /// The same scan with the slow half moved off the main thread.
    ///
    /// Walking the mounted volumes reads a marker file from each one, and a
    /// drive that is asleep, busy, or waiting on a permission prompt answers
    /// that read whenever it feels like it. Done on the main thread during
    /// `AppStore.init` — which is where startup does it — nothing draws until
    /// every drive has replied, so an app whose entire subject is external
    /// drives can be kept from ever showing a window by one of them.
    ///
    /// Only the enumeration moves. Matching volumes to targets and publishing
    /// the result stay on the main actor, because they touch published state.
    func rescanOffMainThread(targets: [ReplicationTarget], bookmarked: [UUID: URL] = [:]) async {
        if TargetBookmarks.isSandboxed {
            apply(volumes: [], targets: targets, bookmarked: bookmarked)
            return
        }
        let volumes = await Task.detached(priority: .userInitiated) {
            Self.enumerateVolumes()
        }.value
        apply(volumes: volumes, targets: targets, bookmarked: bookmarked)
    }

    private func apply(
        volumes: [VolumeInfo],
        targets: [ReplicationTarget],
        bookmarked: [UUID: URL] = [:]
    ) {
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

        // Devices the sweep did not find, but whose bookmark resolves.
        //
        // Sandboxed this is the only way a drive is ever found, because walking
        // the mounted volumes and reading each root is precisely what is not
        // allowed. Unsandboxed it is a second opinion, and a cheap one.
        //
        // The marker is still what settles identity. A bookmark is permission
        // to look, and it can resolve onto a disk that has since been
        // reformatted, replaced, or is simply a different volume mounted where
        // the old one was — so the token has to agree before this archive
        // treats the place as its own and starts writing replicas into it.
        for (targetID, url) in bookmarked where reachable[targetID] == nil {
            guard let target = targets.first(where: { $0.id == targetID }),
                  let marker = Self.readMarker(at: url),
                  marker.markerToken == target.markerToken
            else { continue }
            reachable[targetID] = url
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
            .volumeIsInternalKey, .volumeIsBrowsableKey, .volumeIsReadOnlyKey,
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
                isReadOnly: values?.volumeIsReadOnly ?? false,
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
