import Foundation

/// The two shapes one part of an export can be held in, and what each is for.
///
/// A part arrives as a zip. Unpacking it produces a folder beside it and does
/// not remove the zip, so a drive can end up holding the same 10 GB twice —
/// which on a real archive it did, twelve times over, across a whole export.
/// Nothing told anybody, because from the storage model's point of view either
/// form is simply "the part is here".
///
/// Both are legitimate. The zip is the artefact Google produced, byte for byte;
/// the folder is what a re-read walks without decompressing it all first. What
/// is not legitimate is holding both by accident and never being asked.
enum ExportForm: String, Hashable, CaseIterable {
    case zip
    case unpacked

    var kind: TakeoutArchiveKind { self == .zip ? .zip : .folder }

    var displayName: String {
        switch self {
        case .zip: return "the original zips"
        case .unpacked: return "the unpacked copies"
        }
    }

    /// Why somebody would keep this one, said in the sentence that offers to
    /// remove the other.
    var worthKeepingBecause: String {
        switch self {
        case .zip:
            return "exactly what Google produced, and the smaller of the two to keep"
        case .unpacked:
            return "what a re-read walks straight through, with nothing to decompress first"
        }
    }
}

/// What one drive holds of one export, and what could safely go.
struct ExportFormAudit: Equatable {
    var setID: String
    var targetID: UUID
    var driveName: String
    /// Parts held in both forms at once — the duplication worth surfacing.
    var partsInBothForms: [Int]
    var bytesByForm: [ExportForm: Int64]

    var duplicatedBytes: Int64 {
        guard !partsInBothForms.isEmpty else { return 0 }
        return min(bytesByForm[.zip] ?? 0, bytesByForm[.unpacked] ?? 0)
    }

    var holdsBothForms: Bool { !partsInBothForms.isEmpty }
}

/// Removing one form of an export from one drive.
///
/// The dangerous operation on this screen, and the only one that deletes
/// anything, so it says no more readily than yes.
struct ExportFormRemoval: Equatable, Identifiable {
    struct File: Equatable, Identifiable {
        var archiveID: UUID
        var displayName: String
        var path: String
        var sizeBytes: Int64
        var id: UUID { archiveID }
    }

    var setID: String
    var targetID: UUID
    var driveName: String
    var form: ExportForm
    var files: [File]
    var bytes: Int64
    /// Why this cannot be done, if it cannot. Non-empty means refuse.
    var refusals: [String]

    var id: String { "\(setID)|\(targetID.uuidString)|\(form.rawValue)" }
    var isAllowed: Bool { refusals.isEmpty && !files.isEmpty }

    /// What a drive holds of an export, by form.
    static func audit(
        forSet setID: String,
        target: ReplicationTarget,
        archives: [TakeoutArchive]
    ) -> ExportFormAudit {
        let mine = archives.filter {
            $0.exportSetID == setID && $0.targetID == target.id && $0.holdsBytes
        }
        var partsByForm: [ExportForm: Set<Int>] = [:]
        var bytes: [ExportForm: Int64] = [:]
        for archive in mine {
            guard let part = archive.partNumber else { continue }
            let form: ExportForm = archive.kind == .zip ? .zip : .unpacked
            partsByForm[form, default: []].insert(part)
            bytes[form, default: 0] += archive.sizeBytes
        }
        let both = (partsByForm[.zip] ?? []).intersection(partsByForm[.unpacked] ?? [])
        return ExportFormAudit(
            setID: setID, targetID: target.id, driveName: target.name,
            partsInBothForms: both.sorted(), bytesByForm: bytes
        )
    }

    /// What removing one form would delete, and every reason it must not.
    ///
    /// - Parameter replicasPointingIntoZips: how many recorded copies on this
    ///   drive name a zip of this export *inside themselves*. A photo counted
    ///   as a member of a zip is stored nowhere else on that drive, so deleting
    ///   the zip deletes the photo's only copy there while every catalog-only
    ///   check goes on reporting it present.
    static func plan(
        removing form: ExportForm,
        setID: String,
        target: ReplicationTarget,
        archives: [TakeoutArchive],
        replicasPointingIntoZips: Int
    ) -> ExportFormRemoval {
        let mine = archives.filter {
            $0.exportSetID == setID && $0.targetID == target.id && $0.holdsBytes
        }
        let surviving = Set(
            mine.filter { ($0.kind == .zip ? ExportForm.zip : .unpacked) != form }
                .compactMap(\.partNumber)
        )
        let going = mine.filter { ($0.kind == .zip ? ExportForm.zip : .unpacked) == form }

        var refusals: [String] = []
        // Every part losing this form must still have the other one here. A
        // part held only as a zip on this drive is that drive's whole copy of
        // it, whatever the other drives have.
        let stranded = going.compactMap(\.partNumber).filter { !surviving.contains($0) }.sorted()
        if !stranded.isEmpty {
            refusals.append(
                "\(Formatters.count(stranded.count, "part")) of this export "
                + "\(stranded.count == 1 ? "is" : "are") held on \(target.name) only in this form. "
                + "Removing it would take \(stranded.count == 1 ? "that part" : "those parts") off this drive entirely."
            )
        }
        // Zip members are recorded as living inside a specific zip. Deleting it
        // leaves them reading as present at a path with nothing in it, which no
        // check that consults only the catalog can ever notice.
        if form == .zip, replicasPointingIntoZips > 0 {
            refusals.append(
                "\(Formatters.count(replicasPointingIntoZips, "photo")) on \(target.name) "
                + "\(replicasPointingIntoZips == 1 ? "is" : "are") counted as living inside these zips rather than as files of "
                + "\(replicasPointingIntoZips == 1 ? "its" : "their") own. Unpack them first and they will be counted where the bytes are."
            )
        }

        return ExportFormRemoval(
            setID: setID, targetID: target.id, driveName: target.name, form: form,
            files: going
                .map {
                    File(
                        archiveID: $0.id, displayName: $0.displayName,
                        path: $0.path, sizeBytes: $0.sizeBytes
                    )
                }
                .sorted { $0.displayName < $1.displayName },
            bytes: going.reduce(0) { $0 + $1.sizeBytes },
            refusals: refusals
        )
    }
}
