#!/usr/bin/env swift
//
// Creates privacy-safe media for App Review recordings and screenshots.
//
//     swift Packaging/make-review-fixtures.swift /tmp/Heykinn-Review-Fixtures
//
// Every pixel and every metadata value is generated locally. Nothing is
// downloaded, no real library is read, and no third-party photograph or name
// appears in the result. The output contains an ordinary photo folder and a
// small extracted Google Takeout-shaped tree so both import routes can be
// demonstrated with the same disposable fixture.

import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum FixtureError: Error {
    case context
    case image
    case destination(URL)
}

let arguments = CommandLine.arguments
let root = URL(
    fileURLWithPath: arguments.count > 1
        ? arguments[1]
        : "/tmp/Heykinn-Review-Fixtures",
    isDirectory: true
)
let photoFolder = root.appendingPathComponent("Photo Folder", isDirectory: true)
let takeoutFolder = root
    .appendingPathComponent("Google Takeout", isDirectory: true)
    .appendingPathComponent("takeout-20260814T000000Z-001", isDirectory: true)
    .appendingPathComponent("Takeout/Google Photos/Photos from 2024", isDirectory: true)

try? FileManager.default.removeItem(at: root)
try FileManager.default.createDirectory(at: photoFolder, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: takeoutFolder, withIntermediateDirectories: true)

let calendar = Calendar(identifier: .gregorian)
let baseDate = calendar.date(from: DateComponents(year: 2024, month: 1, day: 12, hour: 10))!
let exif = DateFormatter()
exif.locale = Locale(identifier: "en_US_POSIX")
exif.dateFormat = "yyyy:MM:dd HH:mm:ss"

func component(_ seed: Int, _ offset: Int) -> CGFloat {
    let multiplier = 47 + offset * 18
    let value = (seed * multiplier + offset * 71) % 220 + 24
    return CGFloat(value) / CGFloat(255)
}

func writeImage(to url: URL, index: Int, date: Date, label: String) throws {
    let width = 1_600
    let height = 1_000
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { throw FixtureError.context }

    let first = CGColor(
        colorSpace: colorSpace,
        components: [component(index, 0), component(index, 1), component(index, 2), 1]
    )!
    let second = CGColor(
        colorSpace: colorSpace,
        components: [component(index + 5, 2), component(index + 9, 0), component(index + 3, 1), 1]
    )!
    let gradient = CGGradient(
        colorsSpace: colorSpace,
        colors: [first, second] as CFArray,
        locations: [0, 1]
    )!
    context.drawLinearGradient(
        gradient,
        start: CGPoint(x: 0, y: 0),
        end: CGPoint(x: width, y: height),
        options: []
    )

    // Deterministic abstract shapes make the thumbnails visibly distinct
    // without depicting any person, place, trademark, or protected artwork.
    for shape in 0..<6 {
        let x = CGFloat((index * 137 + shape * 241) % width)
        let y = CGFloat((index * 89 + shape * 173) % height)
        let size = CGFloat(170 + ((index + shape * 3) % 6) * 55)
        context.setFillColor(CGColor(gray: 1, alpha: 0.08 + CGFloat(shape) * 0.025))
        if shape.isMultiple(of: 2) {
            context.fillEllipse(in: CGRect(x: x - size / 2, y: y - size / 2, width: size, height: size))
        } else {
            context.saveGState()
            context.translateBy(x: x, y: y)
            context.rotate(by: CGFloat(shape) * 0.19)
            context.fill(CGRect(x: -size / 2, y: -size / 2, width: size, height: size))
            context.restoreGState()
        }
    }

    let attributes: [CFString: Any] = [
        kCTFontAttributeName: CTFontCreateWithName("Helvetica Neue Bold" as CFString, 56, nil),
        kCTForegroundColorAttributeName: CGColor(gray: 1, alpha: 0.92),
    ]
    let line = CTLineCreateWithAttributedString(
        CFAttributedStringCreate(nil, label as CFString, attributes as CFDictionary)
    )
    context.textPosition = CGPoint(x: 70, y: 70)
    CTLineDraw(line, context)

    guard let image = context.makeImage() else { throw FixtureError.image }
    guard let destination = CGImageDestinationCreateWithURL(
        url as CFURL,
        UTType.jpeg.identifier as CFString,
        1,
        nil
    ) else { throw FixtureError.destination(url) }
    let timestamp = exif.string(from: date)
    let properties: [CFString: Any] = [
        kCGImageDestinationLossyCompressionQuality: 0.86,
        kCGImagePropertyExifDictionary: [
            kCGImagePropertyExifDateTimeOriginal: timestamp,
            kCGImagePropertyExifDateTimeDigitized: timestamp,
        ],
        kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFDateTime: timestamp],
    ]
    CGImageDestinationAddImage(destination, image, properties as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { throw FixtureError.destination(url) }
    try FileManager.default.setAttributes(
        [.creationDate: date, .modificationDate: date],
        ofItemAtPath: url.path
    )
}

for index in 1...12 {
    let date = calendar.date(byAdding: .day, value: index * 37, to: baseDate)!
    let name = String(format: "REVIEW_%02d.jpg", index)
    try writeImage(
        to: photoFolder.appendingPathComponent(name),
        index: index,
        date: date,
        label: String(format: "Review Sample %02d", index)
    )
}

for index in 1...4 {
    let date = calendar.date(byAdding: .day, value: index * 61, to: baseDate)!
    let name = String(format: "TAKEOUT_%02d.jpg", index)
    let mediaURL = takeoutFolder.appendingPathComponent(name)
    try writeImage(
        to: mediaURL,
        index: index + 20,
        date: date,
        label: String(format: "Takeout Sample %02d", index)
    )
    let sidecar: [String: Any] = [
        "title": name,
        "description": "Synthetic App Review fixture \(index)",
        "photoTakenTime": [
            "timestamp": String(Int(date.timeIntervalSince1970)),
            "formatted": ISO8601DateFormatter().string(from: date),
        ],
    ]
    let data = try JSONSerialization.data(withJSONObject: sidecar, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: takeoutFolder.appendingPathComponent(name + ".json"))
}

let readme = """
Heykinn Clicks App Review fixtures

All images and metadata in this directory were generated locally by
Packaging/make-review-fixtures.swift. They contain no personal data,
third-party photographs, location data, accounts, or credentials.

- Photo Folder: choose with Add photos > Choose a folder.
- Google Takeout: choose the Google Takeout directory with Find a download.
"""
try Data(readme.utf8).write(to: root.appendingPathComponent("README.txt"))

print("Created privacy-safe review fixtures at \(root.path)")
print("  ordinary folder: \(photoFolder.path) (12 images)")
print("  Google Takeout:  \(root.appendingPathComponent("Google Takeout").path) (4 images + sidecars)")
