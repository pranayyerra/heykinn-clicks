import Foundation

/// Whether the app is running from somewhere it can actually work.
///
/// Opening an app straight out of a mounted disk image is what people do — the
/// image opens, the app is right there, and dragging it to Applications looks
/// like an optional tidiness step. macOS responds by **translocating** it:
/// running it from a randomised read-only path so that nothing it does can
/// persist. The app has no stable identity in that state, so the privacy system
/// refuses it everything.
///
/// The symptom is that Photos access is denied with no prompt, and the app
/// never appears in System Settings → Privacy & Security → Photos. Which is
/// indistinguishable, from inside the app, from a permission somebody declined
/// — and that is what it used to say, sending people to a settings pane where
/// nothing they could do would help.
///
/// It is worth detecting precisely because the honest advice is nothing to do
/// with permissions: move the app, then open it again.
enum AppInstallLocation {

    /// macOS runs a translocated app from a path under this.
    private static let translocationMarker = "/AppTranslocation/"

    enum Problem: Equatable {
        /// Running from a randomised read-only copy macOS made.
        case translocated
        /// Running from a mounted image or another read-only volume.
        case readOnlyVolume(name: String)

        var headline: String {
            switch self {
            case .translocated:
                return "Move Heykinn Clicks to your Applications folder"
            case .readOnlyVolume:
                return "Move Heykinn Clicks to your Applications folder"
            }
        }

        var explanation: String {
            switch self {
            case .translocated:
                return "This copy is running from a temporary location macOS made for it, which it does when an app is opened straight from a disk image. In that state macOS will not let the app have permission for anything — connecting your Photos library will be refused without ever asking you.\n\nDrag Heykinn Clicks into Applications, eject the installer, and open it from there."
            case .readOnlyVolume(let name):
                return "This copy is running from “\(name)”, which cannot be written to — usually the installer image itself. macOS will not grant permissions to an app in that state, so connecting your Photos library will be refused without ever asking you.\n\nDrag Heykinn Clicks into Applications, eject “\(name)”, and open it from there."
            }
        }
    }

    /// What is wrong with where this copy is running from, or nil if nothing is.
    static func problem(
        bundleURL: URL = Bundle.main.bundleURL,
        fileManager: FileManager = .default
    ) -> Problem? {
        if bundleURL.path.contains(translocationMarker) { return .translocated }

        // A read-only volume catches the case translocation does not: an app
        // copied onto a locked disk, or launched from an image that macOS chose
        // not to translocate.
        let values = try? bundleURL.resourceValues(forKeys: [
            .volumeIsReadOnlyKey, .volumeNameKey, .volumeURLKey,
        ])
        guard values?.volumeIsReadOnly == true else { return nil }
        // The boot volume is read-only on modern macOS and is not a problem;
        // apps live on the writable data volume mounted over it.
        let volumeURL = values?.volume
        if volumeURL?.path == "/" { return nil }
        return .readOnlyVolume(name: values?.volumeName ?? "that disk")
    }
}
