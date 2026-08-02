import Foundation

/// Decides residency for newly imported assets from the rule table.
enum PolicyEngine {
    struct Decision {
        var residency: ResidencyDomain
        var source: ResidencyAssignmentSource
        var matchedRule: PolicyRule?
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
        if let matched {
            return Decision(residency: matched.targetResidency, source: .policy, matchedRule: matched)
        }
        // No rule matched: local-first default.
        return Decision(residency: .local, source: .importDefault, matchedRule: nil)
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
