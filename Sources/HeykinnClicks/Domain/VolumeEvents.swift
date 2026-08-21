import Foundation

/// Being told that the mounted volumes changed, and that one is about to go.
///
/// **The only part of watching drives that is the platform's.** Everything else
/// `TargetMonitor` does — listing what is mounted, matching a volume to a
/// registered drive by its marker, resolving a configured folder — is
/// `FileManager` and works anywhere.
///
/// `onVolumeWillUnmount` is the one with no guaranteed equivalent elsewhere.
/// macOS posts it *before* unmounting, which is the only chance to stop reading
/// and let an eject succeed; without it, ejecting from Finder while the app is
/// hashing fails with "disk in use", or the volume is pulled out from under
/// open handles. A platform that cannot say this in advance has to accept the
/// harder failure and recover afterwards, which the app is built to do anyway —
/// so this is a seam that may legitimately be half-implemented, and saying so
/// is better than pretending every platform can answer it.
protocol VolumeEvents: AnyObject {
    var onVolumesChanged: (() -> Void)? { get set }
    var onVolumeWillUnmount: ((URL?) -> Void)? { get set }
    func start()
    func stop()
}
