import SwiftUI
import AppKit
import ImageIO
import UniformTypeIdentifiers

// The niivo mail app icon, drawn with CoreGraphics from the CI's icon rules (form-lab.html `icon` block and the
// ICON engine: `ICON = { cell:6.5, off:74, fill:{squircle:0.8}, shadowMin:96, solidBelow:32, nvScale:1.12 }`,
// `ICON_DEFAULT_BG.nv = 'carbon'`, `iconInk(carbon) = accent`). Colours are fixed sRGB hex (never `NV.*`, which follow
// the system appearance). Rules and rationale: docs/NIIVO-THEME.md §1.5.

/// Pure CoreGraphics drawing of the mark and the icon. Expects a y-down context.
enum NiivoIconArt {
    enum Colorway: Sendable {
        case signal   // signal ıı on carbon: the CI default (one ink = the one cyan element)
        case paper    // paper ıı on carbon: dark / tinted-friendly
        case ink      // ink ıı on paper, 1 pt line #E1E0DC: light

        var ground: UInt32 { self == .ink ? 0xF2F1EF : 0x0C0C0C }
        var mark: UInt32 {
            switch self { case .signal: 0x00D0FF; case .paper: 0xF2F1EF; case .ink: 0x111111 }
        }
    }

    // Apple macOS icon template: 1024 canvas, 824 body at 100, continuous corner 185.4.
    static let canvas: CGFloat = 1024, body: CGFloat = 824, inset: CGFloat = 100, corner: CGFloat = 185.4
    static let shadowMinPt: CGFloat = 96     // ICON.shadowMin (form-lab: "Below 96 px display size, drop the shadow")
    static let solidBelowPt: CGFloat = 32    // ICON.solidBelow (engine), keyed on display points
    static let shadowOffset: CGFloat = 74    // ICON.off, mark units
    static let cell: CGFloat = 6.5           // ICON.cell, mark units

    static func cg(_ rgb: UInt32, _ a: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255,
                blue: CGFloat(rgb & 0xFF) / 255, alpha: a)
    }

    /// The ıı (niivo-ci-study.md §4.1) in a 238 × 236 box mapped onto `box`. Outline = even-odd.
    static func markPath(in box: CGRect, solid: Bool, dy: CGFloat = 0) -> CGPath {
        let sx = box.width / 238, sy = box.height / 236
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: box.minX + x * sx, y: box.minY + (y + dy) * sy) }
        let p = CGMutablePath()
        for d in [CGFloat(0), 116] {
            p.addLines(between: [pt(0 + d, 236), pt(76 + d, 236), pt(122 + d, 0), pt(46 + d, 0)]); p.closeSubpath()
            if !solid {
                p.addLines(between: [pt(29.13 + d, 212), pt(56.23 + d, 212), pt(92.87 + d, 24), pt(65.77 + d, 24)]); p.closeSubpath()
            }
        }
        return p
    }

    /// Continuous-corner rounded rect (Apple's squircle): the only rounded thing the CI allows ("Only OS app icons
    /// follow the platform mask", form-lab.html:367). Built from SwiftUI's continuous style.
    static func squircle(_ r: CGRect, radius: CGFloat) -> CGPath {
        RoundedRectangle(cornerRadius: radius, style: .continuous).path(in: r).cgPath
    }

    /// A leaning cut centred at (cx, cy): bottom edge fixed, top shifted right by h·tan(11.03°).
    private static func cutPoly(_ cx: CGFloat, _ cy: CGFloat, _ w: CGFloat, _ h: CGFloat) -> [CGPoint] {
        let s = h * CGFloat(tan(NV.lean)) / 2
        return [CGPoint(x: cx - w / 2 - s, y: cy + h / 2), CGPoint(x: cx + w / 2 - s, y: cy + h / 2),
                CGPoint(x: cx + w / 2 + s, y: cy - h / 2), CGPoint(x: cx - w / 2 + s, y: cy - h / 2)]
    }

    /// Draws one icon into a y-down context of `side` × `side` px. `pointSize` is the display size it is for
    /// (shadow and hole are chosen by display points, so @2x matches its 1x sibling).
    static func draw(in ctx: CGContext, side: CGFloat, colorway cw: Colorway, pointSize: CGFloat) {
        let u = side / canvas
        let bodyR = CGRect(x: inset * u, y: inset * u, width: body * u, height: body * u)
        let tile = squircle(bodyR, radius: corner * u)

        ctx.saveGState()
        ctx.addPath(tile); ctx.setFillColor(cg(cw.ground)); ctx.fillPath()
        if cw == .ink {
            // .cii-line: 1 px #E1E0DC inside edge on light grounds.
            let lw = max(1, side / pointSize)
            ctx.addPath(squircle(bodyR.insetBy(dx: lw / 2, dy: lw / 2), radius: corner * u - lw / 2))
            ctx.setStrokeColor(cg(0xE1E0DC)); ctx.setLineWidth(lw); ctx.strokePath()
        }

        let shadow = pointSize >= shadowMinPt
        let solid = pointSize < solidBelowPt
        // markWidth(nv, squircle) = size · 0.8 · (238 / 404) · 1.12 (the ıı match the W's height, then +12 %).
        let mw = bodyR.width * 0.8 * (238.0 / 404.0) * 1.12
        let k = mw / 238
        let boxH = 236 + (shadow ? shadowOffset : 0)
        let mh = boxH * k
        let ox = bodyR.midX - mw / 2
        let oy = bodyR.midY - mh * (shadow ? 0.42 : 0.5)
        let markBox = CGRect(x: ox, y: oy, width: mw, height: 236 * k)
        let ink = cg(cw.mark)

        if shadow {
            // Cut noise: · and ı on the family (7, 13) mod 3 lattice, clipped hard to the solid ıı 74 units down.
            ctx.saveGState()
            ctx.addPath(markPath(in: markBox, solid: true, dy: shadowOffset)); ctx.clip()
            ctx.setFillColor(cg(cw.mark, 0.95))
            let cols = Int((238 / cell).rounded(.up)), rows = Int((boxH / cell).rounded(.up))
            let z = cell
            let iw = max(0.5, z * 0.085) * 1.2 * 1.1, ih = z * 0.62, dot = max(0.7, z * 0.17)
            for gy in 0..<rows {
                for gx in 0..<cols {
                    let cx = ox + (CGFloat(gx) + 0.5) * cell * k, cy = oy + (CGFloat(gy) + 0.5) * cell * k
                    let isCut = (gx * 7 + gy * 13) % 3 != 0
                    let poly = isCut ? cutPoly(cx, cy, iw * k, ih * k) : cutPoly(cx, cy, dot * k, dot * k)
                    ctx.addLines(between: poly); ctx.closePath()
                }
            }
            ctx.fillPath()
            ctx.restoreGState()
        }

        ctx.addPath(markPath(in: markBox, solid: solid))
        ctx.setFillColor(ink)
        ctx.fillPath(using: solid ? .winding : .evenOdd)
        ctx.restoreGState()
    }

    /// Renders one icon to a CGImage of `px` × `px`.
    static func image(px: Int, colorway: Colorway, pointSize: CGFloat) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(px)); ctx.scaleBy(x: 1, y: -1)   // y-down
        ctx.setShouldAntialias(true); ctx.interpolationQuality = .high
        draw(in: ctx, side: CGFloat(px), colorway: colorway, pointSize: pointSize)
        return ctx.makeImage()
    }
}

