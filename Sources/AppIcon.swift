// The cl_audit app's own icon, unlike the profiles' Dock icons (Painter): six designs, chosen in Settings ▸ General ▸
// App icon. The built bundle carries the default (Front panel, build.sh); the chosen one is set while the app runs.

import AppKit
import SwiftUI

enum AppIconStyle: String, CaseIterable, Identifiable {
    case panel, panelLit, orange, stack, meter, levels, knob, monogram
    var id: String { rawValue }
    static let standard: AppIconStyle = .panel
    var title: String {
        switch self {
        case .panel: return "Front panel"
        case .panelLit: return "Lit frame"
        case .orange: return "Orange plate"
        case .stack: return "Stack"
        case .meter: return "VU meter"
        case .levels: return "Level meter"
        case .knob: return "Knob"
        case .monogram: return "Monogram"
        }
    }
}

/// The orange plate's own choices: what its display shows, its keys and its slot.
enum PlateDisplay: String, CaseIterable, Identifiable {
    case cyan, bluish, orange, levels
    var id: String { rawValue }
    var title: String { self == .levels ? "Levels" : rawValue.capitalized }
}
enum PlateKeys: String, CaseIterable, Identifiable {
    case classic, graphite, strip, round, tonal, wide
    var id: String { rawValue }
    var title: String { self == .tonal ? "Orange" : rawValue.capitalized }
}
enum PlateSlot: String, CaseIterable, Identifiable {
    case light, dark
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}
struct PlateLook: Equatable {
    var display: PlateDisplay = .cyan
    var keys: PlateKeys = .strip
    var slot: PlateSlot = .light
}

final class AppIconPrefs: ObservableObject {
    static let shared = AppIconPrefs()
    private let key = "appIconStyle"
    @Published var style: AppIconStyle { didSet { UserDefaults.standard.set(style.rawValue, forKey: key); apply() } }
    @Published var plate: PlateLook {
        didSet {
            let d = UserDefaults.standard
            d.set(plate.display.rawValue, forKey: "appIconPlateDisplay")
            d.set(plate.keys.rawValue, forKey: "appIconPlateKeys")
            d.set(plate.slot.rawValue, forKey: "appIconPlateSlot")
            apply()
        }
    }
    private init() {
        let d = UserDefaults.standard
        style = AppIconStyle(rawValue: d.string(forKey: key) ?? "") ?? .standard
        plate = PlateLook(display: PlateDisplay(rawValue: d.string(forKey: "appIconPlateDisplay") ?? "") ?? .cyan,
                          keys: PlateKeys(rawValue: d.string(forKey: "appIconPlateKeys") ?? "") ?? .strip,
                          slot: PlateSlot(rawValue: d.string(forKey: "appIconPlateSlot") ?? "") ?? .light)
    }

    /// The Dock and the app switcher show the chosen icon while the app runs.
    func apply() { NSApp.applicationIconImage = AppIcon.image(style, plate: plate, pixels: 512) }
}

enum AppIcon {
    // MARK: colours (as on the home site)
    static let cyan = TileColor.hex(0x7ff9ea)
    static let slot: [(CGFloat, NSColor)] = [(0, TileColor.hex(0xffb08a)), (0.6, TileColor.hex(0xff7a3d)), (1, TileColor.hex(0xf0612a))]
    static let slotGlow = TileColor.hex(0xff7a3d)
    static let gun: [(CGFloat, NSColor)] = [(0, TileColor.hex(0x8a8a85)), (1, TileColor.hex(0x4c4c48))]
    static let silver: [(CGFloat, NSColor)] = [(0, TileColor.hex(0xf3f3f1)), (1, TileColor.hex(0xb9b9b4))]
    static let glass: [(CGFloat, NSColor)] = [(0, TileColor.hex(0x030607)), (0.7, TileColor.hex(0x0a1113)), (1, TileColor.hex(0x0d1719))]
    static let profiles = (teal: TileColor.teal.color(fiveHour: nil, stale: false), orange: Painter.orange,
                           purple: TileColor.purple.color(fiveHour: nil, stale: false), pink: TileColor.pink.color(fiveHour: nil, stale: false),
                           blue: TileColor.blue.color(fiveHour: nil, stale: false))

    // MARK: output

