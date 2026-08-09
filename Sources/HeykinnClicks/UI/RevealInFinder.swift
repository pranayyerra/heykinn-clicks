import SwiftUI
import AppKit

/// Opens Finder on a file the app is telling you about.
///
/// Every path on these screens is a real thing on a real disk, and the app
/// used to name it and stop — leaving the reader to copy a path out of a
/// caption and paste it into Finder to see the thing being described. It is
/// one line of AppKit, and it turns "your export is on Field Drive" into
/// something you can go and look at.
enum RevealInFinder {

    /// Selects the item in a Finder window, or opens the enclosing folder when
    /// the item itself has gone — which is the case worth handling, since a
    /// missing file is exactly when somebody wants to go and look.
    static func reveal(_ path: String) {
        let url = URL(fileURLWithPath: path)
        if FileManager.default.fileExists(atPath: path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([url.deletingLastPathComponent()])
        }
    }

    static func canReveal(_ path: String) -> Bool {
        // The enclosing folder is enough: revealing where a deleted export
        // *was* is a useful answer to "where did it go".
        FileManager.default.fileExists(
            atPath: (path as NSString).deletingLastPathComponent
        )
    }

    /// The disk a path is on, named the way the user would name it.
    ///
    /// Derived from the path rather than looked up, because the whole point is
    /// to say something useful about a volume that is *not* mounted — at which
    /// point there is nothing to look it up in. `/Volumes/Field Drive/Photos`
    /// is on "Field Drive"; anything else is on this Mac.
    static func volumeName(for path: String) -> String? {
        let prefix = "/Volumes/"
        guard path.hasPrefix(prefix) else { return nil }
        let rest = path.dropFirst(prefix.count)
        guard let name = rest.split(separator: "/", maxSplits: 1).first, !name.isEmpty else {
            return nil
        }
        return String(name)
    }

    /// Why a path cannot be opened, in the user's terms — or nil when it can.
    static func unreachableReason(_ path: String) -> String? {
        guard !canReveal(path) else { return nil }
        if let volume = volumeName(for: path) {
            return "\(volume) is not connected"
        }
        return "No longer on this Mac"
    }
}

/// The standard way this app offers it, so every one of them looks and reads
/// the same wherever a path is shown.
///
/// It renders *something* whether or not the path is reachable. The previous
/// version returned an empty view when the disk was absent, which hid the
/// answer at precisely the moment the question gets asked — "where is it?" is
/// asked about content that is not in front of you far more often than about
/// content that is. Now reachability decides whether the action is offered,
/// not whether the fact appears.
struct RevealButton: View {
    let path: String
    var label: String = "Show in Finder"

    @ViewBuilder
    var body: some View {
        if let reason = RevealInFinder.unreachableReason(path) {
            Label(reason, systemImage: "externaldrive.badge.xmark")
                .font(.caption)
                .foregroundStyle(.secondary)
                .help(path)
        } else {
            Button {
                RevealInFinder.reveal(path)
            } label: {
                Label(label, systemImage: "arrow.up.forward.app")
                    .font(.caption)
            }
            .buttonStyle(.link)
            .help(path)
        }
    }
}

/// A path, always shown, with the action offered only when it can be taken.
///
/// Use this wherever the app names a location: it keeps the path selectable
/// and copyable even on a disk that is not attached, so somebody can go and
/// plug the right drive in — which they cannot do if the app will not tell
/// them which drive it is.
struct PathRow: View {
    let path: String
    var label: String = "Show in Finder"

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(path)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(2)
                .truncationMode(.head)
                .fixedSize(horizontal: false, vertical: true)
            RevealButton(path: path, label: label)
            Spacer(minLength: 0)
        }
    }
}

/// A folder named on screen, and a way to go and look at it.
///
/// A path the app prints is a real place on a real disk. Rendered as grey text
/// it is a dead end — something to read, retype into Finder, and mistype. This
/// is that path with somewhere to go.
///
/// Falls back to selectable text when the disk is not here, which is the case
/// the tooltip has to explain rather than the app pretending the click failed.
struct FolderLink: View {
    let path: String
    let display: String
    var symbol: String = "folder"

    init(path: String, display: String, symbol: String = "folder") {
        self.path = path
        self.display = display
        self.symbol = symbol
    }

    init(location: AppStore.Location) {
        self.init(path: location.path, display: location.display)
    }

    var body: some View {
        if RevealInFinder.canReveal(path) {
            Button {
                RevealInFinder.reveal(path)
            } label: {
                Label(display, systemImage: symbol)
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .buttonStyle(.link)
            .help("Show \(path) in Finder")
        } else {
            Label(display, systemImage: symbol)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .help("\(path) — plug the drive in to open it")
        }
    }
}
