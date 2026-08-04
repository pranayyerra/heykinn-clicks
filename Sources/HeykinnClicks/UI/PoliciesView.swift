import SwiftUI

struct PoliciesView: View {
    @EnvironmentObject private var store: AppStore
    @State private var isAddSheetPresented = false
    @State private var ruleBeingEdited: PolicyRule?

    var body: some View {
        List {
            Section {
                redundancyRow
            } header: {
                Text("How many copies of every Local photo to keep, and where photos are sent.")
            }
            Section {
                ForEach(store.policyRules) { rule in
                    ruleRow(rule)
                }
            } header: {
                Text("Rules apply at import and re-apply whenever a rule changes; the first match (highest priority) decides. Manual overrides on an asset always win. A rule naming a cloud queues a pending migration — content never changes residency without one.")
            }
        }
        .navigationTitle("Policies")
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

    /// The number the whole protection model is judged against. It was
    /// hardcoded and invisible while the app enforced it — capping target
    /// registration at a figure the user could neither see nor change.
    private var redundancyRow: some View {
        let targetCount = store.targets.count
        // What was asked for, not what is currently possible. The stepper used
        // to read the bounded number back, so with no drives registered it sat
        // at one and could not be raised — the control for the app's central
        // promise was unusable exactly when a new user would reach for it.
        let desired = store.requestedCopies
        return VStack(alignment: .leading, spacing: 6) {
            Stepper(
                value: Binding(
                    get: { store.requestedCopies },
                    set: { store.redundancyPolicy = LocalRedundancyPolicy(desiredCopies: $0) }
                ),
                in: 1...max(store.maxSettableCopies, LocalRedundancyPolicy.default.desiredCopies)
            ) {
                HStack {
                    Label("Keep \(LocalRedundancyPolicy(desiredCopies: desired).description)", systemImage: "square.stack.3d.up")
                        .font(.headline)
                    Spacer()
                    Text(targetCount == 1 ? "1 drive registered" : "\(targetCount) drives registered")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Text(redundancyNote(desired: desired, targets: targetCount))
                .font(.caption)
                .foregroundStyle(desired > targetCount ? .orange : .secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)
    }

    private func redundancyNote(desired: Int, targets: Int) -> String {
        if targets == 0 {
            return "Register a target in Storage & Health first — the policy cannot ask for more copies than you have places to keep them."
        }
        if desired == targets {
            return "That is every target you have registered. Add another in Storage & Health to raise this."
        }
        return "\(targets - desired) target(s) beyond what the policy asks for. Every registered target still holds a full copy; this is the number that must hold a photo before it counts as safe. Lowering it never deletes anything."
    }

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
            Text(existing == nil ? "New residency rule" : "Edit rule")
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
                Picker("Assign residency", selection: $target) {
                    ForEach(ResidencyDomain.allCases) { domain in
                        Text(domain.displayName).tag(domain)
                    }
                }
            }
            Text("Would apply to \(matchCount.formatted()) existing asset(s).")
                .font(.caption)
                .foregroundStyle(.secondary)
            if target != .local {
                Text("A rule cannot put content in \(target.displayName) — matching assets stay Local and are queued as a pending migration, which runs when you (or a future connector) carry it out.")
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
