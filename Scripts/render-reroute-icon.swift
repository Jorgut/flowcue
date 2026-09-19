#!/usr/bin/env swift

import AppKit
import CoreGraphics
import Foundation

private let designSize: CGFloat = 1024
private let sRGBColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

private struct GlyphMetrics {
    let bodyWidth: CGFloat
    let headWidth: CGFloat
    let cursorWidth: CGFloat
    let cursorHeight: CGFloat
    let arrowColor: CGColor
}

private func color(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
    CGColor(
        colorSpace: sRGBColorSpace,
        components: [
            CGFloat((hex >> 16) & 0xFF) / 255,
            CGFloat((hex >> 8) & 0xFF) / 255,
            CGFloat(hex & 0xFF) / 255,
            alpha
        ]
    )!
}

private func makeContext(size: Int) throws -> CGContext {
    guard let context = CGContext(
        data: nil,
        width: size,
        height: size,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: sRGBColorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        throw NSError(domain: "RerouteIcon", code: 1)
    }
    context.setAllowsAntialiasing(true)
    context.setShouldAntialias(true)
    context.interpolationQuality = .high
    context.scaleBy(x: CGFloat(size) / designSize, y: CGFloat(size) / designSize)
    return context
}

private func pngData(from image: CGImage) throws -> Data {
    let representation = NSBitmapImageRep(cgImage: image)
    guard let data = representation.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "RerouteIcon", code: 2)
    }
    return data
}

private func drawLinearGradient(
    in context: CGContext,
    colors: [CGColor],
    locations: [CGFloat],
    start: CGPoint,
    end: CGPoint
) {
    guard let gradient = CGGradient(
        colorsSpace: sRGBColorSpace,
        colors: colors as CFArray,
        locations: locations
    ) else { return }
    context.drawLinearGradient(gradient, start: start, end: end, options: [])
}

private func drawRadialGlow(
    in context: CGContext,
    center: CGPoint,
    radius: CGFloat,
    glowColor: CGColor
) {
    guard let gradient = CGGradient(
        colorsSpace: sRGBColorSpace,
        colors: [glowColor, color(0x000000, alpha: 0)] as CFArray,
        locations: [0, 1]
    ) else { return }
    context.drawRadialGradient(
        gradient,
        startCenter: center,
        startRadius: 0,
        endCenter: center,
        endRadius: radius,
        options: []
    )
}

/// The macOS icon keyline used by Apple's current system apps: an 824-point
/// fifth-order superellipse centered in the 1024-point canvas.
private func appIconPath() -> CGPath {
    let center = CGPoint(x: designSize / 2, y: designSize / 2)
    let radius: CGFloat = 412
    let exponent: CGFloat = 5
    let segmentCount = 512
    let path = CGMutablePath()

    for index in 0...segmentCount {
        let angle = CGFloat(index) / CGFloat(segmentCount) * .pi * 2
        let cosine = cos(angle)
        let sine = sin(angle)
        let x = center.x
            + radius * (cosine >= 0 ? 1 : -1) * pow(abs(cosine), 2 / exponent)
        let y = center.y
            + radius * (sine >= 0 ? 1 : -1) * pow(abs(sine), 2 / exponent)
        let point = CGPoint(x: x, y: y)
        if index == 0 {
            path.move(to: point)
        } else {
            path.addLine(to: point)
        }
    }
    path.closeSubpath()
    return path
}