enum IconRender {
    struct Failure: Error, CustomStringConvertible { let description: String }

    /// The ten standard iconset members: (points, scale).
    static let iconsetSizes: [(Int, Int)] = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2),
                                             (256, 1), (256, 2), (512, 1), (512, 2)]

    /// Writes `<outDir>/AppIcon.iconset/*`, `<outDir>/AppIcon.icns` (via iconutil) and 256 px previews:
    /// `app-icon.png` (signal on carbon, the icon), `app-icon-dark.png` (paper on carbon), `app-icon-light.png`
    /// (ink on paper). There is no separate tinted file: macOS tints from luminance and paper-on-carbon already is
    /// the monochrome colourway.
    @MainActor static func run(outDir: URL) async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: outDir, withIntermediateDirectories: true)
        let set = outDir.appendingPathComponent("AppIcon.iconset", isDirectory: true)
        if fm.fileExists(atPath: set.path) { try fm.removeItem(at: set) }
        try fm.createDirectory(at: set, withIntermediateDirectories: true)

        for (pt, scale) in iconsetSizes {
            let name = "icon_\(pt)x\(pt)\(scale == 2 ? "@2x" : "").png"
            guard let img = NiivoIconArt.image(px: pt * scale, colorway: .signal, pointSize: CGFloat(pt)) else {
                throw Failure(description: "couldn't render \(name)")
            }
            try writePNG(img, to: set.appendingPathComponent(name))
        }

        let icns = outDir.appendingPathComponent("AppIcon.icns")
        if fm.fileExists(atPath: icns.path) { try fm.removeItem(at: icns) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
        p.arguments = ["-c", "icns", "-o", icns.path, set.path]
        let err = Pipe(); p.standardError = err
        try p.run(); p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw Failure(description: "iconutil exited \(p.terminationStatus): \(msg)")
        }

        for (file, cw) in [("app-icon.png", NiivoIconArt.Colorway.signal), ("app-icon-dark.png", .paper),
                           ("app-icon-light.png", .ink)] {
            guard let img = NiivoIconArt.image(px: 256, colorway: cw, pointSize: 256) else {
                throw Failure(description: "couldn't render \(file)")
            }
            try writePNG(img, to: outDir.appendingPathComponent(file))
        }
    }

    /// Renders `NiivoGlyphSheet` to `<outDir>/glyphs-light.png` and `glyphs-dark.png` at 2×.
    @MainActor static func glyphSheet(outDir: URL) throws {
        _ = NiivoFonts.available
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        for (file, dark) in [("glyphs-light.png", false), ("glyphs-dark.png", true)] {
            let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
            var out: CGImage?
            appearance.performAsCurrentDrawingAppearance {
                let r = ImageRenderer(content: NiivoGlyphSheet()
                    .environment(\.skin, .niivo)
                    .environment(\.colorScheme, dark ? .dark : .light))
                r.scale = 2
                out = r.cgImage
            }
            guard let img = out else { throw Failure(description: "couldn't render \(file)") }
            try writePNG(img, to: outDir.appendingPathComponent(file))
        }
    }

    static func writePNG(_ img: CGImage, to url: URL) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw Failure(description: "couldn't create \(url.lastPathComponent)")
        }
        CGImageDestinationAddImage(dest, img, nil)
        guard CGImageDestinationFinalize(dest) else { throw Failure(description: "couldn't write \(url.lastPathComponent)") }
    }
}
