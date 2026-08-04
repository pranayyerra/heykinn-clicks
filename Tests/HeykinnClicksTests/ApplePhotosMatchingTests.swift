import XCTest
@testable import HeykinnClicks

/// Counterpart matching decides which photos merge into one row and which
/// appear twice, so it is worth pinning — especially since no Photos library
/// is available to exercise it end to end.
final class ApplePhotosMatchingTests: XCTestCase {

    private func item(
        name: String = "IMG_1234.HEIC",
        date: Date? = Date(timeIntervalSince1970: 1_600_000_000),
        width: Int = 4032,
        height: Int = 3024
    ) -> ApplePhotosVerifier.LibraryItem {
        ApplePhotosVerifier.LibraryItem(
            localIdentifier: "ABC-123/L0/001",
            filename: name,
            captureDate: date,
            pixelWidth: width,
            pixelHeight: height,
            kind: .photo,
            isMotionHalf: false
        )
    }

    private func asset(
        name: String = "IMG_1234.jpg",
        date: Date? = Date(timeIntervalSince1970: 1_600_000_000),
        width: Int? = 4032,
        height: Int? = 3024
    ) -> Asset {
        Asset(
            id: UUID(), kind: .photo, originalFilename: name, importOrigin: .googleTakeout,
            captureDate: date, importDate: Date(), updatedDate: Date(), fileSize: 100,
            pixelWidth: width, pixelHeight: height, contentHash: "hash",
            residency: .local, residencySource: .importDefault, presence: .localOnly,
            stagingRelativePath: nil, importBatchID: nil, exifSummary: [:]
        )
    }

    /// The case the whole feature turns on: Google hands back a re-encoded
    /// JPEG of what Photos stores as HEIC. Different bytes, different
    /// extension, same photograph.
    func testSamePhotographAcrossEncodingsMatches() {
        XCTAssertTrue(ApplePhotosVerifier.metadataMatches(item(), asset()))
    }

    /// The defect real data exposed: Takeout hands back UUID filenames for
    /// much of an export, so requiring a name match missed most true matches
    /// and the app exported originals only to learn by hashing it already held
    /// them.
    func testUUIDFilenamesFromTakeoutStillMatch() {
        let takeoutNamed = asset(name: "4DC2E0F6-8057-4BB3-85DC-5CA1B883C344.jpg")
        XCTAssertTrue(ApplePhotosVerifier.metadataMatches(item(name: "IMG_2380.HEIC"), takeoutNamed))
        XCTAssertEqual(
            ApplePhotosVerifier.counterpart(for: item(name: "IMG_2380.HEIC"), among: [takeoutNamed])?.id,
            takeoutNamed.id
        )
    }

    func testDifferentCaptureTimeDoesNotMatch() {
        let later = Date(timeIntervalSince1970: 1_600_000_060)
        XCTAssertFalse(ApplePhotosVerifier.metadataMatches(item(), asset(date: later)))
    }

    /// A crop or an export at another size is a different picture as far as
    /// this is concerned; merging them would hide one of them.
    func testDifferentDimensionsDoNotMatch() {
        XCTAssertFalse(ApplePhotosVerifier.metadataMatches(item(width: 1024, height: 768), asset()))
    }

    /// Without a capture date there is nothing to anchor a match.
    func testMissingCaptureDateNeverMatches() {
        XCTAssertFalse(ApplePhotosVerifier.metadataMatches(item(date: nil), asset()))
        XCTAssertFalse(ApplePhotosVerifier.metadataMatches(item(), asset(date: nil)))
    }

    func testMissingDimensionsNeverMatch() {
        XCTAssertFalse(ApplePhotosVerifier.metadataMatches(item(), asset(width: nil, height: nil)))
    }

    // MARK: - Bursts

    /// Frames of a burst share a capture second and dimensions. Filename
    /// separates them; a lone candidate needs no separating.
    func testABurstIsSeparatedByFilename() {
        let a = asset(name: "IMG_1234.jpg")
        let b = asset(name: "IMG_1235.jpg")
        XCTAssertEqual(
            ApplePhotosVerifier.counterpart(for: item(name: "IMG_1235.HEIC"), among: [a, b])?.id,
            b.id
        )
    }

    /// When even the filename cannot separate them, nothing is linked —
    /// attaching the archive to the wrong picture is worse than waiting for
    /// the byte comparison, which cannot be wrong.
    func testAnUnresolvableBurstLinksNothing() {
        let a = asset(name: "unrelated-a.jpg")
        let b = asset(name: "unrelated-b.jpg")
        XCTAssertNil(ApplePhotosVerifier.counterpart(for: item(name: "IMG_9999.HEIC"), among: [a, b]))
    }

    func testASingleMetadataMatchIsTrustedWithoutTheFilename() {
        let only = asset(name: "totally-different-name.jpg")
        XCTAssertEqual(
            ApplePhotosVerifier.counterpart(for: item(), among: [only])?.id,
            only.id
        )
    }

    // MARK: - The refusal to guess

    /// With no library connected the verifier must refuse rather than answer,
    /// so an absent library can never be read as "not present".
    func testAnUnconnectedVerifierRefusesInsteadOfAnswering() async {
        let verifier = UnconnectedCloudVerifier(domain: .appleCloud)
        XCTAssertFalse(verifier.isConnected)
        do {
            _ = try await verifier.verifyPresence(of: [asset()])
            XCTFail("An unconnected verifier must not return results")
        } catch {
            guard case CloudVerificationError.notConnected = error else {
                return XCTFail("Expected notConnected, got \(error)")
            }
        }
    }

    func testLibraryUnavailableReadsAsSomethingOtherThanAbsence() {
        let message = CloudVerificationError.libraryUnavailable(.appleCloud).localizedDescription
        XCTAssertTrue(message.contains("empty"), "Must not be mistakable for 'the photo is not there'")
    }
}