    /// Draws in a 64×64, y-down space (the context must be flipped), scaled to fit `rect`.
    static func draw(_ style: AppIconStyle, plate: PlateLook = PlateLook(), in rect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let s = min(rect.width, rect.height) / 64
        ctx.saveGState()
        ctx.translateBy(x: rect.minX + (rect.width - 64 * s) / 2, y: rect.minY + (rect.height - 64 * s) / 2)
        ctx.scaleBy(x: s, y: s)
        unit = s
        switch style {
        case .panel: panel(ctx)
        case .panelLit: panel(ctx); litFrame(ctx)
        case .orange: orangePlate(ctx, plate)
        case .stack: stack(ctx)
        case .meter: meter(ctx)
        case .levels: levels(ctx)
        case .knob: knob(ctx)
        case .monogram: monogram(ctx)
        }
        ctx.restoreGState()
    }

    static func image(_ style: AppIconStyle, plate: PlateLook = PlateLook(), pixels: Int) -> NSImage {
        NSImage(size: NSSize(width: pixels, height: pixels), flipped: true) { r in draw(style, plate: plate, in: r); return true }
    }

    static func png(_ style: AppIconStyle, plate: PlateLook = PlateLook(), pixels px: Int) -> Data? {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image(style, plate: plate, pixels: px).draw(in: NSRect(x: 0, y: 0, width: px, height: px))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }

