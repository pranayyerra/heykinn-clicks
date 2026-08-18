import XCTest
@testable import HeykinnClicks

/// Rules the documentation states, checked against the thing they describe.
///
/// **Why these exist.** A doc that says "23 of 23 files in `Domain/` import only
/// `Foundation`" is false the next time somebody adds a file, and nothing
/// notices — a census of the repository rots by the hour and re-auditing it by
/// hand is how it got three separate wrong numbers in the first place. The
/// claims worth making are rules, and a rule can be enforced. So the documents
/// state the rule and point here, and this fails when the rule stops holding.
final class DocumentedRulesTests: XCTestCase {

    /// The package root, derived from this file rather than the working
    /// directory, which differs between `swift test` and Xcode.
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // HeykinnClicksTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // root
    }

    // MARK: - Portability

    /// **`Domain/` imports nothing another platform would not have.**
    ///
    /// `Foundation` unconditionally; anything else only behind
    /// `#if canImport(...)` with a fallback that compiles when it is absent.
    /// That is the foundation of the O2 tiers: a status reader on another
    /// platform needs the model and none of Apple.
    ///
    /// The distinction is the whole rule rather than a technicality.
    /// `Digest256` does import CryptoKit — guarded, with `SHA256Reference`
    /// underneath it — and is portable *because of* the guard. A flat "only
    /// Foundation" reading would fail it and be wrong; an "it is fine, it is
    /// only one import" reading would pass an unguarded one and be worse.
    func testEveryDomainFileImportsOnlyPortableModules() throws {
        let domain = repositoryRoot
            .appendingPathComponent("Sources/HeykinnClicks/Domain", isDirectory: true)
        let files = try swiftFiles(under: domain)
        XCTAssertFalse(files.isEmpty, "found no Domain sources — has the layout moved?")

        var offenders: [String] = []
        for file in files {
            var guardDepth = 0
            var unguarded: [String] = []
            for raw in try String(contentsOf: file, encoding: .utf8).split(separator: "\n") {
                let line = raw.trimmingCharacters(in: .whitespaces)
                if line.hasPrefix("#if canImport(") { guardDepth += 1; continue }
                if line.hasPrefix("#endif") { guardDepth = max(0, guardDepth - 1); continue }
                guard guardDepth == 0, line.hasPrefix("import ") else { continue }
                let module = String(line.dropFirst("import ".count))
                    .trimmingCharacters(in: .whitespaces)
                if module != "Foundation" { unguarded.append(module) }
            }
            if !unguarded.isEmpty {
                offenders.append("\(file.lastPathComponent): \(unguarded.joined(separator: ", "))")
            }
        }
        XCTAssertEqual(
            offenders, [],
            """
            Domain/ is the part of the app another platform can carry over \
            unchanged, and these files now need something it may not have, \
            unguarded. Either put it behind #if canImport with a fallback \
            that compiles without it — Digest256 and SHA256Reference are the \
            worked example — or MULTI_DEVICE_STATE.md's O2 tiers need revisiting.
            """
        )
    }

    // MARK: - The invariant list

    /// **Every invariant is numbered once, and they run in order.**
    ///
    /// Code cites invariants by number — `invariant 12` in `StorageGroup`,
    /// `invariant 13` in `AppStore`. The list had two number 15s, and both were
    /// cited in live text meaning different things, so a reader following
    /// either citation had even odds of arriving at the wrong rule. That is a
    /// broken cross-reference, and nothing but a person reading carefully was
    /// ever going to catch it.
    func testSpecInvariantsAreNumberedOnceAndInOrder() throws {
        let numbers = try specInvariantNumbers()
        XCTAssertGreaterThan(numbers.count, 10, "parsed almost no invariants — has the heading changed?")

        let duplicates = Set(numbers.filter { n in numbers.filter { $0 == n }.count > 1 })
        XCTAssertEqual(duplicates.sorted(), [], "invariant numbers used more than once")
        XCTAssertEqual(numbers, numbers.sorted(), "invariants are printed out of numeric order")
        XCTAssertEqual(numbers, Array(1...numbers.count), "the invariant numbering has a gap")
    }

    /// **Every `invariant N` citation points at one that exists.**
    ///
    /// The other half: renumbering the list is safe only if something checks
    /// that the references followed.
    func testEveryCitedInvariantNumberExists() throws {
        let defined = Set(try specInvariantNumbers())
        var dangling: [String] = []

        for directory in ["Sources", "Tests", "docs"] {
            let root = repositoryRoot.appendingPathComponent(directory, isDirectory: true)
            for file in try filesUnder(root, matchingExtensions: ["swift", "md"]) {
                let text = try String(contentsOf: file, encoding: .utf8)
                for cited in citedInvariantNumbers(in: text) where !defined.contains(cited) {
                    dangling.append("\(file.lastPathComponent) cites invariant \(cited)")
                }
            }
        }
        XCTAssertEqual(dangling.sorted(), [], "citations of invariants SPEC.md does not define")
    }

    // MARK: - Reading the tree

    private func swiftFiles(under url: URL) throws -> [URL] {
        try filesUnder(url, matchingExtensions: ["swift"])
    }

    private func filesUnder(_ url: URL, matchingExtensions extensions: Set<String>) throws -> [URL] {
        guard let walk = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.isRegularFileKey]
        ) else { return [] }
        return walk.compactMap { $0 as? URL }.filter { extensions.contains($0.pathExtension) }
    }

    /// The numbers of the entries under `## Invariants — never regress`, up to
    /// the next heading. SPEC has other numbered lists and they are not this.
    private func specInvariantNumbers() throws -> [Int] {
        let spec = repositoryRoot.appendingPathComponent("docs/SPEC.md")
        let lines = try String(contentsOf: spec, encoding: .utf8).split(
            separator: "\n", omittingEmptySubsequences: false
        )
        guard let start = lines.firstIndex(where: { $0.hasPrefix("## Invariants") }) else {
            XCTFail("SPEC.md has no invariants heading"); return []
        }
        var numbers: [Int] = []
        for line in lines[lines.index(after: start)...] {
            if line.hasPrefix("## ") { break }
            // A top-level list item: digits, a full stop, a space, at column 0.
            guard let dot = line.firstIndex(of: "."), line.startIndex < dot,
                  line[line.startIndex...].hasPrefix(String(line[line.startIndex..<dot])),
                  let number = Int(line[line.startIndex..<dot]),
                  line.index(after: dot) < line.endIndex,
                  line[line.index(after: dot)] == " "
            else { continue }
            numbers.append(number)
        }
        return numbers
    }

    private func citedInvariantNumbers(in text: String) -> [Int] {
        let pattern = try! NSRegularExpression(pattern: "[Ii]nvariant ([0-9]+)")
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return pattern.matches(in: text, range: range).compactMap { match in
            Range(match.range(at: 1), in: text).flatMap { Int(text[$0]) }
        }
    }

    // MARK: - Invariant 19

    /// **Nothing on screen uses a word the app invented.**
    ///
    /// The interface had been swept for these once and the sweep was written up
    /// as finished. It was not: the photo library's filter still read
    /// *All domains · Local · Apple Cloud · Google Cloud*, registering a drive
    /// still promised to queue "all existing Local assets for replication", and
    /// "catalog" survived in four places. Every one of them was found by
    /// grepping, which is what a person does once and a test does for ever.
    ///
    /// Only literals a person can read are checked. Interpolations are cut out
    /// first — `\(target.name)` puts a drive's name on screen, not the word
    /// "target" — and so are strings with no space in them, which are symbol
    /// names and dictionary keys rather than prose.
    func testNoScreenUsesAWordTheAppInvented() throws {
        let invented = [
            "domain", "residency", "replica", "replication",
            "catalog", "marker", "target", "asset",
        ]
        let ui = repositoryRoot.appendingPathComponent("Sources/HeykinnClicks/UI", isDirectory: true)
        var offences: [String] = []

        for file in try swiftFiles(under: ui) {
            let text = try String(contentsOf: file, encoding: .utf8)
            for (offset, raw) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let line = raw.trimmingCharacters(in: .whitespaces)
                if line.hasPrefix("//") { continue }
                for literal in visibleStringLiterals(in: String(raw)) {
                    guard literal.contains(" ") else { continue }
                    let words = literal.lowercased().split { !$0.isLetter }
                    for word in invented
                    where words.contains(Substring(word)) || words.contains(Substring(word + "s")) {
                        offences.append("\(file.lastPathComponent):\(offset + 1) says \"\(word)\"")
                        break
                    }
                }
            }
        }
        XCTAssertEqual(
            offences.sorted(), [],
            """
            Invariant 19: a person who is not technical can use this without             learning our vocabulary. Say what the thing is to them — a drive,             a photo, a copy, what the app knows — not what it is called in here.
            """
        )
    }

    /// String literals with the `\(…)` interpolations removed, so what remains
    /// is only what somebody actually reads.
    ///
    /// An interpolation is skipped whole, parentheses balanced, which also
    /// steps over any quotes inside it — `\(names.joined(separator: " and "))`
    /// would otherwise look like the end of the string and the start of another.
    private func visibleStringLiterals(in line: String) -> [String] {
        let characters = Array(line)
        var literals: [String] = []
        var index = 0
        while index < characters.count {
            guard characters[index] == "\"" else { index += 1; continue }
            index += 1
            var visible = ""
            while index < characters.count, characters[index] != "\"" {
                guard characters[index] == "\\", index + 1 < characters.count else {
                    visible.append(characters[index]); index += 1; continue
                }
                guard characters[index + 1] == "(" else {
                    index += 2; visible.append(" "); continue
                }
                index += 2
                var depth = 1
                while index < characters.count, depth > 0 {
                    if characters[index] == "(" { depth += 1 }
                    if characters[index] == ")" { depth -= 1 }
                    index += 1
                }
                visible.append(" ")
            }
            index += 1
            literals.append(visible)
        }
        return literals
    }
}
