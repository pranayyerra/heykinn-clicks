#!/usr/bin/env swift
//
// Fetches a folder of photographs, for screenshots.
//
//     swift Packaging/make-demo-photos.swift /tmp/demo-photos 60
//
// The App Store listing cannot show the real archive. That one holds real drive
// names, real people's names read out of a Google export, and twenty-four
// thousand real photographs — none of which belongs in a permanent public
// listing, and all of which was scrubbed out of this repository for the same
// reason.
//
// So the screenshots are shot against borrowed content. Not mocked-up screens:
// the app really imports these, really copies them, really verifies them. Only
// the photographs are somebody else's, which is the one part a screenshot is
// allowed to stage.
//
// **Licence.** These come from Lorem Picsum, which serves photographs from
// Unsplash. The Unsplash Licence permits commercial use without attribution,
// which is what an App Store listing is. It does not permit redistributing the
// photographs as photographs — so these belong in a screenshot and not in this
// repository, which is why this fetches them rather than checking them in.
//
// Capture dates are written into each file, spread across two years. Without
// them every photograph lands in one month and the library screenshot shows a
// single heap rather than a timeline, which is the thing worth photographing.

import Foundation
import ImageIO
import UniformTypeIdentifiers

struct Failure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

let arguments = CommandLine.arguments
let directory = URL(
    fileURLWithPath: arguments.count > 1 ? arguments[1] : "/tmp/demo-photos",
    isDirectory: true
)
let count = arguments.count > 2 ? (Int(arguments[2]) ?? 60) : 60

try? FileManager.default.removeItem(at: directory)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

/// Fixed ids rather than random ones, so re-running produces the same set and a
/// screenshot can be retaken without the grid rearranging itself underneath.
/// Chosen from Picsum's landscape-heavy range; anything showing an identifiable
/// person is worth swapping out by hand before shipping a listing.
let ids: [Int] = [
    10, 11, 13, 15, 16, 17, 18, 19, 20, 22,
    24, 25, 27, 28, 29, 33, 37, 42, 43, 47,
    48, 49, 52, 54, 56, 58, 59, 63, 65, 66,
    68, 71, 74, 76, 79, 82, 83, 84, 87, 88,
    89, 90, 92, 94, 95, 96, 98, 100, 101, 103,
    104, 106, 107, 110, 111, 112, 113, 116, 117, 119,
]

let calendar = Calendar(identifier: .gregorian)
let end = calendar.date(from: DateComponents(year: 2026, month: 7, day: 20))!

let exifFormatter = DateFormatter()
exifFormatter.locale = Locale(identifier: "en_US_POSIX")
exifFormatter.dateFormat = "yyyy:MM:dd HH:mm:ss"

/// Deterministic spread, so the months come out the same on every run.
struct Rolling {
    var state: UInt64
    mutating func next() -> Double {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Double((state >> 33) % 100_000) / 100_000
    }
}
var random = Rolling(state: 20260810)

var written = 0
for index in 0..<min(count, ids.count) {
    // Landscape mostly, some portrait, as a real roll is.
    let portrait = index % 5 == 3
    let width = portrait ? 1_200 : 1_800
    let height = portrait ? 1_800 : 1_200

    let source = URL(string: "https://picsum.photos/id/\(ids[index])/\(width)/\(height)")!
    guard let data = try? Data(contentsOf: source),
          let imageSource = CGImageSourceCreateWithData(data as CFData, nil),
          let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil)
    else {
        FileHandle.standardError.write(Data("could not fetch id \(ids[index])\n".utf8))
        continue
    }

    let taken = calendar.date(byAdding: .day, value: -Int(random.next() * 700), to: end)!
    let name = String(format: "IMG_%04d.jpg", 1000 + index)
    let url = directory.appendingPathComponent(name)

    guard let destination = CGImageDestinationCreateWithURL(
        url as CFURL, UTType.jpeg.identifier as CFString, 1, nil
    ) else { continue }
    let properties: [CFString: Any] = [
        kCGImageDestinationLossyCompressionQuality: 0.82,
        kCGImagePropertyExifDictionary: [
            kCGImagePropertyExifDateTimeOriginal: exifFormatter.string(from: taken),
            kCGImagePropertyExifDateTimeDigitized: exifFormatter.string(from: taken),
        ],
        kCGImagePropertyTIFFDictionary: [
            kCGImagePropertyTIFFDateTime: exifFormatter.string(from: taken),
        ],
    ]
    CGImageDestinationAddImage(destination, image, properties as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { continue }

    try? FileManager.default.setAttributes(
        [.modificationDate: taken, .creationDate: taken], ofItemAtPath: url.path
    )
    written += 1
}

print("Wrote \(written) photographs to \(directory.path)")
print("Source: Lorem Picsum (Unsplash Licence) — fine in a screenshot, not for redistribution.")
