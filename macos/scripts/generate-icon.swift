#!/usr/bin/env swift
// Renders the huske logo mark (website/assets/logo-mark-rounded.svg geometry)
// into an .iconset and compiles AppIcon.icns with iconutil.
// Usage: swift generate-icon.swift <output-dir>

import AppKit
import Foundation

let args = CommandLine.arguments
guard args.count == 2 else {
    FileHandle.standardError.write(Data("usage: generate-icon.swift <output-dir>\n".utf8))
    exit(2)
}
let outDir = URL(fileURLWithPath: args[1], isDirectory: true)
let iconset = outDir.appendingPathComponent("AppIcon.iconset", isDirectory: true)
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func render(size: Int, scale: Int, name: String) throws {
    let pixels = size * scale
    guard
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
    else { fatalError("bitmap rep") }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    let canvas = CGFloat(pixels)
    // HIG-style margin: artwork occupies ~80% of the canvas, centered.
    let art = canvas * 0.80
    let origin = (canvas - art) / 2.0
    let u = art / 64.0

    func rgb(_ hex: UInt32) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255.0,
            green: CGFloat((hex >> 8) & 0xFF) / 255.0,
            blue: CGFloat(hex & 0xFF) / 255.0, alpha: 1)
    }
    // y-flip: SVG y-down → AppKit y-up.
    func bar(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ color: NSColor, radius: CGFloat) {
        let rect = NSRect(
            x: origin + x * u, y: origin + (64 - y - h) * u, width: w * u, height: h * u)
        color.setFill()
        NSBezierPath(roundedRect: rect, xRadius: radius * u, yRadius: radius * u).fill()
    }

    bar(0, 0, 64, 64, rgb(0x0E1116), radius: 14)
    bar(14, 10, 6, 44, rgb(0xD88A3A), radius: 1.2)
    bar(24, 24, 26, 5, rgb(0xF4EFE3), radius: 1.2)
    bar(24, 34, 20, 5, rgb(0xF4EFE3), radius: 1.2)
    bar(24, 44, 14, 5, rgb(0xF4EFE3), radius: 1.2)

    NSGraphicsContext.restoreGraphicsState()
    guard let png = rep.representation(using: .png, properties: [:]) else { fatalError("png") }
    try png.write(to: iconset.appendingPathComponent(name))
}

for size in [16, 32, 128, 256, 512] {
    try render(size: size, scale: 1, name: "icon_\(size)x\(size).png")
    try render(size: size, scale: 2, name: "icon_\(size)x\(size)@2x.png")
}

let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", outDir.appendingPathComponent("AppIcon.icns").path]
try task.run()
task.waitUntilExit()
guard task.terminationStatus == 0 else { exit(task.terminationStatus) }
try? FileManager.default.removeItem(at: iconset)
print("wrote \(outDir.appendingPathComponent("AppIcon.icns").path)")
