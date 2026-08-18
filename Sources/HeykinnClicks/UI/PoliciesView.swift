import SwiftUI

/// The residency rules, which decide whether a photo is Local or claimed as
/// living in a cloud.
///
/// Lived on a screen of its own beside the storage groups, which put two
/// unrelated questions under one word: how many copies to keep is the archive's
/// central promise, while this is automation most archives never touch — both
/// of the rules on a real one said "stays Local", which is what happens anyway.
/// Groups moved to the copies page, next to the copies they govern; this moved
/// to Settings, next to the other automation.
struct PoliciesView: View {
    @EnvironmentObject private var store: AppStore
    @State private var isAddSheetPresented = false
    @State private var ruleBeingEdited: PolicyRule?

    var body: some View {
        Form {
            Section {
                ForEach(store.policyRules) { rule in
                    ruleRow(rule)
                }
                if store.policyRules.isEmpty {
                    Text("No rules. Photos come in as Local and stay there, which is what most archives want.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } header: {
                // A List section header is a single truncating line, and this
                // ran to four — the reader got "…Manual overrides on an asset
                // always win. A" and a full stop that never came.
                Text("Rules apply as photos come in, and again whenever you change one. The highest-priority rule that matches decides, and anything you set on a photo yourself beats all of them. A rule naming a cloud only ever proposes a move — nothing leaves your drives without one you can see.")
                    .fixedSize(horizontal: false, vertical: true)
                    .textCase(nil)
            }
        }
        .formStyle(.grouped)
        .toolbar {
            ToolbarItem {
                Button {
                    isAddSheetPresented = true
                } label: {
                    Label("Add rule", systemImage: "plus")
                }
            }
        }
        .sheet(isPresented: $isAddSheetPresented) {
            PolicyRuleEditor(existing: nil) { rule in
                store.savePolicyRule(rule)
            }
        }
        .sheet(item: $ruleBeingEdited) { rule in
            PolicyRuleEditor(existing: rule) { updated in
                store.savePolicyRule(updated)
            }
        }
    }

    // A copies stepper used to head this screen: one number for the whole
    // archive, capped at however many devices were registered. Both halves of
    // it were wrong once sources arrived. How many copies, and on which
    // devices, is a question about a particular set of photos — the answer for
    // a Google export has nothing to do with the answer for a folder of scans —
    // and it is asked and answered here, next to the photos it governs. A
    // global number sitting above those could only contradict them.
    //
    // Deleted rather than kept as a default for new sources: `newSourceDefaults`
    // already does that job by remembering the last answer given, and a control
    // presented as policy is read as policy however it is labelled.

    private func ruleRow(_ rule: PolicyRule) -> some View {
        HStack {
            // The row is the way in to editing — a rule you can only create
            // and delete is a rule you retype to fix a typo in.
            Button {
                ruleBeingEdited = rule
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(rule.name)
                        .font(.headline)
                    Text(criteriaDescription(rule))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            Spacer()
            Text("priority \(rule.priority)")
                .font(.caption)
                .foregroundStyle(.secondary)
            ResidencyBadge(domain: rule.targetResidency)
            Toggle("", isOn: Binding(
                get: { rule.isEnabled },
                set: { enabled in
                    var updated = rule
                    updated.isEnabled = enabled
                    store.savePolicyRule(updated)
                }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            Button(role: .destructive) {
                store.deletePolicyRule(rule)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 2)
    }

    private func criteriaDescription(_ rule: PolicyRule) -> String {
        var parts: [String] = []
        if let origin = rule.matchOrigin { parts.append("origin = \(origin.displayName)") }
        if let kind = rule.matchKind { parts.append("kind = \(kind.displayName)") }
        if let minSize = rule.minFileSize { parts.append("size ≥ \(Formatters.bytes.string(fromByteCount: minSize))") }
        return parts.isEmpty ? "Matches everything" : parts.joined(separator: ", ")
    }
}

struct PolicyRuleEditor: View {
    var existing: PolicyRule?
    var onSave: (PolicyRule) -> Void
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var priority = 50
    @State private var matchOrigin: ImportOrigin?
    @State private var matchKind: AssetKind?
    @State private var minSizeMB = 0
    @State private var target: ResidencyDomain = .local

    /// What the rule would govern today, counted live while the user edits.
    /// "Would apply to 3 assets" catches a wrong criterion before Save does.
    private var matchCount: Int {
        let candidate = builtRule()
        return store.assets.filter {
            !$0.isLivePhotoMotion
                && candidate.matches(kind: $0.kind, origin: $0.importOrigin, fileSize: $0.fileSize)
        }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(existing == nil ? "New rule" : "Edit rule")
                .font(.title3)
                .bold()
            Form {
                TextField("Name", text: $name)
                Stepper("Priority: \(priority)", value: $priority, in: 0...200, step: 10)
                Picker("Origin", selection: $matchOrigin) {
                    Text("Any").tag(ImportOrigin?.none)
                    ForEach(ImportOrigin.allCases) { origin in
                        Text(origin.displayName).tag(ImportOrigin?.some(origin))
                    }
                }
                Picker("Kind", selection: $matchKind) {
                    Text("Any").tag(AssetKind?.none)
                    ForEach(AssetKind.allCases) { kind in
                        Text(kind.displayName).tag(AssetKind?.some(kind))
                    }
                }
                Stepper("Minimum size: \(minSizeMB) MB", value: $minSizeMB, in: 0...10_000, step: 50)
                Picker("Keep them in", selection: $target) {
                    ForEach(ResidencyDomain.allCases) { domain in
                        Text(domain.displayName).tag(domain)
                    }
                }
            }
            Text("Would apply to \(Formatters.count(matchCount, "existing asset")).")
                .font(.caption)
                .foregroundStyle(.secondary)
            if target != .local {
                Text("A rule cannot put photos into \(target.displayName) — the ones it matches stay on your drives and are queued as a move, which happens when you carry it out.")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    onSave(builtRule())
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 440)
        .onAppear {
            guard let existing else { return }
            name = existing.name
            priority = existing.priority
            matchOrigin = existing.matchOrigin
            matchKind = existing.matchKind
            minSizeMB = existing.minFileSize.map { Int($0 / (1024 * 1024)) } ?? 0
            target = existing.targetResidency
        }
    }

    private func builtRule() -> PolicyRule {
        PolicyRule(
            id: existing?.id ?? UUID(),
            name: name.isEmpty ? "Untitled rule" : name,
            priority: priority,
            isEnabled: existing?.isEnabled ?? true,
            matchOrigin: matchOrigin,
            matchKind: matchKind,
            minFileSize: minSizeMB > 0 ? Int64(minSizeMB) * 1024 * 1024 : nil,
            targetResidency: target
        )
    }
}
