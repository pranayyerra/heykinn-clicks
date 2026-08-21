import AppKit
import Foundation

/// Mount and unmount events from `NSWorkspace`.
final class AppleVolumeEvents: VolumeEvents {
    var onVolumesChanged: (() -> Void)?
    var onVolumeWillUnmount: ((URL?) -> Void)?

    private var observers: [NSObjectProtocol] = []

    func start() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [
            NSWorkspace.didMountNotification,
            NSWorkspace.didUnmountNotification,
            NSWorkspace.didRenameVolumeNotification,
        ] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) {
                [weak self] _ in self?.onVolumesChanged?()
            })
        }
        // Posted *before* unmounting — see `VolumeEvents` for why that matters.
        observers.append(center.addObserver(
            forName: NSWorkspace.willUnmountNotification, object: nil, queue: .main
        ) { [weak self] notification in
            self?.onVolumeWillUnmount?(
                notification.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL
            )
        })
    }

    func stop() {
        let center = NSWorkspace.shared.notificationCenter
        for observer in observers { center.removeObserver(observer) }
        observers.removeAll()
    }
}
