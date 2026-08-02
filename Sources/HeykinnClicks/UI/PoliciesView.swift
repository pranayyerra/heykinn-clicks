import SwiftUI

struct PoliciesView: View {
    @EnvironmentObject private var store: AppStore
    @State private var isAddSheetPresented = false

    var body: some View {
        List {
            Section {
                ForEach(store.policyRules) { rule in
                    ruleRow(rule)
                }
            } header: {
                Text("Rules run at import, highest priority first; the first match assigns residency. Manual overrides on an asset always win afterwards. Unmatched assets default to Local.")
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
            PolicyRuleEditor { rule in
                store.savePolicyRule(rule)
            }
        }
    }

    private func ruleRow(_ rule: PolicyRule) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(rule.name)
                    .font(.headline)
                Text(criteriaDescription(rule))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
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
    var onSave: (PolicyRule) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var priority = 50
    @State private var matchOrigin: ImportOrigin?
    @State private var matchKind: AssetKind?
    @State private var minSizeMB = 0
    @State private var target: ResidencyDomain = .local

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New residency rule")
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
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    onSave(PolicyRule(
                        id: UUID(),
                        name: name.isEmpty ? "Untitled rule" : name,
                        priority: priority,
                        isEnabled: true,
                        matchOrigin: matchOrigin,
                        matchKind: matchKind,
                        minFileSize: minSizeMB > 0 ? Int64(minSizeMB) * 1024 * 1024 : nil,
                        targetResidency: target
                    ))
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 440)
    }
}
