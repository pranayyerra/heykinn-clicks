import SwiftUI

/// One block per file of a Google download, coloured by how well it is held.
///
/// A download is a dozen large zips and its state is per-file: nine on both
/// drives, two on one, one missing. Prose can only summarise that — "12 files ·
/// 127.2 GB · on every drive, copies match on a spot check" is four facts
/// averaged into a sentence, and the moment they stop agreeing it becomes
/// "Files 3, 4 and 7 of this download are not on Desk Drive yet", which is a
/// sentence the reader has to reassemble into a picture.
///
/// The picture is small enough to draw. Twelve blocks, numbered, in the colour
/// of what is true about each — and the shortfall is a shape you see rather
/// than a list you parse.
struct ExportPartGrid: View {
    let parts: [ExportPart]
    /// Every archive of this export, not just the canonical copy per drive.
    /// A drive can hold both the .zip and the folder unpacked from it, and the
    /// plan keeps only one of them — so asking the plan "what have I got?"
    /// silently drops half the answer to the question this detail exists for.
    let archives: [TakeoutArchive]
    let managedTargetIDs: Set<UUID>
    /// How many copies this export set asks for.
    let copiesRequired: Int
    let driveNames: [UUID: String]
    @State private var selected: ExportPart.ID?

    private func grade(_ part: ExportPart) -> PartRedundancy {
        part.redundancy(acrossTargets: managedTargetIDs, copiesRequired: copiesRequired)
    }

    private func tint(_ grade: PartRedundancy) -> Color {
        switch grade {
        case .redundantVerified, .redundantSpotChecked, .redundantUnverified: return .green
        // Informational, not a warning. Nothing is missing and nothing is
        // wrong; the two copies are simply in forms that cannot be compared.
        case .redundantIncomparable: return .teal
        case .singleCopyByPolicy: return .teal
        case .singleCopy: return .orange
        case .absent: return .red
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 34, maximum: 44), spacing: 6)],
                spacing: 6
            ) {
                ForEach(parts.sorted { $0.partNumber < $1.partNumber }) { part in
                    block(part)
                }
            }
            legend
            if let selected, let part = parts.first(where: { $0.id == selected }) {
                detail(part)
            }
        }
    }

    private func block(_ part: ExportPart) -> some View {
        let grade = grade(part)
        let isSelected = selected == part.id
        return Button {
            selected = isSelected ? nil : part.id
        } label: {
            Text("\(part.partNumber)")
                .font(.caption.weight(.medium))
                .monospacedDigit()
                .frame(maxWidth: .infinity)
                .frame(height: 30)
                .background(tint(grade).opacity(grade == .absent ? 0.22 : 0.18), in: RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(tint(grade).opacity(isSelected ? 1 : 0.45), lineWidth: isSelected ? 2 : 1)
                )
                .foregroundStyle(tint(grade))
        }
        .buttonStyle(.plain)
        .help("File \(part.partNumber): \(grade.displayName)")
        .accessibilityLabel("File \(part.partNumber), \(grade.displayName)")
    }

    /// Only the states actually present. A key explaining four colours when
    /// the grid uses one is furniture, and it is the case a healthy archive is
    /// always in.
    private var legend: some View {
        let present = Set(parts.map { grade($0) })
            .sorted { $0.severityOrder < $1.severityOrder }
        return HStack(spacing: 12) {
            ForEach(present, id: \.self) { grade in
                HStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(tint(grade).opacity(0.5))
                        .frame(width: 10, height: 10)
                    Text(grade.plainDescription)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func detail(_ part: ExportPart) -> some View {
        // Named per drive with the form it is held in. A part can be the
        // original .zip or the folder somebody unpacked from it, and both
        // count as a copy — the app has always treated them alike and never
        // said which one you actually have, which is the difference between
        // "I can hand this to the other drive" and "I can browse it".
        let holders = archives
            .filter {
                $0.partNumber == part.partNumber && $0.exportSetID == part.setID
                    && $0.holdsBytes && $0.targetID.map(managedTargetIDs.contains) == true
            }
            .map { (name: driveNames[$0.targetID!] ?? "a drive", archive: $0) }
            .sorted { ($0.name, $0.archive.kind == .zip ? 0 : 1) < ($1.name, $1.archive.kind == .zip ? 0 : 1) }
        // The devices this export names, not every device registered — a Mac
        // that was never asked to hold the zips does not owe a copy of them.
        let missing = managedTargetIDs.subtracting(part.targetIDs)
            .compactMap { driveNames[$0] }
            .sorted()

        return VStack(alignment: .leading, spacing: 6) {
            Text("File \(part.partNumber) · \(Formatters.bytes.string(fromByteCount: part.sizeBytes))")
                .font(.callout)
            if holders.isEmpty {
                Text("On no drive the app knows about.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(holders, id: \.archive.id) { holder in
                    HStack(spacing: 8) {
                        Image(systemName: holder.archive.kind == .zip ? "doc.zipper" : "folder")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("\(holder.name) — \(holder.archive.kind == .zip ? "the .zip" : "unpacked into a folder")")
                            .font(.caption)
                        Spacer(minLength: 0)
                        RevealButton(path: holder.archive.path, label: "Show")
                    }
                }
            }
            if !missing.isEmpty {
                Text("Not yet on \(missing.joined(separator: " or ")).")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }
}

extension PartRedundancy {
    /// Worst first, so the legend reads in the order a reader cares about.
    var severityOrder: Int {
        switch self {
        case .absent: return 0
        case .singleCopy: return 1
        case .singleCopyByPolicy: return 2
        case .redundantUnverified: return 3
        case .redundantSpotChecked: return 4
        case .redundantIncomparable: return 3
        case .redundantVerified: return 5
        }
    }

    /// The legend's words. `displayName` is written for a reader looking at
    /// one part; this has to make sense as a two-word key under a grid.
    var plainDescription: String {
        switch self {
        case .absent: return "on no drive"
        case .singleCopy: return "one copy only"
        case .singleCopyByPolicy: return "one copy, as asked"
        case .redundantUnverified: return "on every drive"
        case .redundantSpotChecked: return "spot-checked"
        case .redundantIncomparable: return "on every drive, in different forms"
        case .redundantVerified: return "checked in full"
        }
    }
}
