#!/usr/bin/env swift

// Generates macOS app icon sizes from a source PNG (preferred) or falls back
// to a procedural knob if the source is missing.
//
// Usage:
//   swift scripts/generate-icon.swift [outputDir] [sourcePNG]
//
// Default source: Assets.xcassets/AppIcon.appiconset/icon_1024.png
//                 or ../../attachments/OG LOK.png when building from a clean tree.

import AppKit
import Foundation

let projectRoot = URL(fileURLWithPath: CommandLine.arguments[0])
    .deletingLastPathComponent() // scripts/
    .deletingLastPathComponent() // project root

let outputDir: String = {
    if CommandLine.arguments.count > 1 { return CommandLine.arguments[1] }
    return projectRoot
        .appendingPathComponent("Assets.xcassets/AppIcon.appiconset")
        .path
}()

let sourceCandidates: [String] = {
    var list: [String] = []
    if CommandLine.arguments.count > 2 {
        list.append(CommandLine.arguments[2])
    }
    list.append(contentsOf: [
        (outputDir as NSString).appendingPathComponent("icon_1024.png"),
        projectRoot.appendingPathComponent("Assets.xcassets/AppIcon.appiconset/icon_1024.png").path,
        projectRoot.appendingPathComponent("Resources/AppIcon-source.png").path,
    ])
    return list
}()

let sizes: [(name: String, pixels: Int)] = [
    ("icon_16", 16),
    ("icon_16@2x", 32),
    ("icon_32", 32),
    ("icon_32@2x", 64),
    ("icon_128", 128),
    ("icon_128@2x", 256),
    ("icon_256", 256),
    ("icon_256@2x", 512),
    ("icon_512", 512),
    ("icon_512@2x", 1024),
]

func loadSource() -> NSImage? {
    for path in sourceCandidates {
        if FileManager.default.fileExists(atPath: path),
           let img = NSImage(contentsOfFile: path),
           img.size.width > 0 {
            print("Using source: \(path)")
            return img
        }
    }
    return nil
}

func writePNG(_ image: NSImage, to path: String, pixels: Int) {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels,
        pixelsHigh: pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!
    rep.size = NSSize(width: pixels, height: pixels)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(
        in: NSRect(x: 0, y: 0, width: pixels, height: pixels),
        from: .zero,
        operation: .copy,
        fraction: 1.0
    )
    NSGraphicsContext.restoreGraphicsState()

    let data = rep.representation(using: .png, properties: [:])!
    try! data.write(to: URL(fileURLWithPath: path))
    print("  wrote \(URL(fileURLWithPath: path).lastPathComponent) (\(pixels)x\(pixels))")
}

try? FileManager.default.createDirectory(atPath: outputDir, withIntermediateDirectories: true)

if let source = loadSource() {
    for (name, pixels) in sizes {
        let path = (outputDir as NSString).appendingPathComponent("\(name).png")
        writePNG(source, to: path, pixels: pixels)
    }
    // Keep a master 1024 copy in the set.
    let master = (outputDir as NSString).appendingPathComponent("icon_1024.png")
    writePNG(source, to: master, pixels: 1024)
    print("Done — icons generated from source PNG.")
} else {
    fputs("No source PNG found; procedural generator is no longer the primary path.\n", stderr)
    fputs("Place icon_1024.png in Assets.xcassets/AppIcon.appiconset/ and re-run.\n", stderr)
    exit(1)
}