    /// The bundle's icon (shown while the app isn't running), as an .iconset folder for iconutil.
    static func writeIconset(_ style: AppIconStyle = .standard, to dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for base in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
                try? png(style, pixels: base * scale)?.write(to: dir.appendingPathComponent(name))
            }
        }
    }

    // MARK: helpers (64-unit space, y down; angles from 12 o'clock, clockwise)

    /// Pixels per unit of the icon being drawn: glows and shadows are in pixels.
    static var unit: CGFloat = 1
    static let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

    static func rr(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat) -> CGPath {
        CGPath(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerWidth: min(r, w / 2), cornerHeight: min(r, h / 2), transform: nil)
    }
    static func circle(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat) -> CGPath {
        CGPath(ellipseIn: CGRect(x: cx - r, y: cy - r, width: 2 * r, height: 2 * r), transform: nil)
    }
    static func pt(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat, _ deg: CGFloat) -> CGPoint {
        let a = deg * .pi / 180
        return CGPoint(x: cx + r * sin(a), y: cy - r * cos(a))
    }
    static func arc(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat, _ a0: CGFloat, _ a1: CGFloat) -> CGPath {
        let p = CGMutablePath()
        let n = 48
        for i in 0...n {
            let q = pt(cx, cy, r, a0 + (a1 - a0) * CGFloat(i) / CGFloat(n))
            i == 0 ? p.move(to: q) : p.addLine(to: q)
        }
        return p
    }
    static func gradient(_ stops: [(CGFloat, NSColor)]) -> CGGradient {
        CGGradient(colorsSpace: srgb, colors: stops.map { $0.1.cgColor } as CFArray, locations: stops.map { $0.0 })!
    }

    static func fill(_ c: CGContext, _ p: CGPath, _ color: NSColor) {
        c.addPath(p); c.setFillColor(color.cgColor); c.fillPath()
    }
    static func stroke(_ c: CGContext, _ p: CGPath, _ color: NSColor, _ w: CGFloat, round: Bool = false) {
        c.addPath(p); c.setStrokeColor(color.cgColor); c.setLineWidth(w)
        c.setLineCap(round ? .round : .butt); c.strokePath()
    }
    /// Fills `p` with a top-to-bottom gradient running from y0 to y1.
    static func vfill(_ c: CGContext, _ p: CGPath, _ stops: [(CGFloat, NSColor)], _ y0: CGFloat, _ y1: CGFloat) {
        c.saveGState(); c.addPath(p); c.clip()
        c.drawLinearGradient(gradient(stops), start: CGPoint(x: 0, y: y0), end: CGPoint(x: 0, y: y1),
                             options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        c.restoreGState()
    }
    /// Strokes `p` with a top-to-bottom gradient (the bevel's highlight).
    static func vstroke(_ c: CGContext, _ p: CGPath, _ w: CGFloat, _ stops: [(CGFloat, NSColor)], _ y0: CGFloat, _ y1: CGFloat) {
        c.saveGState(); c.addPath(p); c.setLineWidth(w); c.replacePathWithStrokedPath(); c.clip()
        c.drawLinearGradient(gradient(stops), start: CGPoint(x: 0, y: y0), end: CGPoint(x: 0, y: y1),
                             options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        c.restoreGState()
    }
    /// Runs `draw` with a soft glow in `color`, like the site's display text and LEDs.
    static func glow(_ c: CGContext, _ color: NSColor, radius: CGFloat = 2.4, _ draw: () -> Void) {
        c.saveGState()
        c.setShadow(offset: .zero, blur: radius * unit, color: color.withAlphaComponent(0.75).cgColor)
        c.beginTransparencyLayer(auxiliaryInfo: nil); draw(); c.endTransparencyLayer()
        c.restoreGState()
    }
    /// Runs `draw` with a small drop shadow below it.
    static func drop(_ c: CGContext, _ draw: () -> Void) {
        c.saveGState()
        // shadow offsets are in device space, which is y-up under the flipped icon space
        c.setShadow(offset: CGSize(width: 0, height: -1.2 * unit), blur: 2.4 * unit, color: NSColor.black.withAlphaComponent(0.55).cgColor)
        c.beginTransparencyLayer(auxiliaryInfo: nil); draw(); c.endTransparencyLayer()
        c.restoreGState()
    }
    static let highlight: [(CGFloat, NSColor)] = [(0, .white.withAlphaComponent(0.45)), (1, .white.withAlphaComponent(0))]

    /// A brushed plate in the profiles' squircle, so the icons match in size in the Dock.
    static func plate(_ c: CGContext, _ stops: [(CGFloat, NSColor)], hair: NSColor, edge: NSColor) {
        let p = rr(2, 2, 60, 60, 14)
        vfill(c, p, stops, 2, 62)
        if unit >= 2 {   // the brushing is lost below 128 px, where it would only add noise
            c.saveGState(); c.addPath(p); c.clip()
            c.setFillColor(hair.cgColor)
            for x in stride(from: CGFloat(2), to: 62, by: 1.4) { c.fill(CGRect(x: x, y: 2, width: 0.7, height: 60)) }
            c.restoreGState()
        }
        vstroke(c, rr(2.6, 2.6, 58.8, 58.8, 13.4), 1.2, highlight, 2.6, 17.3)
        stroke(c, rr(2.4, 2.4, 59.2, 59.2, 13.6), edge.withAlphaComponent(0.55), 0.8)
    }
    static func gunPlate(_ c: CGContext) { plate(c, gun, hair: .white.withAlphaComponent(0.07), edge: TileColor.hex(0x111111)) }

    /// The orange light slot.
    static func slotBar(_ c: CGContext, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, glows: Bool = true) {
        let p = rr(x, y, w, h, h / 2)
        if glows { glow(c, slotGlow) { vfill(c, p, slot, y, y + h) } } else { vfill(c, p, slot, y, y + h) }
    }

    // MARK: the six designs

    /// Front panel: a piece of the site — gunmetal plate, orange slot, a display with three profile levels, two keys.
    static func panel(_ c: CGContext) {
        gunPlate(c)
        slotBar(c, 18, 8, 28, 3.4)
        let win = rr(8, 16, 48, 29, 4)
        vfill(c, win, glass, 16, 45)
        stroke(c, win, .black, 0.8)
        for (row, lit) in [7, 4, 6].enumerated() {
            for i in 0..<8 where i >= lit {
                fill(c, rr(12 + CGFloat(i) * 5, 21.5 + CGFloat(row) * 7.5, 4, 4.6, 0.6), cyan.withAlphaComponent(0.13))
            }
        }
        glow(c, cyan) {
            for (row, lit) in [7, 4, 6].enumerated() {
                for i in 0..<lit { fill(c, rr(12 + CGFloat(i) * 5, 21.5 + CGFloat(row) * 7.5, 4, 4.6, 0.6), cyan) }
            }
        }
        fill(c, rr(8, 16, 48, 12, 4), .white.withAlphaComponent(0.05))
        let alu: [(CGFloat, NSColor)] = [(0, TileColor.hex(0xd9d9d5)), (1, TileColor.hex(0x9e9e99))]
        for x: CGFloat in [10, 34] {
            let k = rr(x, 49, 20, 8, 1.8)
            vfill(c, k, alu, 49, 57)
            stroke(c, k, TileColor.hex(0x222222), 0.7)
        }
        slotBar(c, 14, 51, 12, 1.6, glows: false)
    }

    /// Front panel with a frame lit like the LED strip on a pressed key: where the profiles have their colour frame.
    static func litFrame(_ c: CGContext) {
        let p = rr(3.25, 3.25, 57.5, 57.5, 12.8)
        glow(c, slotGlow, radius: 3) { stroke(c, p, slotGlow, 2.5) }
        stroke(c, p, TileColor.hex(0xffb08a), 0.9)
    }

    /// Orange plate: Front panel with the plate in the profile frame's orange (flat, with the tiles' soft top light),
    /// a grey slot, and its own display colour and keys (Settings ▸ General ▸ App icon).
    static func orangePlate(_ c: CGContext, _ look: PlateLook) {
        let plateC: [(CGFloat, NSColor)] = [(0, TileColor.hex(0xdf8d72)), (0.5, Painter.orange), (1, TileColor.hex(0xbf694d))]
        let alu: [(CGFloat, NSColor)] = [(0, TileColor.hex(0xd9d9d5)), (1, TileColor.hex(0x9e9e99))]
        let brown = TileColor.hex(0x5a2a1a)
        vfill(c, rr(2, 2, 60, 60, 14), plateC, 2, 62)
        vstroke(c, rr(2.6, 2.6, 58.8, 58.8, 13.4), 1.2, highlight, 2.6, 17.3)

        // the slot: an unlit grey bar set into the plate, or a dark groove
        if look.slot == .light {
            fill(c, rr(16.8, 7.1, 30.4, 5, 2.5), .black.withAlphaComponent(0.16))
            vfill(c, rr(18, 8, 28, 3.4, 1.7), [(0, TileColor.hex(0xececea)), (1, TileColor.hex(0xa7a7a3))], 8, 11.4)
        } else {
            vfill(c, rr(18, 8, 28, 3.4, 1.7), [(0, TileColor.hex(0x1c1c1e)), (1, TileColor.hex(0x3a3a3d))], 8, 11.4)
            fill(c, rr(18.4, 11.5, 27.2, 0.6, 0.3), .white.withAlphaComponent(0.28))
        }

        // the display
        let win = rr(8, 16, 48, 29, 4)
        vfill(c, win, glass, 16, 45)
        stroke(c, win, brown, 0.8)
        func segColor(_ i: Int) -> NSColor {
            switch look.display {
            case .cyan: return cyan
            case .bluish: return TileColor.hex(0x8cbcff)
            case .orange: return TileColor.hex(0xf29a77)
            case .levels: return i < 4 ? Painter.green : i < 6 ? Painter.amber : Painter.red
            }
        }
        func seg(_ row: Int, _ i: Int) -> CGPath { rr(12 + CGFloat(i) * 5, 21.5 + CGFloat(row) * 7.5, 4, 4.6, 0.6) }
        let lit = [7, 4, 6]
        for (row, n) in lit.enumerated() { for i in n..<8 { fill(c, seg(row, i), segColor(i).withAlphaComponent(0.14)) } }
        for i in 0..<8 {   // grouped by column so each colour gets its own glow
            let rows = lit.indices.filter { i < lit[$0] }
            guard !rows.isEmpty else { continue }
            glow(c, segColor(i)) { for row in rows { fill(c, seg(row, i), segColor(i)) } }
        }
        fill(c, rr(8, 16, 48, 12, 4), .white.withAlphaComponent(0.05))

        // the keys; their lit strip takes the display's colour (green for the levels)
        let led = look.display == .levels ? Painter.green : segColor(0)
        func ledStrip(_ x: CGFloat, _ w: CGFloat) { glow(c, led) { fill(c, rr(x, 51.2, w, 1.6, 0.8), led) } }
        switch look.keys {
        case .classic:
            for x: CGFloat in [10, 34] { let k = rr(x, 49, 20, 8, 1.8); vfill(c, k, alu, 49, 57); stroke(c, k, brown, 0.7) }
            fill(c, rr(14, 51, 12, 1.6, 0.8), Painter.orange)
        case .graphite:
            for x: CGFloat in [10, 34] {
                fill(c, rr(x, 49.6, 20, 8, 2), .black.withAlphaComponent(0.22))
                vfill(c, rr(x, 48.8, 20, 8, 2), [(0, TileColor.hex(0x3c3c3f)), (1, TileColor.hex(0x1d1d1f))], 48.8, 56.8)
                fill(c, rr(x + 1, 49.3, 18, 0.5, 0.25), .white.withAlphaComponent(0.22))
            }
            ledStrip(14, 12)
        case .strip:
            fill(c, rr(8, 47.4, 48, 11.4, 3.4), .black.withAlphaComponent(0.2))
            fill(c, rr(8, 58.3, 48, 0.6, 0.3), .white.withAlphaComponent(0.22))
            for x: CGFloat in [9.6, 32.8] {
                vfill(c, rr(x, 49, 21.6, 8, 2), alu, 49, 57)
                fill(c, rr(x + 0.8, 49.4, 20, 0.5, 0.25), .white.withAlphaComponent(0.8))
                fill(c, rr(x, 56.3, 21.6, 0.7, 0.35), .black.withAlphaComponent(0.25))
            }
            ledStrip(14.4, 12)
        case .round:
            for (i, x) in [CGFloat(17), 32, 47].enumerated() {
                fill(c, circle(x, 53.6, 4.6), .black.withAlphaComponent(0.2))
                let b = circle(x, 53, 4.2)
                c.saveGState(); c.addPath(b); c.clip()
                c.drawRadialGradient(gradient([(0, TileColor.hex(0xf4f4f2)), (0.6, TileColor.hex(0xcfcfcb)), (1, TileColor.hex(0x9a9a96))]),
                                     startCenter: CGPoint(x: x - 0.84, y: 51.32), startRadius: 0,
                                     endCenter: CGPoint(x: x - 0.84, y: 51.32), endRadius: 6.72, options: [.drawsAfterEndLocation])
                c.restoreGState()
                stroke(c, b, .white.withAlphaComponent(0.5), 0.5)
                if i == 0 { glow(c, led) { stroke(c, circle(x, 53, 5.4), led, 1.1) } }
            }
        case .tonal:
            for x: CGFloat in [10, 34] {
                fill(c, rr(x, 49.8, 20, 8, 2), TileColor.hex(0x7a3520).withAlphaComponent(0.45))
                vfill(c, rr(x, 48.8, 20, 8, 2), [(0, TileColor.hex(0xeda78c)), (1, TileColor.hex(0xcd7a5e))], 48.8, 56.8)
                fill(c, rr(x + 1, 49.3, 18, 0.5, 0.25), .white.withAlphaComponent(0.45))
            }
            ledStrip(14, 12)
        case .wide:
            fill(c, rr(10, 49.8, 44, 8, 2.2), .black.withAlphaComponent(0.22))
            vfill(c, rr(10, 48.8, 44, 8, 2.2), alu, 48.8, 56.8)
            fill(c, rr(11, 49.3, 42, 0.5, 0.25), .white.withAlphaComponent(0.8))
            ledStrip(20, 24)
        }
    }

    /// Stack: three profile tiles fanned behind each other — all your profiles in one place.
    static func stack(_ c: CGContext) {
        let bg: [(CGFloat, NSColor)] = [(0, TileColor.hex(0x2b2b2f)), (1, TileColor.hex(0x121214))]
        func tile(_ x: CGFloat, _ y: CGFloat, _ color: NSColor, shadow: Bool) {
            let p = rr(x, y, 42, 42, 10)
            let body = { vfill(c, p, bg, y, y + 42); stroke(c, p, color, 2.6) }
            shadow ? drop(c, body) : body()
        }
        tile(18, 4, profiles.purple, shadow: true)
        tile(11, 11, profiles.teal, shadow: true)
        tile(4, 18, profiles.orange, shadow: false)
        for (y, w, color) in [(CGFloat(29), CGFloat(19), Painter.green), (42, 11, Painter.amber)] {
            fill(c, rr(10, y, 30, 7, 3.5), Painter.track)
            glow(c, color) { fill(c, rr(10, y, w, 7, 3.5), color) }
        }
    }

    /// VU meter: a backlit warm meter window with a needle, over the orange slot, like the meters on an amplifier.
    static func meter(_ c: CGContext) {
        gunPlate(c)
        let win = rr(7, 7, 50, 39, 4)
        vfill(c, win, [(0, TileColor.hex(0xfdf1d2)), (1, TileColor.hex(0xeccf8f))], 7, 46)
        c.saveGState(); c.addPath(win); c.clip()
        let (cx, cy, r): (CGFloat, CGFloat, CGFloat) = (32, 57, 33)
        let ink = TileColor.hex(0x2a2620)
        stroke(c, arc(cx, cy, r, -42, 14), ink, 1.3)
        stroke(c, arc(cx, cy, r + 1.6, 14, 42), TileColor.hex(0xd23a22), 3.6)
        for a in stride(from: CGFloat(-42), through: 42, by: 14) {
            let long = Int(a) % 28 == 0
            let t = CGMutablePath()
            t.move(to: pt(cx, cy, r, a)); t.addLine(to: pt(cx, cy, r + (long ? 5 : 3.2), a))
            stroke(c, t, a >= 14 ? TileColor.hex(0xc8321e) : ink, 1.3)
        }
        let needle = CGMutablePath()
        needle.move(to: CGPoint(x: cx, y: cy)); needle.addLine(to: pt(cx, cy, r + 4, 22))
        stroke(c, needle, TileColor.hex(0x141414), 2.4, round: true)
        fill(c, CGPath(rect: CGRect(x: 7, y: 7, width: 50, height: 10), transform: nil), .white.withAlphaComponent(0.25))
        c.restoreGState()
        stroke(c, win, .black, 1)
        slotBar(c, 20, 51.5, 24, 3.4)
    }

    /// Level meter: one LED column per profile on black glass, green → amber → red, each profile's colour below.
    static func levels(_ c: CGContext) {
        gunPlate(c)
        let win = rr(7, 7, 50, 40, 4)
        vfill(c, win, glass, 7, 47)
        stroke(c, win, .black, 0.8)
        let cols: [(NSColor, Int)] = [(profiles.teal, 3), (profiles.orange, 5), (profiles.purple, 2), (profiles.pink, 6)]
        func seg(_ i: Int, _ k: Int) -> CGPath { rr(11.75 + CGFloat(i) * 11, 41 - CGFloat(k) * 5.7, 7.5, 4.2, 0.7) }
        func level(_ k: Int) -> NSColor { k < 3 ? Painter.green : k < 5 ? Painter.amber : Painter.red }
        for (i, col) in cols.enumerated() {
            for k in col.1..<6 { fill(c, seg(i, k), level(k).withAlphaComponent(0.14)) }
        }
        for k in 0..<6 {
            let lit = cols.indices.filter { k < cols[$0].1 }
            guard !lit.isEmpty else { continue }
            glow(c, level(k)) { for i in lit { fill(c, seg(i, k), level(k)) } }
        }
        fill(c, rr(7, 7, 50, 14, 4), .white.withAlphaComponent(0.05))
        for (i, col) in cols.enumerated() { fill(c, circle(15.5 + CGFloat(i) * 11, 54.5, 2.7), col.0) }
    }

    /// Knob: a round selector, the profiles' colours around a brushed knob with its orange pointer on one.
    static func knob(_ c: CGContext) {
        let bezel = circle(32, 32, 30)
        c.saveGState(); c.addPath(bezel); c.clip()
        c.drawRadialGradient(gradient([(0, TileColor.hex(0x3a3a3e)), (1, TileColor.hex(0x101012))]),
                             startCenter: CGPoint(x: 32, y: 17), startRadius: 0, endCenter: CGPoint(x: 32, y: 17), endRadius: 51,
                             options: [.drawsAfterEndLocation])
        c.restoreGState()
        stroke(c, bezel, .black, 0.8)
        vstroke(c, circle(32, 32, 29.4), 1.2, highlight, 2.6, 17.3)
        let ticks = CGMutablePath()
        for a in stride(from: CGFloat(0), to: 360, by: 15) { ticks.move(to: pt(32, 32, 26.6, a)); ticks.addLine(to: pt(32, 32, 28.6, a)) }
        stroke(c, ticks, .white.withAlphaComponent(0.32), 0.9)
        for (a, col) in [(CGFloat(-100), profiles.purple), (-50, profiles.teal), (0, profiles.orange), (50, profiles.pink), (100, profiles.blue)] {
            let p = pt(32, 32, 22.6, a)
            fill(c, circle(p.x, p.y, 2.6), col)
        }
        drop(c) { fill(c, circle(32, 33.2, 18), .black.withAlphaComponent(0.55)) }
        let k = circle(32, 32, 18)
        c.saveGState(); c.addPath(k); c.clip()
        c.drawRadialGradient(gradient([(0, TileColor.hex(0xfafaf8)), (0.55, TileColor.hex(0xc8c8c3)), (1, TileColor.hex(0x85857f))]),
                             startCenter: CGPoint(x: 27.7, y: 24.8), startRadius: 0, endCenter: CGPoint(x: 27.7, y: 24.8), endRadius: 28.8,
                             options: [.drawsAfterEndLocation])
        if unit >= 2 {
            for r in stride(from: CGFloat(3), to: 17, by: 1.4) { stroke(c, circle(32, 32, r), .black.withAlphaComponent(0.06), 0.5) }
        }
        c.restoreGState()
        stroke(c, k, TileColor.hex(0x55554f), 0.8)
        let ptr = CGMutablePath()
        ptr.move(to: pt(32, 32, 8, -50)); ptr.addLine(to: pt(32, 32, 15, -50))
        glow(c, slotGlow) { stroke(c, ptr, slotGlow, 3.4, round: true) }
    }

    /// Monogram: "cl_" printed on a silver nameplate, the underscore being the orange slot.
    static func monogram(_ c: CGContext) {
        plate(c, silver, hair: .black.withAlphaComponent(0.05), edge: TileColor.hex(0x3a3a38))
        Painter.text("cl", .monospacedSystemFont(ofSize: 28, weight: .heavy), TileColor.hex(0x1d1d1f), x: 8.5, baseline: 42, kern: -1)
        slotBar(c, 42, 38.4, 13.5, 4.2)
    }
}

/// Settings ▸ General ▸ App icon: each design over its key; the chosen one latched.
struct AppIconPicker: View {
    @ObservedObject private var prefs = AppIconPrefs.shared
    @Environment(\.face) private var face

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
            ForEach(AppIconStyle.allCases) { s in
                let on = prefs.style == s
                Button { prefs.style = s } label: {
                    VStack(spacing: 6) {
                        Image(nsImage: AppIcon.image(s, plate: prefs.plate, pixels: 96)).resizable().frame(width: 44, height: 44)
                        KeyLook(kind: .page, latched: on, height: 20, hPad: 8) { Text(s.title) }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 4).padding(.top, 7).padding(.bottom, 4)
                    .background { if on { WellShape(well: face.win, radius: 6) } }
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressableKey())
                .help("\(s.title) app icon")
            }
        }
        if prefs.style == .orange { plateOptions.padding(.top, 4) }
    }

    /// The orange plate's display, keys and slot: each choice drawn as the icon it gives.
    var plateOptions: some View {
        VStack(alignment: .leading, spacing: 8) {
            optionRow("Display", PlateDisplay.allCases, \.display) { $0.title }
            optionRow("Keys", PlateKeys.allCases, \.keys) { $0.title }
            optionRow("Slot", PlateSlot.allCases, \.slot) { $0.title }
        }
        .padding(8)
        .background(SurfaceShape(surface: face.strip, radius: 7))
    }

    func optionRow<V: Hashable>(_ label: String, _ options: [V], _ path: WritableKeyPath<PlateLook, V>,
                                title: @escaping (V) -> String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 9.5, weight: .semibold)).tracking(1).textCase(.uppercase).foregroundStyle(face.muted)
            HStack(spacing: 4) {
                ForEach(options, id: \.self) { o in
                    let on = prefs.plate[keyPath: path] == o
                    Button { prefs.plate[keyPath: path] = o } label: {
                        VStack(spacing: 3) {
                            Image(nsImage: AppIcon.image(.orange, plate: { var l = prefs.plate; l[keyPath: path] = o; return l }(), pixels: 64))
                                .resizable().frame(width: 30, height: 30)
                            Text(title(o)).font(.system(size: 9, weight: on ? .semibold : .regular))
                                .foregroundStyle(on ? face.text : face.muted).lineLimit(1).fixedSize()
                        }
                        .padding(.horizontal, 4).padding(.vertical, 4)
                        .background { if on { WellShape(well: face.win, radius: 5) } }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PressableKey())
                    .help("\(label): \(title(o))")
                }
            }
        }
    }
}