private func drawTile(in context: CGContext, size: Int) {
    let path = appIconPath()
    let isLarge = size >= 256
    let isMedium = size >= 128
    let outputScale = CGFloat(size) / designSize

    context.saveGState()
    context.setShadow(
        offset: CGSize(width: 0, height: (size >= 64 ? -8 : -4) * outputScale),
        blur: (size >= 64 ? 36 : 24) * outputScale,
        color: color(0x000000, alpha: size >= 64 ? 0.26 : 0.16)
    )
    context.addPath(path)
    context.setFillColor(color(0x18181D))
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(path)
    context.clip()
    if isLarge {
        drawLinearGradient(
            in: context,
            colors: [color(0x2D2C34), color(0x19191F), color(0x101014)],
            locations: [0, 0.52, 1],
            start: CGPoint(x: 190, y: 910),
            end: CGPoint(x: 850, y: 110)
        )
        drawRadialGlow(
            in: context,
            center: CGPoint(x: 504, y: 458),
            radius: 330,
            glowColor: color(0x636CFF, alpha: 0.10)
        )
    } else {
        drawLinearGradient(
            in: context,
            colors: isMedium
                ? [color(0x292831), color(0x141419)]
                : [color(0x24232A), color(0x141419)],
            locations: [0, 1],
            start: CGPoint(x: 210, y: 900),
            end: CGPoint(x: 820, y: 120)
        )
    }
    context.restoreGState()

    if isLarge {
        context.saveGState()
        context.addPath(path)
        context.clip()
        context.addPath(path)
        context.setStrokeColor(color(0xFFFFFF, alpha: 0.11))
        context.setLineWidth(4)
        context.strokePath()
        context.restoreGState()
    }
}

private func glyphMetrics(for size: Int) -> GlyphMetrics {
    switch size {
    case ...16:
        return GlyphMetrics(
            bodyWidth: 112,
            headWidth: 96,
            cursorWidth: 128,
            cursorHeight: 192,
            arrowColor: color(0x8A90FF)
        )
    case ...32:
        return GlyphMetrics(
            bodyWidth: 104,
            headWidth: 80,
            cursorWidth: 96,
            cursorHeight: 192,
            arrowColor: color(0x8A90FF)
        )
    case ...64:
        return GlyphMetrics(
            bodyWidth: 100,
            headWidth: 78,
            cursorWidth: 100,
            cursorHeight: 190,
            arrowColor: color(0x8A90FF)
        )
    default:
        return GlyphMetrics(
            bodyWidth: 98,
            headWidth: 76,
            cursorWidth: 98,
            cursorHeight: 190,
            arrowColor: color(0x7E84FF)
        )
    }
}

private func drawReturnGlyph(in context: CGContext, size: Int) {
    let metrics = glyphMetrics(for: size)
    context.setLineCap(.round)
    context.setLineJoin(.round)

    let body = CGMutablePath()
    body.move(to: CGPoint(x: 672, y: 462))
    body.addLine(to: CGPoint(x: 672, y: 430))
    body.addCurve(
        to: CGPoint(x: 586, y: 344),
        control1: CGPoint(x: 672, y: 380),
        control2: CGPoint(x: 636, y: 344)
    )
    body.addLine(to: CGPoint(x: 362, y: 344))
    context.addPath(body)
    context.setStrokeColor(metrics.arrowColor)
    context.setLineWidth(metrics.bodyWidth)
    context.strokePath()

    let arrowHead = CGMutablePath()
    arrowHead.move(to: CGPoint(x: 418, y: 420))
    arrowHead.addLine(to: CGPoint(x: 338, y: 344))
    arrowHead.addLine(to: CGPoint(x: 418, y: 268))
    context.addPath(arrowHead)
    context.setStrokeColor(metrics.arrowColor)
    context.setLineWidth(metrics.headWidth)
    context.strokePath()

    let cursorRect = CGRect(
        x: 672 - metrics.cursorWidth / 2,
        y: 588,
        width: metrics.cursorWidth,
        height: metrics.cursorHeight
    )
    context.addPath(
        CGPath(
            roundedRect: cursorRect,
            cornerWidth: metrics.cursorWidth / 2,
            cornerHeight: metrics.cursorWidth / 2,
            transform: nil
        )
    )
    context.setFillColor(color(0xF7F7FA))
    context.fillPath()
}

private func drawAppIcon(size: Int) throws -> Data {
    let context = try makeContext(size: size)
    drawTile(in: context, size: size)
    drawReturnGlyph(in: context, size: size)

    guard let image = context.makeImage() else {
        throw NSError(domain: "RerouteIcon", code: 3)
    }
    return try pngData(from: image)
}

