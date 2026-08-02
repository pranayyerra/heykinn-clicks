import Foundation

struct ImportBatch: Identifiable, Hashable {
    let id: UUID
    var sourcePath: String
    var startedAt: Date
    var completedAt: Date?
    var importedCount: Int
    var duplicateCount: Int
    var failedCount: Int
}
