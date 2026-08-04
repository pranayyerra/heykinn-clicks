import Foundation

/// Withdrawing a cloud-presence claim the app never verified.
///
/// Earlier versions asked the user to state that content was still in a cloud
/// domain and recorded the answer as presence. Nothing does that any more, and
/// the claims already written are migrated away rather than left behind a
/// manual purge — a claim with no evidence under it is not data worth keeping.
///
/// Pure so the rule can be tested: this rewrites assets in a catalog holding
/// someone's only record of where their photos are.
enum CloudClaimWithdrawal {

    /// The asset with its unverified claim for `domain` removed, or nil when
    /// there is nothing to withdraw.
    ///
    /// **A claim is only withdrawn when the app holds the bytes locally.** The
    /// withdrawal says "this content is here, so the unchecked claim about
    /// somewhere else adds nothing" — which needs the local copy to be true.
    /// Without one, the cloud claim is the only record that the content exists
    /// anywhere, and dropping it would assert the asset is nowhere at all: a
    /// stronger and far worse falsehood than the unverified claim it replaces.
    /// Such assets are left exactly as they are.
    static func withdraw(
        _ domain: ResidencyDomain,
        from asset: Asset,
        now: Date = Date()
    ) -> Asset? {
        guard isWithdrawable(asset, domain: domain) else { return nil }

        var updated = asset
        updated.presence.set(domain, false)
        updated.cloudPresenceEvidence = .none
        updated.cloudPresenceCheckedAt = nil
        if updated.residency == domain {
            // Residency follows the content that actually exists, and the local
            // copy is what withdrawal rests on.
            updated.residency = .local
            updated.residencySource = .manual
        }
        updated.updatedDate = now
        return updated
    }

    /// Whether this asset carries a cloud claim the app never checked.
    static func isUnverifiedClaim(_ asset: Asset, domain: ResidencyDomain) -> Bool {
        domain != .local
            && asset.presence.contains(domain)
            && asset.cloudPresenceEvidence != .verified
    }

    /// An unverified claim the app can safely drop, because it holds the
    /// content itself. Distinct from `isUnverifiedClaim`: a claim can be
    /// unfounded and still be the only thing pointing at the content.
    static func isWithdrawable(_ asset: Asset, domain: ResidencyDomain) -> Bool {
        isUnverifiedClaim(asset, domain: domain) && asset.presence.local
    }
}
