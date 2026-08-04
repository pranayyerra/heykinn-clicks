import SwiftUI
import AppKit

/// Opens Finder on a file the app is telling you about.
///
/// Every path on these screens is a real thing on a real disk, and until now
/// the app would name it and stop — leaving the reader to copy a path out of a
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
}

/// The standard way this app offers it, so every one of them looks and reads
/// the same wherever a path is shown.
struct RevealButton: View {
    let path: String
    var label: String = "Show in Finder"

    var body: some View {
        if RevealInFinder.canReveal(path) {
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
