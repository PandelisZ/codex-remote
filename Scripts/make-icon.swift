#!/usr/bin/env swift
// Draws Codex Remote's app icon and writes the .icns.
//
// Geometry rather than an image asset, so the icon is reproducible, reviewable as a diff,
// and crisp at every size. That last part is why it is not a generated picture: a macOS
// icon has to survive being drawn at 16pt in a Finder list, and detail that looks good at
// 1024 turns to mush there. Everything is sized as a fraction of the canvas, and the detail
// that cannot survive a size is dropped at that size rather than smeared into grey.
//
// The mark is the thing the app is about: a rack of machines, one of them running. Three
// units, a drive slot on each, and a single live indicator — the same green the machine row
// uses when sessions are up. On the oxblood the site is built from, so the app, the page and
// the manual are recognisably one product.
import AppKit
import Foundation

_ = NSApplication.shared   // AppKit drawing needs an application object, even headless.

let outputDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
let sizes = [16, 32, 64, 128, 256, 512, 1024]

// The site's palette, so the three surfaces match.
let boardTop    = NSColor(srgbRed: 0.690, green: 0.165, blue: 0.243, alpha: 1)  // #B02A3E
let boardBottom = NSColor(srgbRed: 0.427, green: 0.086, blue: 0.149, alpha: 1)  // #6D1626
let paper       = NSColor(srgbRed: 0.965, green: 0.949, blue: 0.925, alpha: 1)  // #F6F2EC
let live        = NSColor(srgbRed: 0.322, green: 0.780, blue: 0.494, alpha: 1)  // #52C77E

