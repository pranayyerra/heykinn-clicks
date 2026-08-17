import Foundation

/// Which installation this is, for stamping the changes it makes.
///
/// **Deliberately not in the catalog.** Snapshots of the catalog are written
/// onto the drives and can be restored onto a different device, and a device
/// id carried across would have the new device claiming to be the old one —
/// issuing changes under an identity another device is already using, which
/// breaks the tie-break in `HLCTimestamp` and with it the guarantee that two
/// devices resolve a conflict the same way. Same reasoning as
/// `TargetBookmarks`, for the same kind of reason: this is a fact about the
/// installation, not about the archive.
///
/// It lives beside the catalog rather than in preferences because preferences
/// are per-sandbox-container. The App Store build and the Developer ID build
/// have separate ones but share a single archive through the app group, so
/// storing it there would make one device look like two devices that never
/// run at the same time — which is exactly the shape of a device whose changes
/// can be lost.
struct DeviceIdentity: Equatable {

    /// Stable for the life of this installation. Compared bytewise wherever it
    /// breaks a tie, so its characters must be stable text — a UUID string.
    let id: String

    /// What to call this device when a person has to be told which one did
    /// something. Not identity: it can change, and two devices can share one.
    let displayName: String

    static let fileName = "device.json"

    private struct Stored: Codable {
        var id: String
        var displayName: String
    }

    /// Reads the identity beside the catalog, minting one on first run.
    ///
    /// A file that exists but cannot be parsed is replaced rather than treated
    /// as fatal — an unreadable identity would otherwise stop the app opening
    /// an archive that is perfectly fine. The cost of minting a new one is that
    /// this device's earlier changes look like another device's, which is
    /// survivable; refusing to launch is not.
    static func resolve(
        inDirectory directory: URL,
        displayName: @autoclosure () -> String = defaultDisplayName(),
        fileManager: FileManager = .default
    ) -> DeviceIdentity {
        let url = directory.appendingPathComponent(fileName)

        if let data = try? Data(contentsOf: url),
           let stored = try? JSONDecoder().decode(Stored.self, from: data),
           !stored.id.isEmpty {
            return DeviceIdentity(id: stored.id, displayName: stored.displayName)
        }

        // Lowercased, because this becomes a directory name on a drive.
        //
        // `UUID().uuidString` is uppercase, and the drives these live on are
        // usually exFAT — case-insensitive but case-preserving. Nothing breaks
        // today, since a name written once is read back with the same case. It
        // breaks the moment a second implementation writes `9f3c…` where this
        // one wrote `9F3C…`: on the drive those are one directory, and the two
        // devices would each believe the other's segments were their own and
        // skip them. Choosing one case makes the question unable to arise.
        let minted = DeviceIdentity(id: UUID().uuidString.lowercased(), displayName: displayName())
        let stored = Stored(id: minted.id, displayName: minted.displayName)
        if let data = try? JSONEncoder().encode(stored) {
            try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            // Atomic, so a crash part-way cannot leave a truncated identity
            // that the next launch replaces with a third one.
            try? data.write(to: url, options: .atomic)
        }
        return minted
    }

    static func defaultDisplayName() -> String {
        let name = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        return name.isEmpty ? "This device" : name
    }
}
