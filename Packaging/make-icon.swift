#!/usr/bin/env swift
//
// Draws Packaging/AppIcon.icns from the Hey Kinn brand mark.
//
//     swift Packaging/make-icon.swift
//
// A generator rather than a checked-in binary, so the icon can be argued with:
// every measurement below is a number somebody can change and re-run. The
// source of truth is `Packaging/BrandMark.png` — the black lock-up, vendored
// here so this does not depend on a folder in Downloads that may not exist on
// the next machine.
//
// The otter is lifted out of the lock-up and set in white on the brand
// gradient, which is how `Fav-Icon.png` already treats it. The wordmark is
// deliberately dropped: "Hey Kinn" is illegible at 32 points and a smear at 16,
// and an app icon has the app's name written under it already.
//
// One honest limitation: the mark exists only as raster, at 228×275 inside an
// 800×800 lock-up, so the largest icon upscales it about 2.2×. It holds up
// because the shape is smooth and flat, but a vector source would be sharper at
// 512 and 1024 — worth asking the designer for.

import AppKit
import ImageIO
import UniformTypeIdentifiers

struct Failure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

let packaging = URL(fileURLWithPath: CommandLine.arguments.first.map {
    URL(fileURLWithPath: $0).deletingLastPathComponent().path
} ?? ".", isDirectory: true)

// MARK: - Brand
//
// Sampled from `Fav-Icon.png` rather than guessed: left edge and right edge of
// the badge, which is a flat horizontal ramp between these two.

let gradientLeft = CGColor(red: 0x57 / 255, green: 0x42 / 255, blue: 0xD9 / 255, alpha: 1)
let gradientRight = CGColor(red: 0xE0 / 255, green: 0x00 / 255, blue: 0x80 / 255, alpha: 1)

/// Where the otter sits inside `BrandMark.png`, measured rather than eyeballed:
/// the bounding box of its dark pixels once the wordmark band is excluded.
/// Origin is top-left, matching how the bitmap is read below.
let markBounds = CGRect(x: 286, y: 190, width: 228, height: 275)

// MARK: - Lifting the mark out of the lock-up

