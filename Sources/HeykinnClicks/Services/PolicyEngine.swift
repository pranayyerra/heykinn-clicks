import Foundation

/// Decides residency for assets from the rule table.
enum PolicyEngine {
    struct Decision: Equatable {
        /// The residency the asset gets *now*. Always satisfiable: an import
        /// proves local presence and nothing else, so this is `.local` even
        /// when the winning rule names a cloud.
        var residency: ResidencyDomain
        var source: ResidencyAssignmentSource
        var matchedRule: PolicyRule?
        /// Set when the winning rule targets a cloud domain. A rule cannot put
        /// content in a cloud — only a migration can — so a cloud target is an
        /// *intent*: the caller opens a pending Local → cloud migration job
        /// rather than writing a residency the presence model would refute.
        var pendingCloudTarget: ResidencyDomain?
    }

    static func assignResidency(
        kind: AssetKind,
        origin: ImportOrigin,
        fileSize: Int64,
        rules: [PolicyRule]
    ) -> Decision {
        let matched = rules
            .filter(\.isEnabled)
            .sorted { $0.priority > $1.priority }
            .first { $0.matches(kind: kind, origin: origin, fileSize: fileSize) }
        guard let matched else {
            // No rule matched: local-first default.
            return Decision(residency: .local, source: .importDefault, matchedRule: nil)
        }
        if matched.targetResidency == .local {
            return Decision(residency: .local, source: .policy, matchedRule: matched)
        }
        return Decision(
            residency: .local,
            source: .policy,
            matchedRule: matched,
            pendingCloudTarget: matched.targetResidency
        )
    }

    /// Origin classification from filename conventions; grows into real
    /// source-aware classification (WhatsApp folders, Takeout structure) later.
    static func classifyOrigin(filename: String, folderHint: String?) -> ImportOrigin {
        let name = filename.uppercased()
        let folder = folderHint?.lowercased() ?? ""
        if name.contains("-WA") || folder.contains("whatsapp") { return .whatsapp }
        if folder.contains("takeout") || folder.contains("google photos") { return .googleTakeout }
        if folder.contains("photos library") || folder.contains("apple") { return .appleExport }
        return .localFolder
    }
}