private func drawMenuIcon(size: Int) throws -> Data {
    guard let context = CGContext(
        data: nil,
        width: size,
        height: size,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: sRGBColorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        throw NSError(domain: "RerouteIcon", code: 4)
    }
    context.setAllowsAntialiasing(true)
    context.setShouldAntialias(true)
    context.scaleBy(x: CGFloat(size) / 18, y: CGFloat(size) / 18)
    context.setStrokeColor(color(0x000000))
    context.setFillColor(color(0x000000))
    context.setLineCap(.round)
    context.setLineJoin(.round)

    let body = CGMutablePath()
    body.move(to: CGPoint(x: 13.80, y: 8.02))
    body.addLine(to: CGPoint(x: 13.80, y: 7.28))
    body.addCurve(
        to: CGPoint(x: 11.79, y: 5.26),
        control1: CGPoint(x: 13.80, y: 6.10),
        control2: CGPoint(x: 12.96, y: 5.26)
    )
    body.addLine(to: CGPoint(x: 4.69, y: 5.26))
    context.addPath(body)
    context.setLineWidth(2.30)
    context.strokePath()

    let arrowHead = CGMutablePath()
    arrowHead.move(to: CGPoint(x: 6.00, y: 7.04))
    arrowHead.addLine(to: CGPoint(x: 4.13, y: 5.26))
    arrowHead.addLine(to: CGPoint(x: 6.00, y: 3.49))
    context.addPath(arrowHead)
    context.setLineWidth(1.78)
    context.strokePath()

    let cursorRect = CGRect(x: 12.65, y: 10.95, width: 2.30, height: 4.45)
    context.addPath(
        CGPath(
            roundedRect: cursorRect,
            cornerWidth: 1.15,
            cornerHeight: 1.15,
            transform: nil
        )
    )
    context.fillPath()

    guard let image = context.makeImage() else {
        throw NSError(domain: "RerouteIcon", code: 5)
    }
    return try pngData(from: image)
}

@discardableResult
private func runProcess(_ executableURL: URL, arguments: [String]) throws -> String {
    let diagnostics = Pipe()
    let process = Process()
    process.executableURL = executableURL
    process.arguments = arguments
    process.standardOutput = diagnostics
    process.standardError = diagnostics

    try process.run()
    let data = diagnostics.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()

    let output = String(decoding: data, as: UTF8.self)
    guard process.terminationStatus == 0 else {
        throw NSError(
            domain: "RerouteIcon",
            code: Int(process.terminationStatus),
            userInfo: [
                NSLocalizedDescriptionKey: output.isEmpty
                    ? "\(executableURL.lastPathComponent) failed"
                    : output
            ]
        )
    }
    return output
}

private func activeDeveloperDirectory() throws -> URL {
    if let override = ProcessInfo.processInfo.environment["DEVELOPER_DIR"],
       !override.isEmpty {
        return URL(fileURLWithPath: override, isDirectory: true)
    }

    let output = try runProcess(
        URL(fileURLWithPath: "/usr/bin/xcode-select"),
        arguments: ["-p"]
    )
    let path = output.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !path.isEmpty else {
        throw NSError(
            domain: "RerouteIcon",
            code: 6,
            userInfo: [NSLocalizedDescriptionKey: "xcode-select returned an empty developer path"]
        )
    }
    return URL(fileURLWithPath: path, isDirectory: true)
}

