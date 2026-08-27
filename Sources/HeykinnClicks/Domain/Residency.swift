import Foundation

/// The single logical residency domain of an asset in steady state.
/// Exactly one domain per asset; multi-domain overlap is legal only while a
/// `MigrationJob` for that asset is active.
enum ResidencyDomain: String, Codable, CaseIterable, Identifiable, Hashable {
    case local = "local"
    case appleCloud = "appleCloud"
    case googleCloud = "googleCloud"

    var id: String { rawValue }

    /// What a person calls these places.
    ///
    /// **"Local", "Apple Cloud" and "Google Cloud" were the app's names for
    /// them, not anybody else's** — and they reached the screen, in a filter
    /// headed "All domains", which is a word this app invented and invariant 19
    /// forbids. Somebody with photographs says "my drives" and "iCloud".
    ///
    /// Chosen to read as a noun in a sentence as well as on its own, because
    /// these appear both ways: "Release the iCloud copies" and "Kept on:
    /// My drives".
    var displayName: String {
        switch self {
        case .local: return "My drives"
        case .appleCloud: return "iCloud"
        case .googleCloud: return "Google Photos"
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
/// Cloud presence cannot be checked without a connected account, so until one
/// exists there is nothing to record.
///
/// There are deliberately only two levels. The app never asks the user to
/// assert presence — nobody reviews a whole archive to confirm each is still in
/// Google, and an answer collected that way is a guess wearing the user's
/// authority. Nor is presence inferred from an export, which proves content was
/// in Google *at export time* and nothing about now. A middle grade would only
/// ever be read as the stronger one, and reading it that way is what deletes
/// somebody's only copy.
enum CloudPresenceEvidence: String, Codable, CaseIterable, Hashable {
    /// No claim: the default, and the only value until an account is connected.
    case none
    /// Confirmed against the provider with a connected account.
    case verified

    var displayName: String {
        switch self {
        case .none: return "—"
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
