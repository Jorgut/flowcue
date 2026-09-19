import CoreGraphics
import Foundation
import ImageIO
import XCTest

final class IconAssetTests: XCTestCase {
    private struct Raster {
        let width: Int
        let height: Int
        let pixels: Data
    }

    private var projectDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func raster(at url: URL) throws -> Raster {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw NSError(
                domain: "IconAssetTests",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Could not decode \(url.path)"]
            )
        }

        let bytesPerRow = image.width * 4
        var pixels = Data(count: bytesPerRow * image.height)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let rendered = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(
                data: bytes.baseAddress,
                width: image.width,
                height: image.height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(
                image,
                in: CGRect(x: 0, y: 0, width: image.width, height: image.height)
            )
            return true
        }
        guard rendered else {
            throw NSError(
                domain: "IconAssetTests",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Could not rasterize \(url.path)"]
            )
        }
        return Raster(width: image.width, height: image.height, pixels: pixels)
    }

    private func runIconutil(input: URL, output: URL) throws {
        let diagnostics = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
        process.arguments = [
            "--convert", "iconset",
            "--output", output.path,
            input.path,
        ]
        process.standardOutput = diagnostics
        process.standardError = diagnostics

        try process.run()
        let data = diagnostics.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let outputText = String(decoding: data, as: UTF8.self)
        XCTAssertEqual(process.terminationStatus, 0, outputText)
    }

    private func assertVisuallyEquivalent(
        _ actual: Raster,
        _ expected: Raster,
        name: String
    ) {
        XCTAssertEqual(actual.width, expected.width, name)
        XCTAssertEqual(actual.height, expected.height, name)
        XCTAssertEqual(actual.pixels.count, expected.pixels.count, name)

        var colorDifference = 0
        var colorSampleCount = 0
        actual.pixels.withUnsafeBytes { actualRawBytes in
            expected.pixels.withUnsafeBytes { expectedRawBytes in
                let actualBytes = actualRawBytes.bindMemory(to: UInt8.self)
                let expectedBytes = expectedRawBytes.bindMemory(to: UInt8.self)
                for offset in stride(from: 0, to: actualBytes.count, by: 4) {
                    XCTAssertEqual(actualBytes[offset + 3], expectedBytes[offset + 3], name)
                    for channel in 0..<3 {
                        colorDifference += abs(
                            Int(actualBytes[offset + channel])
                                - Int(expectedBytes[offset + channel])
                        )
                        colorSampleCount += 1
                    }
                }
            }
        }

        let meanColorDifference = Double(colorDifference) / Double(colorSampleCount)
        XCTAssertLessThan(meanColorDifference, 12, name)
    }

    func testGeneratedAppIconRoundTripsThroughIconutil() throws {
        let supportDirectory = projectDirectory.appendingPathComponent("Support")
        let sourceDirectory = supportDirectory.appendingPathComponent("Reroute.iconset")
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RerouteIconTests-\(UUID().uuidString)")
        let extractedDirectory = temporaryDirectory.appendingPathComponent("Reroute.iconset")
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        try runIconutil(
            input: supportDirectory.appendingPathComponent("Reroute.icns"),
            output: extractedDirectory
        )

        let expectedDimensions: [String: Int] = [
            "icon_16x16.png": 16,
            "icon_16x16@2x.png": 32,
            "icon_32x32.png": 32,
            "icon_32x32@2x.png": 64,
            "icon_128x128.png": 128,
            "icon_128x128@2x.png": 256,
            "icon_256x256.png": 256,
            "icon_256x256@2x.png": 512,
            "icon_512x512.png": 512,
            "icon_512x512@2x.png": 1024,
        ]

        for (name, dimension) in expectedDimensions {
            let source = try raster(at: sourceDirectory.appendingPathComponent(name))
            let extracted = try raster(at: extractedDirectory.appendingPathComponent(name))
            XCTAssertEqual(source.width, dimension, name)
            XCTAssertEqual(source.height, dimension, name)
            XCTAssertEqual(extracted.width, dimension, name)
            XCTAssertEqual(extracted.height, dimension, name)
            assertVisuallyEquivalent(extracted, source, name: name)
        }
    }

    func testMenuBarTemplatesAreMonochromeAtBothScales() throws {
        let supportDirectory = projectDirectory.appendingPathComponent("Support")
        let templates = [
            ("RerouteMenuTemplate.png", 18),
            ("RerouteMenuTemplate@2x.png", 36),
        ]

        for (name, dimension) in templates {
            let image = try raster(at: supportDirectory.appendingPathComponent(name))
            XCTAssertEqual(image.width, dimension, name)
            XCTAssertEqual(image.height, dimension, name)

            var hasVisiblePixel = false
            image.pixels.withUnsafeBytes { rawBytes in
                let bytes = rawBytes.bindMemory(to: UInt8.self)
                for offset in stride(from: 0, to: bytes.count, by: 4) {
                    guard bytes[offset + 3] > 0 else { continue }
                    hasVisiblePixel = true
                    XCTAssertEqual(bytes[offset], 0, name)
                    XCTAssertEqual(bytes[offset + 1], 0, name)
                    XCTAssertEqual(bytes[offset + 2], 0, name)
                }
            }
            XCTAssertTrue(hasVisiblePixel, name)
        }
    }
}
