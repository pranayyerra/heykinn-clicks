import Foundation
import AppKit

/// First-run seed so every screen has something meaningful to show. Sample
/// "photos" are real PNG files written into staging, so hashing, duplicate
/// grouping, and drive replication all work on them for real.
@MainActor
enum SampleData {

    static func seed(into store: AppStore) {
        let catalog = store.directCatalogAccess()
        let staging = store.staging
        do {
            try seedPolicies(catalog: catalog)
            let localAssets = try seedLocalAssets(catalog: catalog, staging: staging)
            try seedCloudAssets(catalog: catalog)
            try seedMigration(catalog: catalog, localAssets: localAssets)
            try catalog.appendAuditEvent(AuditEvent(
                id: UUID(),
                at: Date(),
                category: .system,
                message: "Sample data seeded on first launch.",
                assetID: nil,
                driveID: nil
            ))
        } catch {
            // Seeding is best-effort; a partial seed still leaves a usable app.
            print("Sample data seeding failed: \(error)")
        }
    }

    private static func seedPolicies(catalog: CatalogStore) throws {
        try catalog.upsertPolicyRule(PolicyRule(
            id: UUID(),
            name: "WhatsApp media stays Local",
            priority: 100,
            isEnabled: true,
            matchOrigin: .whatsapp,
            matchKind: nil,
            minFileSize: nil,
            targetResidency: .local
        ))
        try catalog.upsertPolicyRule(PolicyRule(
            id: UUID(),
            name: "Large videos stay Local",
            priority: 90,
            isEnabled: true,
            matchOrigin: nil,
            matchKind: .video,
            minFileSize: 500 * 1024 * 1024,
            targetResidency: .local
        ))
    }

    private static func seedLocalAssets(catalog: CatalogStore, staging: StagingStore) throws -> [Asset] {
        struct Spec {
            var filename: String
            var origin: ImportOrigin
            var hue: CGFloat
            var daysAgo: Int
            var duplicateOfPrevious: Bool = false
        }
        let specs: [Spec] = [
            Spec(filename: "IMG_2041.png", origin: .localFolder, hue: 0.58, daysAgo: 3),
            Spec(filename: "IMG_2042.png", origin: .localFolder, hue: 0.12, daysAgo: 3),
            Spec(filename: "IMG_2042 copy.png", origin: .localFolder, hue: 0.12, daysAgo: 2, duplicateOfPrevious: true),
            Spec(filename: "IMG-20260712-WA0004.png", origin: .whatsapp, hue: 0.33, daysAgo: 21),
            Spec(filename: "IMG-20260713-WA0011.png", origin: .whatsapp, hue: 0.78, daysAgo: 20),
            Spec(filename: "DSC_0091.png", origin: .localFolder, hue: 0.92, daysAgo: 45),
            Spec(filename: "DSC_0092.png", origin: .localFolder, hue: 0.05, daysAgo: 45),
            Spec(filename: "beach-trip.png", origin: .localFolder, hue: 0.48, daysAgo: 120),
        ]

        var seeded: [Asset] = []
        for spec in specs {
            let assetID = UUID()
            let pngData = makeSamplePNG(hue: spec.hue)
            let temporary = FileManager.default.temporaryDirectory
                .appendingPathComponent("heykinn-sample-\(assetID.uuidString).png")
            try pngData.write(to: temporary)
            defer { try? FileManager.default.removeItem(at: temporary) }

            let stagingPath = try staging.stage(fileAt: temporary, assetID: assetID, fileExtension: "png")
            let stagedURL = staging.url(forRelativePath: stagingPath)
            let hash = try HashingService.sha256(of: stagedURL)
            let fileSize = Int64((try? FileManager.default.attributesOfItem(atPath: stagedURL.path)[.size] as? Int64) ?? Int64(pngData.count))

            let now = Date()
            let capture = Calendar.current.date(byAdding: .day, value: -spec.daysAgo, to: now)
            let asset = Asset(
                id: assetID,
                kind: .photo,
                originalFilename: spec.filename,
                importOrigin: spec.origin,
                captureDate: capture,
                importDate: now,
                updatedDate: now,
                fileSize: fileSize,
                pixelWidth: 320,
                pixelHeight: 320,
                contentHash: hash,
                residency: .local,
                residencySource: spec.origin == .whatsapp ? .policy : .importDefault,
                presence: .localOnly,
                stagingRelativePath: stagingPath,
                importBatchID: nil,
                exifSummary: ["Sample": "Seeded asset"]
            )
            try catalog.upsertAsset(asset)
            seeded.append(asset)
        }
        return seeded
    }

    private static func seedCloudAssets(catalog: CatalogStore) throws {
        let now = Date()
        func cloudAsset(
            filename: String,
            residency: ResidencyDomain,
            presence: DomainPresence,
            daysAgo: Int
        ) -> Asset {
            Asset(
                id: UUID(),
                kind: .photo,
                originalFilename: filename,
                importOrigin: residency == .appleCloud ? .appleExport : .googleTakeout,
                captureDate: Calendar.current.date(byAdding: .day, value: -daysAgo, to: now),
                importDate: now,
                updatedDate: now,
                fileSize: 2_400_000,
                pixelWidth: 4032,
                pixelHeight: 3024,
                contentHash: UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased(),
                residency: residency,
                residencySource: .manual,
                presence: presence,
                stagingRelativePath: nil,
                importBatchID: nil,
                exifSummary: ["Sample": "Cloud-resident placeholder (no local bytes)"]
            )
        }

        var applePresence = DomainPresence.none
        applePresence.appleCloud = true
        try catalog.upsertAsset(cloudAsset(
            filename: "iphone-sunset.heic",
            residency: .appleCloud,
            presence: applePresence,
            daysAgo: 60
        ))

        var googlePresence = DomainPresence.none
        googlePresence.googleCloud = true
        try catalog.upsertAsset(cloudAsset(
            filename: "pixel-hike.jpg",
            residency: .googleCloud,
            presence: googlePresence,
            daysAgo: 200
        ))

        // Deliberate violation: present in both clouds with no migration.
        var bothClouds = DomainPresence.none
        bothClouds.appleCloud = true
        bothClouds.googleCloud = true
        try catalog.upsertAsset(cloudAsset(
            filename: "double-uploaded-party.jpg",
            residency: .appleCloud,
            presence: bothClouds,
            daysAgo: 400
        ))
    }

    private static func seedMigration(catalog: CatalogStore, localAssets: [Asset]) throws {
        guard let candidate = localAssets.last else { return }
        let job = MigrationJob(
            id: UUID(),
            assetIDs: [candidate.id],
            fromDomain: .local,
            toDomain: .appleCloud,
            state: .pending,
            createdAt: Date(),
            updatedAt: Date(),
            note: "Sample migration: move an old trip photo into Apple Cloud."
        )
        try catalog.upsertMigrationJob(job)
    }

    private static func makeSamplePNG(hue: CGFloat, size: Int = 320) -> Data {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: size,
            height: size,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return Data() }

        let base = NSColor(hue: hue, saturation: 0.55, brightness: 0.85, alpha: 1)
        let accent = NSColor(hue: (hue + 0.5).truncatingRemainder(dividingBy: 1), saturation: 0.6, brightness: 0.7, alpha: 1)
        context.setFillColor(base.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        context.setFillColor(accent.cgColor)
        context.fillEllipse(in: CGRect(x: size / 4, y: size / 4, width: size / 2, height: size / 2))

        guard let image = context.makeImage() else { return Data() }
        let representation = NSBitmapImageRep(cgImage: image)
        return representation.representation(using: .png, properties: [:]) ?? Data()
    }
}
