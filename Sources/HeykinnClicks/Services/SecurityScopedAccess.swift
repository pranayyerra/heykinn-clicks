import Foundation

/// A balanced lease on a URL handed to the app by a system file picker.
///
/// SwiftUI's `fileImporter` returns a security-scoped URL in a sandboxed app.
/// The extension is only usable after `startAccessingSecurityScopedResource()`
/// succeeds, and asynchronous work has to keep that access open until it is
/// finished. Keeping the balance in a reference type makes the lifetime
/// explicit: capture the lease in a task, or retain it while a confirmation
/// sheet is open, and access ends when that work releases it.
final class SecurityScopedAccess: @unchecked Sendable {
    let url: URL
    private let didStart: Bool

    init?(url: URL) {
        self.url = url
        if TargetBookmarks.isSandboxed {
            guard url.startAccessingSecurityScopedResource() else { return nil }
            didStart = true
        } else {
            didStart = false
        }
    }

    deinit {
        if didStart { url.stopAccessingSecurityScopedResource() }
    }
}
