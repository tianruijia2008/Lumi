import AppKit
import Foundation

// Draws Lumi's app icon and writes it out as PNGs / an .iconset.
//
// Kept as source rather than a checked-in binary asset: the icon is geometry,
// and geometry in code can be re-rendered at any size, re-tinted, and diffed.
// A 1024px PNG can only be replaced.

// MARK: - macOS icon geometry

/// Apple's grid: the art sits in a square inset from the canvas, not edge to
/// edge, so icons line up optically in the Dock and Finder.
private let canvasToArt: CGFloat = 824.0 / 1024.0

/// The rounded-rect corner is a continuous curve, not a circular arc. A
/// superellipse at this exponent is visually indistinguishable from Apple's
/// shape on a square, and unlike `CGPath(roundedRect:)` it does not read as
/// slightly too round next to system icons.
private func squircle(in rect: CGRect, exponent: CGFloat = 5) -> CGPath {
    let path = CGMutablePath()
    let a = rect.width / 2, b = rect.height / 2
    let cx = rect.midX, cy = rect.midY
    let steps = 512
    for step in 0...steps {
        let t = CGFloat(step) / CGFloat(steps) * 2 * .pi
        let cosT = cos(t), sinT = sin(t)
        let x = cx + a * copysign(pow(abs(cosT), 2 / exponent), cosT)
        let y = cy + b * copysign(pow(abs(sinT), 2 / exponent), sinT)
        if step == 0 { path.move(to: CGPoint(x: x, y: y)) }
        else { path.addLine(to: CGPoint(x: x, y: y)) }
    }
    path.closeSubpath()
    return path
}

private func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha)
}

private func gradient(_ stops: [(UInt32, CGFloat)]) -> CGGradient {
    CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
               colors: stops.map { color($0.0) } as CFArray,
               locations: stops.map { $0.1 })!
}

private func alphaGradient(_ stops: [(UInt32, CGFloat, CGFloat)]) -> CGGradient {
    CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
               colors: stops.map { color($0.0, $0.1) } as CFArray,
               locations: stops.map { $0.2 })!
}

/// macOS 26 supplies the tile itself: it masks whatever the .icns contains to
/// the system shape and adds the rim and shadow. So the art bleeds to the edge
/// of the canvas and draws no rounded rectangle of its own — drawing one puts a
/// second tile inside the system's, which reads as a badge floating on a white
/// card.
///
/// Layout still happens on Apple's 824/1024 grid, so nothing meaningful sits
/// where the mask will cut.
private var fullBleed = true

// MARK: - Shared background

/// The tile every concept sits on: a dark field so light has something to read
/// against, plus the sheen along the top edge that makes it look like glass
/// rather than a painted square.
private func drawTile(_ ctx: CGContext, _ art: CGRect, _ stops: [(UInt32, CGFloat)]) {
    let field = fullBleed ? canvasOf(art) : art
    ctx.saveGState()
    ctx.addPath(fullBleed ? CGPath(rect: field, transform: nil) : squircle(in: field))
    ctx.clip()
    ctx.drawLinearGradient(gradient(stops),
                           start: CGPoint(x: field.minX, y: field.maxY),
                           end: CGPoint(x: field.maxX, y: field.minY),
                           options: [])
    ctx.restoreGState()
}

/// Recovers the full canvas from the layout grid.
private func canvasOf(_ art: CGRect) -> CGRect {
    let side = art.width / canvasToArt
    return CGRect(x: art.midX - side / 2, y: art.midY - side / 2,
                  width: side, height: side)
}

/// The clip every concept uses for its own drawing.
private func tileShape(_ art: CGRect) -> CGPath {
    fullBleed
        ? CGPath(rect: canvasOf(art), transform: nil)
        : squircle(in: art)
}

