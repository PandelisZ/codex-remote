#!/usr/bin/env swift
// Renders Codex Remote's app icon from an SF Symbol onto a rounded slab, then writes the .icns.
// Keeping this in-repo means the icon is reproducible and has no binary asset to review.
import AppKit
import Foundation

_ = NSApplication.shared   // AppKit drawing needs an application object, even headless.

let outputDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
let sizes = [16, 32, 64, 128, 256, 512, 1024]

func render(size: Int) -> Data? {
    let side = CGFloat(size)
    let image = NSImage(size: NSSize(width: side, height: side))
    image.lockFocus()

    let rect = NSRect(x: 0, y: 0, width: side, height: side)
    let inset = side * 0.06
    let body = rect.insetBy(dx: inset, dy: inset)
    let path = NSBezierPath(roundedRect: body, xRadius: side * 0.22, yRadius: side * 0.22)

    let gradient = NSGradient(colors: [
        NSColor(calibratedRed: 0.15, green: 0.44, blue: 0.86, alpha: 1),
        NSColor(calibratedRed: 0.09, green: 0.24, blue: 0.56, alpha: 1),
    ])
    gradient?.draw(in: path, angle: -90)

    let configuration = NSImage.SymbolConfiguration(pointSize: side * 0.5, weight: .semibold)
    if let symbol = NSImage(systemSymbolName: "server.rack", accessibilityDescription: "Codex Remote")?
        .withSymbolConfiguration(configuration) {
        let tinted = NSImage(size: symbol.size)
        tinted.lockFocus()
        NSColor.white.set()
        NSRect(origin: .zero, size: symbol.size).fill(using: .sourceOver)
        symbol.draw(at: .zero, from: .zero, operation: .destinationIn, fraction: 1)
        tinted.unlockFocus()

        let target = NSRect(x: (side - symbol.size.width) / 2,
                            y: (side - symbol.size.height) / 2,
                            width: symbol.size.width, height: symbol.size.height)
        tinted.draw(in: target, from: .zero, operation: .sourceOver, fraction: 0.96)
    }

    // The bitmap has to be read after the focus is released, or the backing store is
    // still owned by the drawing context and comes back empty.
    image.unlockFocus()

    guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
    let bitmap = NSBitmapImageRep(cgImage: cg)
    bitmap.size = NSSize(width: side, height: side)
    return bitmap.representation(using: .png, properties: [:])
}

let iconset = URL(fileURLWithPath: outputDir).appendingPathComponent("Codex Remote.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

for size in sizes {
    guard let data = render(size: size) else { continue }
    try data.write(to: iconset.appendingPathComponent("icon_\(size)x\(size).png"))
    if size <= 512, let retina = render(size: size * 2) {
        try retina.write(to: iconset.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
    }
}
print(iconset.path)
