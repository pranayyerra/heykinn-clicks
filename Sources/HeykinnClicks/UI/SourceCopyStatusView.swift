import SwiftUI

/// Where one source's photos are, drawn the same way for every source.
///
/// Written to be read by someone who has not learned the app's words. It says
/// "device" rather than "target", and it leads with whether the photos are
/// safe before it gets to which disk holds what.
///
/// The headline counts **photos**, and the rows count **contributions**. That
/// split is the whole point: under `k`-of-`n` your devices are supposed to hold
/// different things, so a device holding some of a folder and not the rest is
/// not behind on anything — while a photo sitting on one device when the policy
/// asks for two is the actual problem, and it is invisible if you only look
/// device by device.
struct SourceCopyStatusView: View {
    let status: SourceCopyStatus
    /// Folders can be emptied by hand, so their load-bearing warning matters;
    /// a caller that has already said it can turn this off rather than saying
    /// it twice.
    var showsLoadBearingWarning = true

    @ViewBuilder
    var body: some View {
        if status.total > 0 {
            VStack(alignment: .leading, spacing: 6) {
                headline
                if !status.destinations.isEmpty {
                    Text("Kept on")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .padding(.top, 2)
                    ForEach(status.destinations) { placement in
                        row(placement)
                    }
                }
                // Copies on devices this source no longer names — after a
                // retarget, usually. Not a fault, but space the user should be
                // able to see rather than wonder about.
                if !status.leftovers.isEmpty {
                    Text("Also still on")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .padding(.top, 2)
                    ForEach(status.leftovers) { placement in
                        row(placement)
                    }
                }
                if status.waitingInCorridor > 0 {
                    Label(
                        "\(Formatters.count(status.waitingInCorridor, "photo")) are being held on this Mac so a device that is not connected can be given them next time it is.",
                        systemImage: "tray.and.arrow.down"
                    )
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                if showsLoadBearingWarning, status.loadBearing > 0 {
                    Label(loadBearingText, systemImage: "pin")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: - Headline

    private struct Verdict {
        var text: String
        var symbol: String
        var tint: Color
    }

    private var headline: some View {
        let verdict = self.verdict
        return Label(verdict.text, systemImage: verdict.symbol)
            .font(.caption.weight(.medium))
            .foregroundStyle(verdict.tint)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// One line, about photos. Ordered by what the reader most needs to know:
    /// nowhere named, then not enough named, then short of copies, then safe.
    private var verdict: Verdict {
        let copies = Formatters.count(status.desiredCopies, "copy", "copies")

        if status.hasNoDestinations {
            return Verdict(
                text: "No device is chosen for these yet — pick where they should be kept.",
                symbol: "exclamationmark.triangle.fill",
                tint: .orange
            )
        }
        if status.hasTooFewDestinations {
            return Verdict(
                text: "Set to keep \(copies) but only \(Formatters.count(status.destinationCount, "device")) is chosen. Choosing another is the only thing that fixes it.",
                symbol: "exclamationmark.triangle.fill",
                tint: .orange
            )
        }
        if status.unprotected > 0 {
            return Verdict(
                text: "\(Formatters.count(status.unprotected, "photo")) here are not on any of your devices yet.",
                symbol: "exclamationmark.triangle.fill",
                tint: .orange
            )
        }
        if status.partlyProtected > 0 {
            return Verdict(
                text: "\(Formatters.count(status.partlyProtected, "photo")) here have fewer than \(copies) — still being copied.",
                symbol: "arrow.triangle.2.circlepath",
                tint: .orange
            )
        }
        return Verdict(
            text: status.total == 1
                ? "Kept on \(copies), as your policy asks."
                : "All \(status.total.formatted()) are on \(copies), as your policy asks.",
            symbol: "checkmark.circle.fill",
            tint: .green
        )
    }

    private var loadBearingText: String {
        status.loadBearing == status.total
            ? "This folder holds one of the archive's copies of these photos. Moving it is fine; emptying it is not."
            : "\(Formatters.count(status.loadBearing, "photo")) here are kept where they are rather than copied, so this folder holds one of the archive's copies of them."
    }

    // MARK: - One device's share

    private func row(_ placement: SourceCopyStatus.Placement) -> some View {
        HStack(spacing: 8) {
            Image(systemName: placement.kind == .hostDevice ? "laptopcomputer" : "externaldrive.fill")
                .font(.caption)
                .foregroundStyle(placement.isSatisfied ? Color.green : Color.secondary)
                .frame(width: 14)
            Text(placement.name)
                .font(.caption)
            // Connection state only where it changes what the reader can do.
            // An external drive being unplugged explains why nothing is
            // moving; this Mac being "connected" is noise.
            if placement.kind != .hostDevice, !placement.isReachable {
                Text("not connected")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Text(detail(placement))
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(Color.secondary)
        }
    }

    /// A named device is measured against the whole source, because it was
    /// asked to hold all of it. An unnamed one is only reporting what it still
    /// happens to carry.
    private func detail(_ placement: SourceCopyStatus.Placement) -> String {
        var parts: [String] = []
        if placement.held == status.total {
            parts.append("all \(status.total.formatted())")
        } else {
            parts.append("\(placement.held.formatted()) of \(status.total.formatted())")
        }
        if placement.pending > 0 {
            parts.append("\(placement.pending.formatted()) copying")
        }
        if placement.owed > 0 {
            parts.append("\(placement.owed.formatted()) to go · \(Formatters.bytes.string(fromByteCount: placement.owedBytes))")
        }
        if placement.archiveBacked > 0 {
            // Not the same as a copy the app wrote: these are the source's own
            // files, counted where they sit. Worth distinguishing, because
            // deleting them is the one way to lose this copy — and because a
            // retarget can delete the app's copies and not these.
            parts.append(placement.archiveBacked == placement.held
                         ? "in place"
                         : "\(placement.archiveBacked.formatted()) in place")
        }
        return parts.joined(separator: " · ")
    }
}
