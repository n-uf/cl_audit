// The cl_audit app's own icon, unlike the profiles' Dock icons (Painter): six designs, chosen in Settings ▸ General ▸
// App icon; Front panel has its own choices (plate, display, keys, slot). The built bundle carries the default
// (plain Front panel, build.sh); the chosen icon is set while the app runs.

import AppKit
import SwiftUI

enum AppIconStyle: String, CaseIterable, Identifiable {
    case panel, stack, meter, levels, knob, monogram
    var id: String { rawValue }
    static let standard: AppIconStyle = .panel
    var title: String {
        switch self {
        case .panel: return "Front panel"
        case .stack: return "Stack"
        case .meter: return "VU meter"
        case .levels: return "Level meter"
        case .knob: return "Knob"
        case .monogram: return "Monogram"
        }
    }
}

/// Front panel's choices.
enum PanelPlate: String, CaseIterable, Identifiable {
    case grey, greyLit, orange
    var id: String { rawValue }
    var title: String { switch self { case .grey: return "Grey"; case .greyLit: return "Lit frame"; case .orange: return "Orange" } }
}
enum PanelDisplay: String, CaseIterable, Identifiable {
    case cyan, bluish, orange, levels
    var id: String { rawValue }
    var title: String { self == .levels ? "Levels" : rawValue.capitalized }
}
enum PanelKeys: String, CaseIterable, Identifiable {
    case classic, graphite, strip, round, tonal, wide
    var id: String { rawValue }
    var title: String { self == .tonal ? "Plate" : rawValue.capitalized }   // tonal: keys in the plate's own colour
}
enum PanelSlot: String, CaseIterable, Identifiable {
    case lit, light, dark
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}
/// The default is the plain Front panel: grey plate, cyan display, classic keys, lit orange slot.
struct PanelLook: Equatable {
    var plate: PanelPlate = .grey
    var display: PanelDisplay = .cyan
    var keys: PanelKeys = .classic
    var slot: PanelSlot = .lit
}

final class AppIconPrefs: ObservableObject {
    static let shared = AppIconPrefs()
    private let key = "appIconStyle"
    @Published var style: AppIconStyle { didSet { UserDefaults.standard.set(style.rawValue, forKey: key); apply() } }
    @Published var look: PanelLook {
        didSet {
            let d = UserDefaults.standard
            d.set(look.plate.rawValue, forKey: "appIconPanelPlate")
            d.set(look.display.rawValue, forKey: "appIconPanelDisplay")
            d.set(look.keys.rawValue, forKey: "appIconPanelKeys")
            d.set(look.slot.rawValue, forKey: "appIconPanelSlot")
            apply()
        }
    }
    private init() {
        let d = UserDefaults.standard
        func get<T: RawRepresentable>(_ k: String, _ fallback: T) -> T where T.RawValue == String { T(rawValue: d.string(forKey: k) ?? "") ?? fallback }
        var look = PanelLook(plate: get("appIconPanelPlate", .grey), display: get("appIconPanelDisplay", .cyan),
                             keys: get("appIconPanelKeys", .classic), slot: get("appIconPanelSlot", .lit))
        // Lit frame and Orange plate were designs of their own for a while; they are Front panel's plates now.
        let saved = d.string(forKey: key) ?? ""
        if saved == "panelLit" { look.plate = .greyLit }
        if saved == "orange" {
            look.plate = .orange
            look.display = get("appIconPlateDisplay", .cyan)
            look.keys = get("appIconPlateKeys", .strip)
            look.slot = get("appIconPlateSlot", .light)
        }
        style = saved == "panelLit" || saved == "orange" ? .panel : AppIconStyle(rawValue: saved) ?? .standard
        self.look = look
    }

    /// The Dock and the app switcher show the chosen icon while the app runs.
    func apply() { NSApp.applicationIconImage = AppIcon.image(style, look: look, pixels: 512) }
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
    static func draw(_ style: AppIconStyle, look: PanelLook = PanelLook(), in rect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let s = min(rect.width, rect.height) / 64
        ctx.saveGState()
        ctx.translateBy(x: rect.minX + (rect.width - 64 * s) / 2, y: rect.minY + (rect.height - 64 * s) / 2)
        ctx.scaleBy(x: s, y: s)
        unit = s
        switch style {
        case .panel: frontPanel(ctx, look)
        case .stack: stack(ctx)
        case .meter: meter(ctx)
        case .levels: levels(ctx)
        case .knob: knob(ctx)
        case .monogram: monogram(ctx)
        }
        ctx.restoreGState()
    }