private func drawTileSheen(_ ctx: CGContext, _ art: CGRect) {
    let field = fullBleed ? canvasOf(art) : art
    ctx.saveGState()
    ctx.addPath(tileShape(art))
    ctx.clip()
    // A broad wash from the top, then a hairline rim — the two things that
    // separate "glass" from "flat fill".
    ctx.drawLinearGradient(
        alphaGradient([(0xFFFFFF, 0.16, 0), (0xFFFFFF, 0.0, 0.45)]),
        start: CGPoint(x: field.midX, y: field.maxY),
        end: CGPoint(x: field.midX, y: field.midY),
        options: [])
    ctx.restoreGState()

    // The rim belongs to the system tile on macOS 26; drawing our own on top
    // of it doubles the highlight.
    guard !fullBleed else { return }
    ctx.saveGState()
    ctx.addPath(squircle(in: art.insetBy(dx: art.width * 0.004, dy: art.width * 0.004)))
    ctx.setStrokeColor(color(0xFFFFFF, 0.22))
    ctx.setLineWidth(art.width * 0.008)
    ctx.strokePath()
    ctx.restoreGState()
}

// MARK: - Shared layout

private func artRect(_ canvas: CGRect) -> CGRect {
    CGRect(x: canvas.midX - canvas.width * canvasToArt / 2,
           y: canvas.midY - canvas.height * canvasToArt / 2,
           width: canvas.width * canvasToArt,
           height: canvas.height * canvasToArt)
}

/// Fills a shape the way the app fills its panel: a faint white gradient with
/// a bright rim. Nothing else in the icon is allowed to look like this, so the
/// glass always reads as the one active element.
private func fillAsGlass(_ ctx: CGContext, path: CGPath, bounds: CGRect, rim: CGFloat) {
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    ctx.drawLinearGradient(
        alphaGradient([(0xFFFFFF, 0.30, 0), (0xFFFFFF, 0.08, 0.5), (0xFFFFFF, 0.20, 1)]),
        start: CGPoint(x: bounds.minX, y: bounds.maxY),
        end: CGPoint(x: bounds.maxX, y: bounds.minY),
        options: [])
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(path)
    ctx.setStrokeColor(color(0xFFFFFF, 0.55))
    ctx.setLineWidth(rim)
    ctx.strokePath()
    ctx.restoreGState()
}

// MARK: - Concept A — the glass changes what is behind it

/// A letter goes in one side and comes out the other in another script.
///
/// This is the app's actual gesture — put something behind Lumi's glass and
/// read it back — rather than a generic emblem for "languages". It also keeps
/// the icon in the same visual language as the panel itself.
private func drawTransformSlab(_ ctx: CGContext, _ canvas: CGRect) {
    let art = artRect(canvas)
    drawTile(ctx, art, [(0x1E2050, 0), (0x171A3C, 0.5), (0x0C0E22, 1)])

    ctx.saveGState()
    ctx.addPath(tileShape(art))
    ctx.clip()
    let unit = art.width

    // The source, deliberately quieter than the result.
    draw(text: "A", in: ctx,
         centeredAt: CGPoint(x: art.minX + unit * 0.215, y: art.midY + unit * 0.005),
         // Quiet enough to read as the "before", strong enough to survive the
         // resample to 32px — below about 0.55 the A disappears entirely there.
         size: unit * 0.50, weight: .semibold, alpha: 0.58)

    let slab = CGRect(x: art.minX + unit * 0.445, y: art.minY + unit * 0.12,
                      width: unit * 0.435, height: unit * 0.76)
    let radius = unit * 0.13
    let slabPath = CGPath(roundedRect: slab, cornerWidth: radius, cornerHeight: radius,
                          transform: nil)

    // A beam through the middle was the obvious way to say "light passes
    // through this" — but drawn across two glyphs it reads as a strikethrough,
    // which is the one thing an icon must not accidentally say. The glass
    // carries the idea on its own.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -unit * 0.02),
                  blur: unit * 0.07, color: color(0x000000, 0.45))
    ctx.addPath(slabPath)
    ctx.setFillColor(color(0xFFFFFF, 0.02))
    ctx.fillPath()
    ctx.restoreGState()

    fillAsGlass(ctx, path: slabPath, bounds: slab, rim: unit * 0.012)

    draw(text: "文", in: ctx, centeredAt: CGPoint(x: slab.midX, y: slab.midY),
         size: unit * 0.40, weight: .medium, alpha: 0.98)

    ctx.restoreGState()
    drawTileSheen(ctx, art)
}

