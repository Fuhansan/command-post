#!/usr/bin/env swift
// Generates AppIcon PNGs that mirror VibeNotch's status-bar SF Symbol look:
// black squircle background + white `note.text` glyph centered.
// Usage:  swift scripts/generate_appicon.swift  (run from project root)

import AppKit
import CoreImage

let projectDir = FileManager.default.currentDirectoryPath
let iconsetDir = "\(projectDir)/VibeNotch/Assets.xcassets/AppIcon.appiconset"

// macOS app icons live inside an 824x824 visual area on a 1024x1024 canvas
// (per Apple HIG). We render the squircle in that inset, then center the glyph.
let canvas: CGFloat = 1024
let visual: CGFloat = 824
let inset: CGFloat = (canvas - visual) / 2

// macOS continuous corner radius for the squircle is ~22.37% of visual size.
let cornerRadius: CGFloat = visual * 0.2237

func renderMaster() -> NSImage {
    let image = NSImage(size: NSSize(width: canvas, height: canvas))
    image.lockFocus()
    guard let ctx = NSGraphicsContext.current?.cgContext else {
        image.unlockFocus()
        return image
    }

    // Transparent canvas
    ctx.clear(CGRect(x: 0, y: 0, width: canvas, height: canvas))

    // Squircle background — a near-black gradient gives the icon depth so it
    // reads at small sizes instead of looking like a flat black square.
    let bgRect = CGRect(x: inset, y: inset, width: visual, height: visual)
    let path = NSBezierPath(roundedRect: bgRect, xRadius: cornerRadius, yRadius: cornerRadius)
    ctx.saveGState()
    path.addClip()

    let colors = [
        NSColor(calibratedRed: 0.13, green: 0.13, blue: 0.14, alpha: 1.0).cgColor,
        NSColor(calibratedRed: 0.04, green: 0.04, blue: 0.05, alpha: 1.0).cgColor,
    ]
    let space = CGColorSpaceCreateDeviceRGB()
    let gradient = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(
        gradient,
        start: CGPoint(x: bgRect.midX, y: bgRect.maxY),
        end: CGPoint(x: bgRect.midX, y: bgRect.minY),
        options: []
    )

    // Subtle inner highlight at the top edge for "depth"
    let highlightRect = CGRect(x: inset, y: bgRect.maxY - visual * 0.02, width: visual, height: visual * 0.02)
    ctx.setFillColor(NSColor.white.withAlphaComponent(0.05).cgColor)
    ctx.fill(highlightRect)
    ctx.restoreGState()

    // Glyph — same SF Symbol the status bar uses, in white, centered.
    let symbolSize = visual * 0.55
    let cfg = NSImage.SymbolConfiguration(pointSize: symbolSize, weight: .medium)
    guard let symbol = NSImage(systemSymbolName: "note.text", accessibilityDescription: nil)?
        .withSymbolConfiguration(cfg) else {
        image.unlockFocus()
        return image
    }

    let symRect = CGRect(
        x: (canvas - symbol.size.width) / 2,
        y: (canvas - symbol.size.height) / 2,
        width: symbol.size.width,
        height: symbol.size.height
    )

    // Render symbol in white via a tint pass
    if let tinted = symbol.tinted(with: .white) {
        tinted.draw(in: symRect, from: .zero, operation: .sourceOver, fraction: 1.0)
    }

    image.unlockFocus()
    return image
}

extension NSImage {
    func tinted(with color: NSColor) -> NSImage? {
        guard let copy = self.copy() as? NSImage else { return nil }
        copy.lockFocus()
        color.set()
        let imageRect = NSRect(origin: .zero, size: copy.size)
        imageRect.fill(using: .sourceAtop)
        copy.unlockFocus()
        copy.isTemplate = false
        return copy
    }

    func resized(to newSize: NSSize) -> NSImage {
        let img = NSImage(size: newSize)
        img.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        self.draw(
            in: NSRect(origin: .zero, size: newSize),
            from: NSRect(origin: .zero, size: self.size),
            operation: .copy,
            fraction: 1.0
        )
        img.unlockFocus()
        return img
    }

    func pngData() -> Data? {
        guard let tiff = self.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}

let master = renderMaster()
let sizes: [(name: String, px: CGFloat)] = [
    ("icon_16x16.png",      16),
    ("icon_16x16@2x.png",   32),
    ("icon_32x32.png",      32),
    ("icon_32x32@2x.png",   64),
    ("icon_128x128.png",   128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png",   256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png",   512),
    ("icon_512x512@2x.png", 1024),
]

for (name, px) in sizes {
    let resized = master.resized(to: NSSize(width: px, height: px))
    guard let data = resized.pngData() else {
        FileHandle.standardError.write(Data("✗ failed to encode \(name)\n".utf8))
        exit(1)
    }
    let url = URL(fileURLWithPath: "\(iconsetDir)/\(name)")
    try data.write(to: url)
    print("→ \(name) (\(Int(px))px)")
}

// Update Contents.json to reference the new files
let contentsJson = """
{
  "images" : [
    { "idiom" : "mac", "scale" : "1x", "size" : "16x16",   "filename" : "icon_16x16.png" },
    { "idiom" : "mac", "scale" : "2x", "size" : "16x16",   "filename" : "icon_16x16@2x.png" },
    { "idiom" : "mac", "scale" : "1x", "size" : "32x32",   "filename" : "icon_32x32.png" },
    { "idiom" : "mac", "scale" : "2x", "size" : "32x32",   "filename" : "icon_32x32@2x.png" },
    { "idiom" : "mac", "scale" : "1x", "size" : "128x128", "filename" : "icon_128x128.png" },
    { "idiom" : "mac", "scale" : "2x", "size" : "128x128", "filename" : "icon_128x128@2x.png" },
    { "idiom" : "mac", "scale" : "1x", "size" : "256x256", "filename" : "icon_256x256.png" },
    { "idiom" : "mac", "scale" : "2x", "size" : "256x256", "filename" : "icon_256x256@2x.png" },
    { "idiom" : "mac", "scale" : "1x", "size" : "512x512", "filename" : "icon_512x512.png" },
    { "idiom" : "mac", "scale" : "2x", "size" : "512x512", "filename" : "icon_512x512@2x.png" }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
"""
try contentsJson.write(
    toFile: "\(iconsetDir)/Contents.json",
    atomically: true,
    encoding: .utf8
)
print("✓ Wrote AppIcon files to \(iconsetDir)")