    static func image(_ style: AppIconStyle, look: PanelLook = PanelLook(), pixels: Int) -> NSImage {
        NSImage(size: NSSize(width: pixels, height: pixels), flipped: true) { r in draw(style, look: look, in: r); return true }
    }

    static func png(_ style: AppIconStyle, look: PanelLook = PanelLook(), pixels px: Int) -> Data? {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image(style, look: look, pixels: px).draw(in: NSRect(x: 0, y: 0, width: px, height: px))
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

    /// Front panel: a piece of the site — a plate with a slot, a display with three profile levels and two keys.
    /// Its look (Settings ▸ General ▸ App icon): the plate grey, grey with a lit frame, or in the profile frame's
    /// orange; the display's colour; the keys; the slot lit orange, light grey or dark.
    static func frontPanel(_ c: CGContext, _ look: PanelLook) {
        let grey = look.plate != .orange
        let alu: [(CGFloat, NSColor)] = [(0, TileColor.hex(0xd9d9d5)), (1, TileColor.hex(0x9e9e99))]
        let line = grey ? TileColor.hex(0x222222) : TileColor.hex(0x5a2a1a)   // outlines: dark grey, or brown on orange

        // the plate: brushed gunmetal, or the orange of the profiles' frames with the tiles' soft top light
        if grey { gunPlate(c) } else {
            vfill(c, rr(2, 2, 60, 60, 14), [(0, TileColor.hex(0xdf8d72)), (0.5, Painter.orange), (1, TileColor.hex(0xbf694d))], 2, 62)
            vstroke(c, rr(2.6, 2.6, 58.8, 58.8, 13.4), 1.2, highlight, 2.6, 17.3)
        }

        // the slot: lit orange, an unlit light-grey bar set into the plate, or a dark groove
        switch look.slot {
        case .lit: slotBar(c, 18, 8, 28, 3.4)
        case .light:
            fill(c, rr(16.8, 7.1, 30.4, 5, 2.5), .black.withAlphaComponent(0.16))
            vfill(c, rr(18, 8, 28, 3.4, 1.7), [(0, TileColor.hex(0xececea)), (1, TileColor.hex(0xa7a7a3))], 8, 11.4)
        case .dark:
            vfill(c, rr(18, 8, 28, 3.4, 1.7), [(0, TileColor.hex(0x1c1c1e)), (1, TileColor.hex(0x3a3a3d))], 8, 11.4)
            fill(c, rr(18.4, 11.5, 27.2, 0.6, 0.3), .white.withAlphaComponent(0.28))
        }

        // the display
        let win = rr(8, 16, 48, 29, 4)
        vfill(c, win, glass, 16, 45)
        stroke(c, win, grey ? .black : line, 0.8)
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
        for (row, n) in lit.enumerated() { for i in n..<8 { fill(c, seg(row, i), segColor(i).withAlphaComponent(0.13)) } }
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
        case .classic:   // as on the site: light keys, the left one with an orange strip
            for x: CGFloat in [10, 34] { let k = rr(x, 49, 20, 8, 1.8); vfill(c, k, alu, 49, 57); stroke(c, k, line, 0.7) }
            if grey { slotBar(c, 14, 51, 12, 1.6, glows: false) } else { fill(c, rr(14, 51, 12, 1.6, 0.8), Painter.orange) }
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
        case .tonal:     // keys in the plate's own colour, raised
            let face: [(CGFloat, NSColor)] = grey ? [(0, TileColor.hex(0xa3a39e)), (1, TileColor.hex(0x63635f))]
                                                  : [(0, TileColor.hex(0xeda78c)), (1, TileColor.hex(0xcd7a5e))]
            for x: CGFloat in [10, 34] {
                fill(c, rr(x, 49.8, 20, 8, 2), (grey ? NSColor.black : TileColor.hex(0x7a3520)).withAlphaComponent(0.45))
                vfill(c, rr(x, 48.8, 20, 8, 2), face, 48.8, 56.8)
                fill(c, rr(x + 1, 49.3, 18, 0.5, 0.25), .white.withAlphaComponent(0.45))
            }
            ledStrip(14, 12)
        case .wide:
            fill(c, rr(10, 49.8, 44, 8, 2.2), .black.withAlphaComponent(0.22))
            vfill(c, rr(10, 48.8, 44, 8, 2.2), alu, 48.8, 56.8)
            fill(c, rr(11, 49.3, 42, 0.5, 0.25), .white.withAlphaComponent(0.8))
            ledStrip(20, 24)
        }
        if look.plate == .greyLit { litFrame(c) }
    }

