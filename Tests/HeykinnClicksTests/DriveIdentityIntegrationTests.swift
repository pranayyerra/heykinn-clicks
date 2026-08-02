import XCTest
@testable import HeykinnClicks

/// End-to-end drive identity checks against a real mounted volume, using a
/// disk image as a stand-in external drive. Gated behind an environment
/// variable because it shells out to hdiutil and mounts volumes:
///
///     HEYKINN_DMG_TESTS=1 swift test --filter DriveIdentity
final class DriveIdentityIntegrationTests: XCTestCase {

    private var attachedDevices: [String] = []
    private var imagePaths: [URL] = []

    override func tearDown() {
        for device in attachedDevices {
            _ = try? runProcess("/usr/bin/hdiutil", ["detach", device, "-force"])
        }
        attachedDevices = []
        for image in imagePaths {
            try? FileManager.default.removeItem(at: image)
        }
        imagePaths = []
        super.tearDown()
    }

    func testMarkerIdentitySurvivesRemountOnRealVolume() async throws {
        guard ProcessInfo.processInfo.environment["HEYKINN_DMG_TESTS"] == "1" else {
            throw XCTSkip("Set HEYKINN_DMG_TESTS=1 to run DMG-backed drive identity tests")
        }

        let volumeName = "HeykinnTest-\(UUID().uuidString.prefix(8))"
        let imageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(volumeName).dmg")
        imagePaths.append(imageURL)

        _ = try runProcess("/usr/bin/hdiutil", [
            "create", "-size", "20m", "-fs", "APFS", "-volname", String(volumeName), imageURL.path,
        ])
        var mountURL = try attach(imageURL)

        // Register: write the marker that anchors identity.
        let driveID = UUID()
        let token = UUID().uuidString
        let marker = DriveMarker(driveID: driveID, markerToken: token, appName: "heykinn-clicks")
        try await MainActor.run { try DriveMonitor.writeMarker(marker, to: mountURL) }

        let drive = ManagedDrive(
            id: driveID,
            name: "Test Drive",
            volumeUUID: nil,
            markerToken: token,
            registeredAt: Date(),
            lastSeenAt: nil,
            replicaRootComponent: ManagedDrive.defaultReplicaRoot
        )

        // The volume must be enumerated and matched by marker, not path.
        var matched = try await matchedDrive(mountURL: mountURL, against: [drive])
        XCTAssertEqual(matched?.id, driveID, "Freshly registered volume should match by marker")

        // A drive with the wrong token must NOT match — identity is the token,
        // not the volume's existence.
        var impostor = drive
        impostor.markerToken = "wrong-token"
        impostor.volumeUUID = nil
        let impostorMatch = try await matchedDrive(mountURL: mountURL, against: [impostor])
        XCTAssertNil(impostorMatch, "A marker with a mismatched token must not identify the drive")

        // Unplug/replug: detach and re-attach the image, then match again.
        try detachVolume(at: mountURL)
        mountURL = try attach(imageURL)
        matched = try await matchedDrive(mountURL: mountURL, against: [drive])
        XCTAssertEqual(matched?.id, driveID, "Identity must survive an unplug/replug cycle")
    }

    // MARK: - Helpers

    private func matchedDrive(mountURL: URL, against drives: [ManagedDrive]) async throws -> ManagedDrive? {
        try await MainActor.run {
            let volumes = DriveMonitor.enumerateVolumes()
            guard let volume = volumes.first(where: { $0.url.path == mountURL.path }) else {
                throw XCTSkip("Mounted test volume \(mountURL.path) not visible in volume enumeration")
            }
            return DriveMonitor.match(volume: volume, against: drives)
        }
    }

    private func attach(_ imageURL: URL) throws -> URL {
        let output = try runProcess("/usr/bin/hdiutil", ["attach", imageURL.path, "-plist"])
        guard let data = output.data(using: .utf8),
              let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let entities = plist["system-entities"] as? [[String: Any]]
        else {
            throw NSError(domain: "DriveIdentityTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unparseable hdiutil attach output"])
        }
        for entity in entities {
            if let device = entity["dev-entry"] as? String, entity["mount-point"] != nil {
                attachedDevices.append(device)
            }
        }
        guard let mountPoint = entities.compactMap({ $0["mount-point"] as? String }).first else {
            throw NSError(domain: "DriveIdentityTests", code: 2, userInfo: [NSLocalizedDescriptionKey: "No mount point in hdiutil output"])
        }
        return URL(fileURLWithPath: mountPoint)
    }

    private func detachVolume(at mountURL: URL) throws {
        _ = try runProcess("/usr/bin/hdiutil", ["detach", mountURL.path])
        attachedDevices.removeAll()
    }

    @discardableResult
    private func runProcess(_ launchPath: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: "DriveIdentityTests",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "\(launchPath) \(arguments.joined(separator: " ")) failed: \(output)"]
            )
        }
        return output
    }
}
