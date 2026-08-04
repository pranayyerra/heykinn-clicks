import Foundation

/// Seam for confirming, against a connected account, whether assets really are
/// still present in a cloud domain.
///
/// Nothing implements this yet: the app has no Google or Apple integration, no
/// credentials, and makes no network calls. Until a real verifier exists, the
/// catalog records no cloud presence at all — an unconnected domain yields
/// `CloudVerificationError.notConnected`, and there is no weaker grade to fall
/// back to, because the user cannot be asked to assert presence for 24,000
/// photos and an export is not evidence about now.
///
/// Building this out is the work that makes presence knowable: the app's own
/// index is the source of truth, and this is where it meets the provider.
protocol CloudDomainVerifier {
    var domain: ResidencyDomain { get }
    var isConnected: Bool { get }

    /// Asset ID → whether the provider still holds that asset.
    func verifyPresence(of assets: [Asset]) async throws -> [UUID: Bool]
}

enum CloudVerificationError: Error, LocalizedError {
    case notConnected(ResidencyDomain)
    /// Connected, but there is nothing to look in — an empty or unreachable
    /// library. Distinct from `notConnected` because the remedy differs, and
    /// distinct from a negative answer because it is not one.
    case libraryUnavailable(ResidencyDomain)

    var errorDescription: String? {
        switch self {
        case .notConnected(let domain):
            return "No \(domain.displayName) account is connected, so presence there cannot be verified."
        case .libraryUnavailable(let domain):
            return "The \(domain.displayName) library is reachable but empty, so nothing can be checked against it. If it lives on an external drive, connect it."
        }
    }
}

/// Placeholder until account connection is implemented. Deliberately reports
/// `isConnected == false` and refuses to answer, so no code path can mistake
/// an assumption for a verified fact.
struct UnconnectedCloudVerifier: CloudDomainVerifier {
    let domain: ResidencyDomain
    var isConnected: Bool { false }

    func verifyPresence(of assets: [Asset]) async throws -> [UUID: Bool] {
        throw CloudVerificationError.notConnected(domain)
    }
}

/// Registry of verifiers by domain. Swap an entry for a real implementation
/// once account connection lands; everything downstream keeps working.
struct CloudVerifierRegistry {
    var verifiers: [ResidencyDomain: any CloudDomainVerifier]

    static let unconnected = CloudVerifierRegistry(verifiers: [
        .googleCloud: UnconnectedCloudVerifier(domain: .googleCloud),
        .appleCloud: UnconnectedCloudVerifier(domain: .appleCloud),
    ])

    func verifier(for domain: ResidencyDomain) -> (any CloudDomainVerifier)? {
        verifiers[domain]
    }

    func isConnected(_ domain: ResidencyDomain) -> Bool {
        verifiers[domain]?.isConnected ?? false
    }
}