    /// A frame lit like the LED strip on a pressed key, where the profiles have their colour frame.
    static func litFrame(_ c: CGContext) {
        let p = rr(3.25, 3.25, 57.5, 57.5, 12.8)
        glow(c, slotGlow, radius: 3) { stroke(c, p, slotGlow, 2.5) }
        stroke(c, p, TileColor.hex(0xffb08a), 0.9)
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

/// Settings ▸ General ▸ App icon: the designs in rows like the profiles' Icon gallery; the chosen one opens into a
/// lane under its row — Front panel's choices (each drawn as the icon it gives), or the icon at Dock sizes.
struct AppIconPicker: View {
    @ObservedObject private var prefs = AppIconPrefs.shared
    @Environment(\.face) private var face
    static let labelWidth: CGFloat = 50

    /// The six designs in one sunken row (the chosen one raised), then, in one pane, Front panel's choices as label
    /// rows, or how the chosen design looks at Dock sizes.
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 2) { ForEach(AppIconStyle.allCases, id: \.self) { tile($0) } }
                .padding(4)
                .faceWindow(radius: 6)
            lane
                .padding(.horizontal, 9).padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(SurfaceShape(surface: face.strip, radius: 7))
        }
    }

    func tile(_ s: AppIconStyle) -> some View {
        let on = prefs.style == s
        return VStack(spacing: 3) {
            Image(nsImage: AppIcon.image(s, look: prefs.look, pixels: 96)).resizable().frame(width: 36, height: 36)
            Text(s.title).font(.system(size: 9, weight: on ? .semibold : .regular)).lineLimit(1).minimumScaleFactor(0.7)
                .foregroundStyle(on ? face.text : face.muted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 5).padding(.horizontal, 1)
        .background { if on { RaisedShape(finish: face.key, radius: 5, pressed: false) } }
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(.easeOut(duration: 0.15)) { prefs.style = s } }
        .help("\(s.title) app icon")
    }

    @ViewBuilder var lane: some View {
        if prefs.style == .panel {
            VStack(alignment: .leading, spacing: 6) {
                optionRow("Plate", PanelPlate.allCases, \.plate) { $0.title }
                optionRow("Display", PanelDisplay.allCases, \.display) { $0.title }
                optionRow("Keys", PanelKeys.allCases, \.keys) { $0.title }
                optionRow("Slot", PanelSlot.allCases, \.slot) { $0.title }
            }
        } else {
            HStack(alignment: .center, spacing: 8) {
                Text("Dock sizes").font(.system(size: 11, weight: .semibold)).frame(width: Self.labelWidth + 14, alignment: .leading)
                HStack(alignment: .bottom, spacing: 12) {
                    ForEach([48, 40, 32, 24], id: \.self) { pt in
                        Image(nsImage: AppIcon.image(prefs.style, look: prefs.look, pixels: pt * 2)).resizable()
                            .frame(width: CGFloat(pt), height: CGFloat(pt))
                    }
                }
            }
        }
    }

    /// One of Front panel's choices: its label on the left, the choices after it (wrapping in a narrow column).
    func optionRow<V: Hashable>(_ label: String, _ options: [V], _ path: WritableKeyPath<PanelLook, V>,
                                title: @escaping (V) -> String) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Text(label).font(.system(size: 11, weight: .semibold)).frame(width: Self.labelWidth, alignment: .leading)
            FlowLayout(spacing: 2) {
                ForEach(options, id: \.self) { o in
                    let on = prefs.look[keyPath: path] == o
                    VStack(spacing: 2) {
                        Image(nsImage: AppIcon.image(.panel, look: { var l = prefs.look; l[keyPath: path] = o; return l }(), pixels: 56))
                            .resizable().frame(width: 26, height: 26)
                        Text(title(o)).font(.system(size: 9, weight: on ? .semibold : .regular))
                            .foregroundStyle(on ? face.text : face.muted).lineLimit(1).fixedSize()
                    }
                    .padding(.horizontal, 3).padding(.vertical, 3)
                    .background { if on { RaisedShape(finish: face.key, radius: 5, pressed: false) } }
                    .contentShape(Rectangle())
                    .onTapGesture { withAnimation(.easeOut(duration: 0.12)) { prefs.look[keyPath: path] = o } }
                    .help("\(label): \(title(o))")
                }
            }
        }
    }
}
