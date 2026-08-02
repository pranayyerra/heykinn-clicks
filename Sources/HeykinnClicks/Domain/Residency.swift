import Foundation

/// The single logical residency domain of an asset in steady state.
/// Exactly one domain per asset; multi-domain overlap is legal only while a
/// `MigrationJob` for that asset is active.
enum ResidencyDomain: String, Codable, CaseIterable, Identifiable, Hashable {
    case local = "local"
    case appleCloud = "appleCloud"
    case googleCloud = "googleCloud"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .local: return "Local"
        case .appleCloud: return "Apple Cloud"
        case .googleCloud: return "Google Cloud"
        }
    }
}

/// How the current residency value was decided.
enum ResidencyAssignmentSource: String, Codable, Hashable {
    case policy
    case manual
    case migration
    case importDefault

    var displayName: String {
        switch self {
        case .policy: return "Policy rule"
        case .manual: return "Manual override"
        case .migration: return "Migration"
        case .importDefault: return "Import default"
        }
    }
}

/// How the app learned that an asset is present in a cloud domain.
///
/// Local presence is always self-evident: the app hashes the bytes itself.
/// Cloud presence cannot be checked without a connected account, so the
/// catalog records the difference rather than presenting a guess as a fact.
/// A Takeout export proves content *was* in Google at export time — never
/// that it is still there.
enum CloudPresenceEvidence: String, Codable, CaseIterable, Hashable {
    /// No cloud presence recorded.
    case none
    /// The user told the app; never independently checked.
    case userAsserted
    /// Confirmed against the provider with a connected account.
    case verified

    var displayName: String {
        switch self {
        case .none: return "—"
        case .userAsserted: return "Stated by you, unverified"
        case .verified: return "Verified with provider"
        }
    }

    var isTrustworthy: Bool { self == .verified }
}

/// Where the app believes the asset's content currently exists, per domain.
/// This is *presence*, not residency: during a migration an asset may be
/// present in two domains while its residency is still transitioning.
struct DomainPresence: Codable, Hashable {
    var local: Bool
    var appleCloud: Bool
    var googleCloud: Bool

    static let none = DomainPresence(local: false, appleCloud: false, googleCloud: false)
    static let localOnly = DomainPresence(local: true, appleCloud: false, googleCloud: false)

    func contains(_ domain: ResidencyDomain) -> Bool {
        switch domain {
        case .local: return local
        case .appleCloud: return appleCloud
        case .googleCloud: return googleCloud
        }
    }

    mutating func set(_ domain: ResidencyDomain, _ value: Bool) {
        switch domain {
        case .local: local = value
        case .appleCloud: appleCloud = value
        case .googleCloud: googleCloud = value
        }
    }

    var domains: [ResidencyDomain] {
        ResidencyDomain.allCases.filter { contains($0) }
    }

    var count: Int { domains.count }
}
