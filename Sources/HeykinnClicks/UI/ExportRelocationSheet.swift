import SwiftUI

/// The offer to keep an export in the app's folder, with everything it would
/// do shown before it is agreed to.
///
/// A preview rather than a confirmation. "Move these files?" is a question
/// somebody answers yes to without learning anything; what they need to see is
/// which files, from where, to where, and — the part no other screen would ever
/// tell them — that thousands of recorded copies name the old folder inside
/// themselves and are being rewritten along with it.
struct ExportRelocationSheet: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss

    let plan: ExportRelocation

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Keep this export in the app's folder on \(plan.driveName)?")
                .font(.title3)
                .bold()
                .fixedSize(horizontal: false, vertical: true)

            Text("Nothing is copied and nothing leaves the drive. Each file is renamed on the same disk, which is instant however large it is — \(Formatters.bytes.string(fromByteCount: plan.bytes)) here.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 3) {
                Text("Into")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(plan.destinationDirectory)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !plan.moves.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(plan.moves) { move in
                            VStack(alignment: .leading, spacing: 1) {
                                Text(move.displayName)
                                    .font(.caption.weight(.medium))
                                Text(move.from)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 180)
            }

            if plan.replicaPathsToRewrite > 0 {
                // The largest thing this does and the least visible.
                Label(
                    "\(Formatters.count(plan.replicaPathsToRewrite, "photo")) on this drive are counted inside these files rather than copied out, so they record the folder they sit in. Those records are rewritten with the move — if that did not happen they would still read as present, at a path with nothing there.",
                    systemImage: "arrow.triangle.branch"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            if !plan.blocked.isEmpty {
                Label(
                    "\(Formatters.count(plan.blocked.count, "file")) will be left where \(plan.blocked.count == 1 ? "it is" : "they are") — something is already at that name in the app's folder: \(plan.blocked.joined(separator: ", ")).",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Move \(Formatters.count(plan.moves.count, "file"))") {
                    store.relocateExport(plan)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(plan.moves.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 520)
    }
}