// MARK: - Concept B — the same idea, as a lens

/// One glyph, half of it seen through glass — and the half under the glass is
/// already the other language. Rounder and more playful than the slab.
private func drawTransformLens(_ ctx: CGContext, _ canvas: CGRect) {
    let art = artRect(canvas)
    drawTile(ctx, art, [(0x24276A, 0), (0x1A1C48, 0.55), (0x0D0F26, 1)])

    ctx.saveGState()
    ctx.addPath(tileShape(art))
    ctx.clip()
    let unit = art.width

    draw(text: "A", in: ctx,
         centeredAt: CGPoint(x: art.midX - unit * 0.10, y: art.midY + unit * 0.06),
         size: unit * 0.62, weight: .semibold, alpha: 0.50)

    let radius = unit * 0.29
    let center = CGPoint(x: art.midX + unit * 0.14, y: art.midY - unit * 0.10)
    let lens = CGRect(x: center.x - radius, y: center.y - radius,
                      width: radius * 2, height: radius * 2)
    let lensPath = CGPath(ellipseIn: lens, transform: nil)

    // The lens is opaque enough to hide what it covers — the point is that it
    // shows something *different*, not a magnified version of the same thing.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -unit * 0.02),
                  blur: unit * 0.07, color: color(0x000000, 0.45))
    ctx.addPath(lensPath)
    // Opaque enough to hide the letter underneath — the point is that the lens
    // shows something *different*, not a magnified version of the same thing —
    // but not so opaque that it stops looking like glass and starts looking
    // like a hole punched in the tile.
    ctx.setFillColor(color(0x10132E, 0.72))
    ctx.fillPath()
    ctx.restoreGState()

    fillAsGlass(ctx, path: lensPath, bounds: lens, rim: unit * 0.014)

    draw(text: "文", in: ctx, centeredAt: center,
         size: unit * 0.34, weight: .medium, alpha: 0.98)

    ctx.restoreGState()
    drawTileSheen(ctx, art)
}

// MARK: - Concept C — two scripts, one surface

/// The conservative option: the two writing systems side by side, divided by
/// an edge of glass rather than a painted line.
private func drawScripts(_ ctx: CGContext, _ canvas: CGRect) {
    let art = artRect(canvas)
    drawTile(ctx, art, [(0x1C2E6B, 0), (0x16224F, 0.5), (0x0B1128, 1)])

    ctx.saveGState()
    ctx.addPath(tileShape(art))
    ctx.clip()
    let unit = art.width

    // A wedge of glass across the tile, not a hard colour split: the divider
    // is a physical object, which is what keeps it from looking like a flat
    // two-tone badge.
    let wedge = CGMutablePath()
    wedge.move(to: CGPoint(x: art.minX - unit * 0.2, y: art.minY + unit * 0.02))
    wedge.addLine(to: CGPoint(x: art.maxX + unit * 0.2, y: art.maxY - unit * 0.30))
    wedge.addLine(to: CGPoint(x: art.maxX + unit * 0.2, y: art.maxY - unit * 0.10))
    wedge.addLine(to: CGPoint(x: art.minX - unit * 0.2, y: art.minY + unit * 0.22))
    wedge.closeSubpath()

    draw(text: "A", in: ctx,
         centeredAt: CGPoint(x: art.midX - unit * 0.21, y: art.midY + unit * 0.21),
         size: unit * 0.44, weight: .semibold, alpha: 0.95)
    draw(text: "文", in: ctx,
         centeredAt: CGPoint(x: art.midX + unit * 0.22, y: art.midY - unit * 0.22),
         size: unit * 0.40, weight: .medium, alpha: 0.95)

    fillAsGlass(ctx, path: wedge, bounds: art, rim: unit * 0.006)

    ctx.restoreGState()
    drawTileSheen(ctx, art)
}

