import Foundation

/// A rule-based residency assignment. Rules are evaluated in priority order
/// (highest first); the first enabled rule whose criteria all match decides
/// the residency of a newly imported asset. Manual overrides always win later.
struct PolicyRule: Identifiable, Hashable {
    let id: UUID
    var name: String
    var priority: Int
    var isEnabled: Bool
    /// nil criteria are wildcards.
    var matchOrigin: ImportOrigin?
    var matchKind: AssetKind?
    var minFileSize: Int64?
    var targetResidency: ResidencyDomain

    func matches(kind: AssetKind, origin: ImportOrigin, fileSize: Int64) -> Bool {
        if let matchOrigin, matchOrigin != origin { return false }
        if let matchKind, matchKind != kind { return false }
        if let minFileSize, fileSize < minFileSize { return false }
        return true
    }
}