private func compileICNS(
    iconsetDirectory: URL,
    supportDirectory: URL,
    iconFiles: [(pixels: Int, name: String)]
) throws {
    let fileManager = FileManager.default
    let temporaryDirectory = fileManager.temporaryDirectory
        .appendingPathComponent("RerouteIcon-\(UUID().uuidString)", isDirectory: true)
    defer { try? fileManager.removeItem(at: temporaryDirectory) }

    let assetCatalogDirectory = temporaryDirectory
        .appendingPathComponent("RerouteAssets.xcassets", isDirectory: true)
    let appIconDirectory = assetCatalogDirectory
        .appendingPathComponent("Reroute.appiconset", isDirectory: true)
    let compiledDirectory = temporaryDirectory
        .appendingPathComponent("Compiled", isDirectory: true)
    let partialInfoURL = temporaryDirectory.appendingPathComponent("IconInfo.plist")
    try fileManager.createDirectory(at: appIconDirectory, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: compiledDirectory, withIntermediateDirectories: true)

    let contents = """
    {
      "images" : [
        { "filename" : "icon_16x16.png", "idiom" : "mac", "scale" : "1x", "size" : "16x16" },
        { "filename" : "icon_16x16@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "16x16" },
        { "filename" : "icon_32x32.png", "idiom" : "mac", "scale" : "1x", "size" : "32x32" },
        { "filename" : "icon_32x32@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "32x32" },
        { "filename" : "icon_128x128.png", "idiom" : "mac", "scale" : "1x", "size" : "128x128" },
        { "filename" : "icon_128x128@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "128x128" },
        { "filename" : "icon_256x256.png", "idiom" : "mac", "scale" : "1x", "size" : "256x256" },
        { "filename" : "icon_256x256@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "256x256" },
        { "filename" : "icon_512x512.png", "idiom" : "mac", "scale" : "1x", "size" : "512x512" },
        { "filename" : "icon_512x512@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "512x512" }
      ],
      "info" : { "author" : "xcode", "version" : 1 }
    }
    """
    try Data(contents.utf8).write(
        to: appIconDirectory.appendingPathComponent("Contents.json"),
        options: .atomic
    )

    for item in iconFiles {
        try fileManager.copyItem(
            at: iconsetDirectory.appendingPathComponent(item.name),
            to: appIconDirectory.appendingPathComponent(item.name)
        )
    }

    let developerDirectory = try activeDeveloperDirectory()
    let actoolURL = developerDirectory.appendingPathComponent("usr/bin/actool")
    guard fileManager.isExecutableFile(atPath: actoolURL.path) else {
        throw NSError(
            domain: "RerouteIcon",
            code: 7,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "Apple actool was not found at \(actoolURL.path). Install full Xcode to build Reroute icons."
            ]
        )
    }

    try runProcess(
        actoolURL,
        arguments: [
            assetCatalogDirectory.path,
            "--compile", compiledDirectory.path,
            "--platform", "macosx",
            "--minimum-deployment-target", "14.0",
            "--app-icon", "Reroute",
            "--standalone-icon-behavior", "all",
            "--output-partial-info-plist", partialInfoURL.path,
            "--warnings",
            "--errors",
            "--notices",
            "--output-format", "human-readable-text"
        ]
    )

    let compiledIconURL = compiledDirectory.appendingPathComponent("Reroute.icns")
    guard fileManager.fileExists(atPath: compiledIconURL.path) else {
        throw NSError(
            domain: "RerouteIcon",
            code: 8,
            userInfo: [NSLocalizedDescriptionKey: "actool did not produce Reroute.icns"]
        )
    }
    try Data(contentsOf: compiledIconURL).write(
        to: supportDirectory.appendingPathComponent("Reroute.icns"),
        options: .atomic
    )
}

let scriptURL = URL(fileURLWithPath: #filePath).standardizedFileURL
let projectDirectory = scriptURL
    .deletingLastPathComponent()
    .deletingLastPathComponent()
let supportDirectory = projectDirectory.appendingPathComponent("Support", isDirectory: true)
let iconsetDirectory = supportDirectory.appendingPathComponent("Reroute.iconset", isDirectory: true)
try FileManager.default.createDirectory(at: iconsetDirectory, withIntermediateDirectories: true)

let iconFiles: [(pixels: Int, name: String)] = [
    (16, "icon_16x16.png"),
    (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"),
    (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"),
    (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"),
    (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"),
    (1024, "icon_512x512@2x.png")
]

var renderedBySize: [Int: Data] = [:]
for item in iconFiles {
    let data: Data
    if let cached = renderedBySize[item.pixels] {
        data = cached
    } else {
        data = try drawAppIcon(size: item.pixels)
        renderedBySize[item.pixels] = data
    }
    try data.write(to: iconsetDirectory.appendingPathComponent(item.name), options: .atomic)
}

try compileICNS(
    iconsetDirectory: iconsetDirectory,
    supportDirectory: supportDirectory,
    iconFiles: iconFiles
)

try renderedBySize[1024]?.write(
    to: supportDirectory.appendingPathComponent("RerouteIcon-1024.png"),
    options: .atomic
)
try drawMenuIcon(size: 18).write(
    to: supportDirectory.appendingPathComponent("RerouteMenuTemplate.png"),
    options: .atomic
)
try drawMenuIcon(size: 36).write(
    to: supportDirectory.appendingPathComponent("RerouteMenuTemplate@2x.png"),
    options: .atomic
)

print(iconsetDirectory.path)