/// The otter as a white image with alpha taken from the lock-up's ink.
///
/// The lock-up is black on white with no transparency, so "how much otter is
/// here" is just how dark the pixel is. Anti-aliased edges come through as
/// partial alpha, which is what keeps the curves smooth when this is scaled up.
func whiteMark() throws -> CGImage {
    let url = packaging.appendingPathComponent("BrandMark.png")
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else { throw Failure("could not read \(url.lastPathComponent)") }

    // Buffers are allocated rather than passed as `&array`. A CGContext keeps
    // the pointer it is given for its whole life, and Swift only guarantees an
    // inout-to-pointer conversion for the duration of the call — so the drawn
    // pixels were being read back out of a buffer that had already gone. It
    // failed quietly, as the wrong picture rather than a crash.
    let width = image.width, height = image.height
    let sourceCount = width * height * 4
    let pixels = UnsafeMutablePointer<UInt8>.allocate(capacity: sourceCount)
    pixels.initialize(repeating: 0, count: sourceCount)
    defer { pixels.deallocate() }

    guard let reader = CGContext(
        data: pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { throw Failure("could not read the mark's pixels") }
    reader.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

    let cropX = Int(markBounds.minX), cropY = Int(markBounds.minY)
    let cropW = Int(markBounds.width), cropH = Int(markBounds.height)
    let cutCount = cropW * cropH * 4
    let cut = UnsafeMutablePointer<UInt8>.allocate(capacity: cutCount)
    cut.initialize(repeating: 0, count: cutCount)
    defer { cut.deallocate() }

    for y in 0..<cropH {
        for x in 0..<cropW {
            let from = ((cropY + y) * width + (cropX + x)) * 4
            let to = (y * cropW + x) * 4
            // How much ink is on this pixel, whatever the file's background.
            //
            // `255 - luminance` was wrong: the lock-up's background is
            // *transparent*, not white, so every empty pixel read as black and
            // the whole crop came out a solid white rectangle. With
            // premultiplied samples, ink coverage is the alpha the pixel has
            // minus the light it carries — black-on-transparent gives 255,
            // empty gives 0, and white paper would give 0 too, so this holds
            // whichever way the mark is exported next time.
            let luminance = (Int(pixels[from]) + Int(pixels[from + 1]) + Int(pixels[from + 2])) / 3
            let alpha = UInt8(max(0, min(255, Int(pixels[from + 3]) - luminance)))
            // Premultiplied, so white at partial alpha is written as alpha.
            cut[to] = alpha; cut[to + 1] = alpha; cut[to + 2] = alpha; cut[to + 3] = alpha
        }
    }

    guard let writer = CGContext(
        data: cut, width: cropW, height: cropH, bitsPerComponent: 8, bytesPerRow: cropW * 4,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ), let result = writer.makeImage() else { throw Failure("could not build the mark") }
    // `makeImage` copies, so the buffers can go.
    return result
}

// MARK: - Drawing

let mark = try whiteMark()

func draw(into context: CGContext, side: CGFloat) {
    let unit = side / 1024
    context.setShouldAntialias(true)
    context.interpolationQuality = .high

    // macOS leaves a margin inside the canvas — an icon drawn edge to edge sits
    // visibly larger than its neighbours in the Dock.
    let margin = 100 * unit
    let plate = CGRect(x: margin, y: margin, width: side - margin * 2, height: side - margin * 2)
    // Continuous-curvature corner: what makes an icon look like it belongs on
    // this OS rather than like a rounded rectangle.
    let radius = plate.width * 0.235

    context.saveGState()
    context.addPath(CGPath(roundedRect: plate, cornerWidth: radius, cornerHeight: radius, transform: nil))
    context.clip()
    if let gradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [gradientLeft, gradientRight] as CFArray,
        locations: [0, 1]
    ) {
        // Horizontal, because the badge it is taken from is: both corners on
        // the left sample blue and both on the right sample magenta.
        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: plate.minX, y: plate.midY),
            end: CGPoint(x: plate.maxX, y: plate.midY),
            options: []
        )
    }
    context.restoreGState()

    // The otter, centred and sized against the plate's height. 0.72 is close to
    // how much of the badge it fills in `Fav-Icon.png`; at 0.60 it read as a
    // sticker on a coloured square, and at 16 points the whole animal
    // dissolved. Much beyond this and the tail meets the corner radius.
    let markHeight = plate.height * 0.72
    let markWidth = markHeight * (markBounds.width / markBounds.height)
    let target = CGRect(
        x: plate.midX - markWidth / 2,
        // Nudged up a hair: the tail's mass sits low, so geometric centring
        // reads as bottom-heavy.
        y: plate.midY - markHeight / 2 + plate.height * 0.015,
        width: markWidth,
        height: markHeight
    )
    context.draw(mark, in: target)
}

func render(side: Int) throws -> CGImage {
    guard let context = CGContext(
        data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { throw Failure("could not make a \(side)px canvas") }
    draw(into: context, side: CGFloat(side))
    guard let image = context.makeImage() else { throw Failure("could not render \(side)px") }
    return image
}

func write(_ image: CGImage, to url: URL) throws {
    guard let destination = CGImageDestinationCreateWithURL(
        url as CFURL, UTType.png.identifier as CFString, 1, nil
    ) else { throw Failure("could not create \(url.lastPathComponent)") }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw Failure("could not write \(url.lastPathComponent)")
    }
}

let iconset = packaging.appendingPathComponent("AppIcon.iconset", isDirectory: true)
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

// The set macOS asks for. Each @2x is the next size up drawn afresh rather than
// a scaled copy, so the small ones stay crisp.
let variants: [(name: String, side: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for variant in variants {
    try write(try render(side: variant.side), to: iconset.appendingPathComponent("\(variant.name).png"))
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = [
    "-c", "icns", iconset.path,
    "-o", packaging.appendingPathComponent("AppIcon.icns").path,
]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { throw Failure("iconutil failed") }

// The .iconset is scratch; the .icns is the artefact.
try? FileManager.default.removeItem(at: iconset)
print("Wrote \(packaging.appendingPathComponent("AppIcon.icns").path)")