func render(size: Int) -> Data? {
    let side = CGFloat(size)
    // Below 128pt a fractional edge lands mid-pixel and the mark goes soft, so the small
    // sizes are laid out in whole pixels. Rounding each rect independently is not enough:
    // two bars whose edges round towards each other close the gap between them and the rack
    // becomes one white block. The sizes below are therefore derived as integers first and
    // the stack is built from them, which keeps every gap at least a pixel wide.
    let snapping = size < 128
    func snap(_ value: CGFloat) -> CGFloat { snapping ? value.rounded() : value }

    // Drawn into an explicit sRGB context rather than NSImage.lockFocus, which renders at
    // the attached screen's backing scale: on a Retina Mac every size came out twice as
    // large, iconutil then slotted each image one size up, and the pixel snapping below was
    // snapping to half-pixels. One point is one pixel here, on any machine.
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let cgContext = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                                    bytesPerRow: 0, space: colorSpace,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    let context = NSGraphicsContext(cgContext: cgContext, flipped: false)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    defer { NSGraphicsContext.restoreGraphicsState() }
    context.imageInterpolation = .high

    // macOS leaves a margin around the rounded body rather than bleeding to the edge.
    let inset = side * 0.086
    let body = NSRect(x: inset, y: inset, width: side - inset * 2, height: side - inset * 2)
    // 22.37% of the width is the standard approximation of the macOS squircle.
    let radius = body.width * 0.2237
    let board = NSBezierPath(roundedRect: body, xRadius: radius, yRadius: radius)
    NSGradient(colors: [boardTop, boardBottom])?.draw(in: board, angle: -90)

    // Light from above: a highlight down the top edge and weight along the bottom, both
    // clipped to the board. A full stroke around the whole thing reads as an outline rather
    // than as a lit edge. Only at 64pt and up: the clip is antialiased, so at small sizes a
    // translucent white lands on the half-covered corner pixels and haloes the whole icon
    // pink — and six pixels of highlight were never going to add anything there anyway.
    if size >= 64 {
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: body.insetBy(dx: 1, dy: 1),
                     xRadius: radius, yRadius: radius).addClip()
        NSGradient(colors: [NSColor(white: 1, alpha: 0.22), NSColor(white: 1, alpha: 0)])?
            .draw(in: NSRect(x: body.minX, y: body.maxY - body.height * 0.30,
                             width: body.width, height: body.height * 0.30), angle: -90)
        NSGradient(colors: [NSColor(white: 0, alpha: 0.10), NSColor(white: 0, alpha: 0)])?
            .draw(in: NSRect(x: body.minX, y: body.minY,
                             width: body.width, height: body.height * 0.18), angle: 90)
        NSGraphicsContext.restoreGraphicsState()
    }

    // The rack. Three units filling most of the board, so the mark is the icon rather than
    // something floating in the middle of it. At 16pt three units and their gaps come to
    // well under a pixel each; two still read as a stack, three would be a grey smudge.
    let unitCount = size < 24 ? 2 : 3
    // At 16pt the fraction rounds down to two pixels a unit, which leaves the rack floating
    // in a board twice its height; a third pixel each fills it properly.
    let unitHeight = snapping ? max(size <= 16 ? 3 : 2, snap(side * 0.1484)) : side * 0.1484
    let gap = snapping ? max(1, snap(unitHeight * 0.32)) : unitHeight * 0.32
    let contentWidth = snap(side * 0.58)
    let left = snap((side - contentWidth) / 2)
    let unitRadius = unitHeight * 0.26

    let stackHeight = unitHeight * CGFloat(unitCount) + gap * CGFloat(unitCount - 1)
    var top = snap((side + stackHeight) / 2)

    for index in 0..<unitCount {
        let unit = NSRect(x: left, y: top - unitHeight, width: contentWidth, height: unitHeight)
        paper.setFill()
        NSBezierPath(roundedRect: unit, xRadius: unitRadius, yRadius: unitRadius).fill()

        // The slot. Below 64pt it is thinner than a pixel and only muddies the faceplate.
        if size >= 64 {
            let slotHeight = max(1, snap(unitHeight * 0.155))
            let slot = NSRect(x: snap(unit.minX + contentWidth * 0.10),
                              y: snap(unit.midY - slotHeight / 2),
                              width: snap(contentWidth * 0.36), height: slotHeight)
            boardBottom.withAlphaComponent(0.42).setFill()
            NSBezierPath(roundedRect: slot, xRadius: slot.height / 2, yRadius: slot.height / 2).fill()
        }

        // One unit is running. The rest are idle, which is the state the app actually shows
        // most of the time — a rack where everything is lit says nothing.
        let diameter = max(snapping ? 2 : 0, snap(unitHeight * 0.34))
        let dot = NSRect(x: snap(unit.maxX - contentWidth * 0.10 - diameter),
                         y: snap(unit.midY - diameter / 2),
                         width: diameter, height: diameter)
        let running = index == 0
        if running, size >= 128 {
            // A soft halo, so the indicator reads as lit rather than painted on.
            let halo = dot.insetBy(dx: -diameter * 0.55, dy: -diameter * 0.55)
            NSGradient(colors: [live.withAlphaComponent(0.45), live.withAlphaComponent(0)])?
                .draw(in: NSBezierPath(ovalIn: halo), relativeCenterPosition: .zero)
        }
        (running ? live : boardBottom.withAlphaComponent(0.30)).setFill()
        NSBezierPath(ovalIn: dot).fill()

        top -= unitHeight + gap
    }

    guard let rendered = cgContext.makeImage() else { return nil }
    let bitmap = NSBitmapImageRep(cgImage: rendered)
    bitmap.size = NSSize(width: side, height: side)
    return bitmap.representation(using: .png, properties: [:])
}

// .icns is built from an iconset directory; each size appears twice, once as the @2x of the
// size below it, which is what makes it sharp on Retina.
let iconset = URL(fileURLWithPath: outputDir).appendingPathComponent("CodexRemote.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

for size in sizes {
    guard let png = render(size: size) else {
        FileHandle.standardError.write(Data("could not render \(size)px\n".utf8))
        exit(1)
    }
    try png.write(to: iconset.appendingPathComponent("icon_\(size)x\(size).png"))
    if size >= 32 {
        try png.write(to: iconset.appendingPathComponent("icon_\(size / 2)x\(size / 2)@2x.png"))
    }
}

let icns = URL(fileURLWithPath: outputDir).appendingPathComponent("CodexRemote.icns")
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", icns.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else {
    FileHandle.standardError.write(Data("iconutil failed\n".utf8))
    exit(1)
}
// Kept: the site uses the 512 as its favicon source, and it saves re-rendering to inspect.
let keep = URL(fileURLWithPath: outputDir).appendingPathComponent("icon-512.png")
try? FileManager.default.removeItem(at: keep)
try? FileManager.default.copyItem(at: iconset.appendingPathComponent("icon_512x512.png"), to: keep)
try? FileManager.default.removeItem(at: iconset)
print(icns.path)   // Just the path: Scripts/bundle.sh reads this.
