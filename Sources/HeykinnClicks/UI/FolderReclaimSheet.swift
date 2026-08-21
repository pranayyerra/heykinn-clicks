import SwiftUI

/// The offer to clear out a folder the archive has already taken everything
/// from, and the one place the app proposes deleting something that is yours.
///
/// Modelled on `ExportFormRemovalSheet`, which had the same job first: say what
/// goes, say what stays, and refuse out loud rather than hiding the button.
///
/// **What stays is as prominent as what goes.** A folder nearly always holds
/// something the app never imported, and the failure to design against is
/// somebody reading "clear the folder" as "the folder disappears".
struct FolderReclaimSheet: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss

    let path: String
    let plan: SourceFolderReclaim.Plan
    @State private var isWorking = false

    private var folderName: String { (path as NSString).lastPathComponent }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Clear out \(folderName)?")
                .font(.title3)
                .bold()
                .fixedSize(horizontal: false, vertical: true)

            if plan.isFolderEmpty {
                // The state a folder is in *after* this sheet has done its job,
                // and the one it used to describe as still holding your
                // photographs. There is nothing here to be waiting on.
                Text("This folder is empty. Everything the app took from it has already gone to the Trash, and there is nothing left here to clear.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            } else if plan.holdsOnlyFilesTheAppNeverTookIn {
                // Nothing is blocked, so nothing is pending — saying copies are
                // still being made would be inventing a wait that is not on.
                Text("Nothing here is a spare copy — the archive holds none of what is still in this folder.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            } else if plan.isEmpty {
                Text("Nothing here can go yet. Every photo the app took from this folder still needs its copies made and read back — until then this folder is one of the places they exist.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("\(Formatters.count(plan.releasable.count, "file")) here — \(Formatters.bytes.string(fromByteCount: plan.releasableBytes)) — are photos your drives already hold and have read back. They go to the Trash, so nothing is gone until you empty it.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if plan.leavesFilesBehind {
                VStack(alignment: .leading, spacing: 6) {
                    Text("The folder stays, and so does everything below.")
                        .font(.callout.weight(.medium))
                    if !plan.notImported.isEmpty {
                        Label(
                            "\(Formatters.count(plan.notImported.count, "file")) the app never took in — \(Formatters.bytes.string(fromByteCount: plan.notImportedBytes)). It has no copy of \(plan.notImported.count == 1 ? "it, so it will not touch it" : "these, so it will not touch them").",
                            systemImage: "hand.raised.fill"
                        )
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(blockedSummaries, id: \.self) { line in
                        Label(line, systemImage: "clock.fill")
                            .font(.caption)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .foregroundStyle(.secondary)
            }

            HStack {
                // Nothing to offer means nothing to decline: one way out, and
                // it is not a cancellation. A greyed-out "Move 0 files to the
                // Trash" is an offer the sheet has just finished explaining it
                // cannot make.
                Button(plan.isEmpty ? "Done" : "Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                if isWorking {
                    ProgressView().controlSize(.small)
                }
                if !plan.isEmpty {
                    Button("Move \(Formatters.count(plan.releasable.count, "file")) to the Trash") {
                        isWorking = true
                        Task {
                            await store.reclaimFolder(at: path)
                            isWorking = false
                            dismiss()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isWorking)
                }
            }
        }
        .padding(24)
        .frame(width: 460)
    }

    /// One line per reason, counted — a list of forty filenames is not a reason.
    private var blockedSummaries: [String] {
        SourceFolderReclaim.Blocker.allCases.compactMap { blocker in
            let count = plan.blocked.values.filter { $0 == blocker }.count
            guard count > 0 else { return nil }
            switch blocker {
            case .notEnoughCopies:
                return "\(Formatters.count(count, "photo")) here \(count == 1 ? "does" : "do") not have all the copies asked for yet."
            case .neverReadBack:
                return "\(Formatters.count(count, "photo")) \(count == 1 ? "has" : "have") copies that have not been read back yet."
            case .damagedCopy:
                return "\(Formatters.count(count, "photo")) \(count == 1 ? "has" : "have") a copy that no longer matches, so this folder is worth keeping."
            }
        }
    }
}
