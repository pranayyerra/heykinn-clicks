import SwiftUI

/// Choosing which copy of an export to keep, when a drive is holding two.
struct ExportFormRemovalSheet: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss

    let plan: ExportFormRemoval

    private var keeping: ExportForm { plan.form == .zip ? .unpacked : .zip }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Remove \(plan.form.displayName) from \(plan.driveName)?")
                .font(.title3)
                .bold()
                .fixedSize(horizontal: false, vertical: true)

            if plan.isAllowed {
                Text("Every part of this export stays on \(plan.driveName) — as \(keeping.displayName), which \(keeping.worthKeepingBecause). This frees \(Formatters.bytes.string(fromByteCount: plan.bytes)).")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Text("This deletes files. The other drives are not touched, and nothing about which photos you have changes — both forms hold the same photos, which is why one of them is spare.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ForEach(plan.refusals, id: \.self) { refusal in
                Label(refusal, systemImage: "hand.raised.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if plan.isAllowed {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(plan.files) { file in
                            HStack(alignment: .firstTextBaseline) {
                                Text(file.displayName)
                                    .font(.caption)
                                Spacer(minLength: 8)
                                Text(Formatters.bytes.string(fromByteCount: file.sizeBytes))
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                    .monospacedDigit()
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 150)
            }

            HStack {
                Button(plan.isAllowed ? "Cancel" : "Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                if plan.isAllowed {
                    Button("Remove \(Formatters.count(plan.files.count, "file"))", role: .destructive) {
                        store.removeExportForm(plan)
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(24)
        .frame(width: 500)
    }
}
