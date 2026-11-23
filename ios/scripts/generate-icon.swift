#!/usr/bin/env swift
// Renders the iOS app icon (1024×1024, opaque, full-bleed) from the huske
// logo mark geometry (website/assets/logo-mark-rounded.svg). iOS applies the
// corner mask itself, so the ink square fills the canvas.
// Usage: swift scripts/generate-icon.swift Huske/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: generate-icon.swift <output.png>\n".utf8))
    exit(2)
}
let output = URL(fileURLWithPath: CommandLine.arguments[1])
let pixels = 1024
let space = CGColorSpace(name: CGColorSpace.sRGB)!
// Opaque RGB (no alpha): what App Store icons require.
guard let ctx = CGContext(
    data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
    space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
else { fatalError("context") }

let u = CGFloat(pixels) / 64.0
func rgb(_ hex: UInt32) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
}
// SVG is y-down; CoreGraphics is y-up.
func bar(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ color: CGColor, radius: CGFloat) {
    let rect = CGRect(x: x * u, y: (64 - y - h) * u, width: w * u, height: h * u)
    ctx.setFillColor(color)
    ctx.addPath(CGPath(roundedRect: rect, cornerWidth: radius * u, cornerHeight: radius * u, transform: nil))
    ctx.fillPath()
}
ctx.setFillColor(rgb(0x0E1116))
ctx.fill(CGRect(x: 0, y: 0, width: pixels, height: pixels))
bar(14, 10, 6, 44, rgb(0xD88A3A), radius: 1.2)
bar(24, 24, 26, 5, rgb(0xF4EFE3), radius: 1.2)
bar(24, 34, 20, 5, rgb(0xF4EFE3), radius: 1.2)
bar(24, 44, 14, 5, rgb(0xF4EFE3), radius: 1.2)

guard let image = ctx.makeImage(),
      let dest = CGImageDestinationCreateWithURL(output as CFURL, UTType.png.identifier as CFString, 1, nil)
else { fatalError("image") }
CGImageDestinationAddImage(dest, image, nil)
guard CGImageDestinationFinalize(dest) else { fatalError("write") }
print("wrote \(output.path)")