// MARK: - Text

private func draw(text: String, in ctx: CGContext, centeredAt point: CGPoint,
                  size: CGFloat, weight: NSFont.Weight, alpha: CGFloat) {
    let font = NSFont.systemFont(ofSize: size, weight: weight)
    let attributes: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: NSColor(cgColor: color(0xFFFFFF, alpha))!,
    ]
    let string = NSAttributedString(string: text, attributes: attributes)
    let bounds = string.size()

    let previous = NSGraphicsContext.current
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    string.draw(at: CGPoint(x: point.x - bounds.width / 2,
                            y: point.y - bounds.height / 2))
    NSGraphicsContext.current = previous
}

// MARK: - Output

private func render(_ concept: String, size: CGFloat) -> CGImage {
    let width = Int(size)
    let ctx = CGContext(data: nil, width: width, height: width,
                        bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setAllowsAntialiasing(true)
    ctx.interpolationQuality = .high
    let canvas = CGRect(x: 0, y: 0, width: size, height: size)
    switch concept {
    case "scripts":    drawScripts(ctx, canvas)
    case "lens":       drawTransformLens(ctx, canvas)
    default:           drawTransformSlab(ctx, canvas)
    }
    return ctx.makeImage()!
}

private func writePNG(_ image: CGImage, to path: String) {
    let rep = NSBitmapImageRep(cgImage: image)
    let data = rep.representation(using: .png, properties: [:])!
    try! data.write(to: URL(fileURLWithPath: path))
}

let arguments = CommandLine.arguments
let concept = arguments.count > 1 ? arguments[1] : "slab"
// `--tile` draws the rounded rectangle too, for platforms that do not supply
// one. macOS 26 does, so it is off by default.
fullBleed = !arguments.contains("--tile")
let output = arguments.count > 2 ? arguments[2] : "/tmp/icon.png"

if output.hasSuffix(".preview.png") {
    // Icons fail at 16 and 32, not at 1024. Nearest-neighbour upscaling shows
    // exactly which strokes survive the resample and which turn to porridge.
    let steps = [16, 32, 64, 128]
    let cell = 256, gap = 16
    let width = cell * steps.count + gap * (steps.count - 1)
    let sheet = CGContext(data: nil, width: width, height: cell,
                          bitsPerComponent: 8, bytesPerRow: 0,
                          space: CGColorSpaceCreateDeviceRGB(),
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    sheet.interpolationQuality = .none
    for (index, pixels) in steps.enumerated() {
        let image = render(concept, size: CGFloat(pixels))
        sheet.draw(image, in: CGRect(x: index * (cell + gap), y: 0,
                                     width: cell, height: cell))
    }
    writePNG(sheet.makeImage()!, to: output)
    print("wrote \(output)")
} else if output.hasSuffix(".iconset") {
    try? FileManager.default.createDirectory(atPath: output,
                                             withIntermediateDirectories: true)
    // The set macOS actually asks for; omitting a size makes Finder scale a
    // neighbour and the hairlines turn to mush.
    let sizes: [(Int, String)] = [
        (16, "icon_16x16"), (32, "icon_16x16@2x"),
        (32, "icon_32x32"), (64, "icon_32x32@2x"),
        (128, "icon_128x128"), (256, "icon_128x128@2x"),
        (256, "icon_256x256"), (512, "icon_256x256@2x"),
        (512, "icon_512x512"), (1024, "icon_512x512@2x"),
    ]
    for (pixels, name) in sizes {
        writePNG(render(concept, size: CGFloat(pixels)), to: "\(output)/\(name).png")
    }
    print("wrote \(output)")
} else {
    writePNG(render(concept, size: 1024), to: output)
    print("wrote \(output)")
}
