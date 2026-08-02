import Foundation

/// Seam for confirming, against a connected account, whether assets really are
/// still present in a cloud domain.
///
/// Nothing implements this yet: the app has no Google or Apple integration, no
/// credentials, and makes no network calls. Until a real verifier exists, the
/// catalog must never record cloud presence as `.verified` — an unconnected
/// domain yields `CloudVerificationError.notConnected`, and callers fall back
/// to recording `.userAsserted` (or nothing at all).
protocol CloudDomainVerifier {
    var domain: ResidencyDomain { get }
    var isConnected: Bool { get }

    /// Asset ID → whether the provider still holds that asset.
    func verifyPresence(of assets: [Asset]) async throws -> [UUID: Bool]
}

enum CloudVerificationError: Error, LocalizedError {
    case notConnected(ResidencyDomain)

    var errorDescription: String? {
        switch self {
        case .notConnected(let domain):
            return "No \(domain.displayName) account is connected, so presence there cannot be verified."
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
