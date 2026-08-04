import Foundation

struct ImportBatch: Identifiable, Hashable {
    let id: UUID
    /// Where this import came from, as something to show a person.
    ///
    /// Named `sourcePath`, and it is one for a folder import — but three of
    /// the four things that write it put a label here instead: "Takeout export
    /// 20260710T081521Z-2 (3 parts)", "Recovered import (Google Takeout)". The
    /// name promises a path and the values are sometimes prose, which is a trap
    /// for anything that reads it: a screen listing "folders you have added"
    /// took every batch at its word and showed somebody seven Takeout imports
    /// as folders they had chosen, with no paths, because there were none.
    var sourcePath: String
    var startedAt: Date
    var completedAt: Date?
    var importedCount: Int
    var duplicateCount: Int
    var failedCount: Int
    /// What kind of import this was. Recorded rather than guessed from the
    /// description, because the description is free text and a screen that
    /// pattern-matches prose to decide what something is will be wrong the
    /// first time the wording changes.
    var origin: ImportOrigin?

    /// Whether `sourcePath` is a place on disk, as opposed to a label. Only a
    /// real path is worth showing as one, or offering to open.
    var isFilesystemPath: Bool { sourcePath.hasPrefix("/") }

    /// True for imports somebody performed by pointing at a folder — the ones
    /// "folders you have added" means.
    var isFolderImport: Bool {
        switch origin {
        case .localFolder, .whatsapp, .messagingApp: return true
        case .googleTakeout, .appleExport, .unknown, nil: return false
        }
    }
}
