import AppKit
import CryptoKit
import Security
import ServiceManagement
import UserNotifications

// MARK: - Drawing

enum IconStyle: String, CaseIterable, Codable, Identifiable {
    var id: String { rawValue }
    // Order = order in the settings window.
    case bars, rings, twinRings, number, segmented, pace
    // Status styles: colours follow the levels; the week always has its own colour.
    case statusTile, gauge, worst, statusBar, thinBars, batteries, gaugeBar
    var title: String {
        switch self {
        case .bars: return "Two numbers"
        case .rings: return "Rings"
        case .twinRings: return "Twin rings"
        case .segmented: return "Segmented"
        case .pace: return "Pace bars"
        case .number: return "Big number"
        case .statusTile: return "Status tile"
        case .gauge: return "Gauge"
        case .worst: return "Worst of two"
        case .statusBar: return "Status + week bar"
        case .thinBars: return "Number + bars"
        case .batteries: return "Batteries"
        case .gaugeBar: return "Gauge + week bar"
        }
    }
}

/// Icon styles in three families, for the two-level picker in the settings window.
enum IconFamily: String, CaseIterable, Identifiable {
    case classic, panels, status
    var id: String { rawValue }
    var title: String {
        switch self {
        case .classic: return "Classic"
        case .panels: return "Like the panels"
        case .status: return "Status colours"
        }
    }
    var styles: [IconStyle] {
        switch self {
        case .classic: return [.bars, .rings, .number]
        case .panels: return [.twinRings, .segmented, .pace]
        case .status: return [.statusTile, .gauge, .worst, .statusBar, .thinBars, .batteries, .gaugeBar]
        }
    }
}

extension IconStyle {
    var family: IconFamily { IconFamily.allCases.first { $0.styles.contains(self) } ?? .classic }
    /// Short name for the segmented picker.
    var shortTitle: String {
        switch self {
        case .bars: return "Two numbers"
        case .rings: return "Rings"
        case .number: return "Big number"
        case .twinRings: return "Twin rings"
        case .segmented: return "Segmented"
        case .pace: return "Pace bars"
        case .statusTile: return "Tile"
        case .gauge: return "Gauge"
        case .worst: return "Worst"
        case .statusBar: return "Tile + bar"
        case .thinBars: return "Bars"
        case .batteries: return "Batteries"
        case .gaugeBar: return "Gauge + bar"
        }
    }
    var blurb: String {
        switch self {
        case .bars: return "5-hour and week as two numbers with colour markers."
        case .rings: return "Outer ring 5-hour, inner ring week, 5-hour number inside."
        case .number: return "The 5-hour % large on the account colour, the week below."
        case .twinRings: return "A ring per limit side by side, its number inside."
        case .segmented: return "Large numbers with eight segments that light up green → amber → red."
        case .pace: return "Large numbers with bars and a white tick for the time already passed."
        case .statusTile: return "The tile follows the 5-hour level; the week pill has its own colour."
        case .gauge: return "The tile fills up from the bottom with the 5-hour usage."
        case .worst: return "The tile follows whichever limit is closer to running out."
        case .statusBar: return "The tile follows the 5-hour level; the week is a progress bar."
        case .thinBars: return "The 5-hour number in its level colour, two bars below."
        case .batteries: return "Two batteries side by side: 5-hour left, week right."
        case .gaugeBar: return "The gauge fill plus the week as a progress bar."
        }
    }
}

/// The account's colour: the Big number tile, the label in Two numbers, the border in Rings.
/// `usage` colours by the 5-hour level instead (green, amber, red).
enum TileColor: String, CaseIterable, Codable, Identifiable {
    case orange, yellow, lime, teal, cyan, blue, indigo, purple, fuchsia, pink, graphite, usage
    var id: String { rawValue }
    /// The colours offered for an account, in hue order (no plain red or green: those mean usage levels).
    static let accents: [TileColor] = [.orange, .yellow, .lime, .teal, .cyan, .blue, .indigo, .purple, .fuchsia, .pink]
    var title: String { self == .usage ? "By usage" : rawValue.capitalized }

    static func hex(_ v: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255,
                blue: CGFloat(v & 0xff) / 255, alpha: 1)
    }

    /// The fixed colour; for `usage`, the colour of the given 5-hour level.
    func color(fiveHour: Double?, stale: Bool) -> NSColor {
        switch self {
        case .orange: return Painter.orange
        case .yellow: return Self.hex(0xeab308)
        case .lime: return Self.hex(0x84cc16)
        case .cyan: return Self.hex(0x06b6d4)
        case .indigo: return Self.hex(0x6366f1)
        case .fuchsia: return Self.hex(0xd946ef)
        case .blue: return Self.hex(0x3b82f6)
        case .purple: return Self.hex(0x8b5cf6)
        case .teal: return Self.hex(0x14b8a6)
        case .pink: return Self.hex(0xec4899)
        case .graphite: return Self.hex(0x3f3f46)
        case .usage: return Painter.color(fiveHour, stale: stale)
        }
    }
}

struct TileModel {
    var label: String
    var fiveHour: Double?
    var weekly: Double?
    var stale: Bool
    var style: IconStyle
    var warn = false
    var tint: TileColor = .orange
    var frame: TileColor? = nil      // nil = no frame
    var fiveHourElapsed: Double? = nil   // % of the 5-hour window already gone (Pace bars)
    var weeklyElapsed: Double? = nil
    var windowOpen = false               // this account's Claude window is open (a dot at the top-left)

    var accent: NSColor { tint.color(fiveHour: fiveHour, stale: stale) }
}

enum Painter {
    static let green = NSColor(srgbRed: 0x22/255, green: 0xc5/255, blue: 0x5e/255, alpha: 1)
    static let amber = NSColor(srgbRed: 0xf5/255, green: 0x9e/255, blue: 0x0b/255, alpha: 1)
    static let red = NSColor(srgbRed: 0xef/255, green: 0x44/255, blue: 0x44/255, alpha: 1)
    static let grey = NSColor(srgbRed: 0x6b/255, green: 0x72/255, blue: 0x80/255, alpha: 1)
    static let tileBg = NSColor(srgbRed: 0x1c/255, green: 0x1c/255, blue: 0x1f/255, alpha: 1)
    static let track = NSColor(srgbRed: 0x3f/255, green: 0x3f/255, blue: 0x46/255, alpha: 1)
    static let orange = NSColor(srgbRed: 0xd9/255, green: 0x77/255, blue: 0x57/255, alpha: 1)
    static let faint = NSColor(srgbRed: 0x9c/255, green: 0xa3/255, blue: 0xaf/255, alpha: 1)

    static func color(_ p: Double?, stale: Bool) -> NSColor {
        guard let p, !stale else { return grey }
        return p >= 80 ? red : p >= 50 ? amber : green
    }

    static func pct(_ p: Double?) -> String { p.map { "\(Int($0.rounded()))%" } ?? "–" }

    /// Draws in a 64×64, y-down space (the context must be flipped), scaled to fit `rect`.
    static func draw(_ m: TileModel, in rect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let s = min(rect.width, rect.height) / 64
        ctx.saveGState()
        ctx.translateBy(x: rect.minX + (rect.width - 64 * s) / 2, y: rect.minY + (rect.height - 64 * s) / 2)
        ctx.scaleBy(x: s, y: s)
        unit = s
        switch m.style {
        case .bars: bars(m)
        case .rings: rings(m)
        case .twinRings: twinRings(m)
        case .segmented: segmented(m)
        case .pace: pace(m)
        case .number: number(m)
        case .statusTile: statusTile(m)
        case .gauge: gauge(m, weekBar: false)
        case .worst: worst(m)
        case .statusBar: statusBar(m)
        case .thinBars: thinBars(m)
        case .batteries: batteries(m)
        case .gaugeBar: gauge(m, weekBar: true)
        }
        if let f = m.frame {
            let p = NSBezierPath(roundedRect: NSRect(x: 3.25, y: 3.25, width: 57.5, height: 57.5), xRadius: 12.8, yRadius: 12.8)
            p.lineWidth = 2.5
            f.color(fiveHour: m.fiveHour, stale: m.stale).setStroke()
            p.stroke()
        }
        if m.windowOpen {
            // A small Claude-orange dot on a dark ring, overlapping the top-left corner like the "!" on the right.
            tileBg.setFill(); NSBezierPath(ovalIn: NSRect(x: 2, y: 2, width: 15, height: 15)).fill()
            TileColor.orange.color(fiveHour: nil, stale: false).setFill()
            NSBezierPath(ovalIn: NSRect(x: 4.5, y: 4.5, width: 10, height: 10)).fill()
        }
        if m.warn {
            red.setFill()
            NSBezierPath(ovalIn: NSRect(x: 46, y: 4, width: 14, height: 14)).fill()
            text("!", sans(11, .heavy), .white, x: 53, baseline: 15.5, align: .center)
        }
        ctx.restoreGState()
    }

    /// The tile, with a soft top-to-bottom gradient of its colour.
    static func tile(_ fill: NSColor, stroke: NSColor?, width: CGFloat = 1) {
        let p = NSBezierPath(roundedRect: NSRect(x: 2, y: 2, width: 60, height: 60), xRadius: 14, yRadius: 14)
        let top = fill.blended(withFraction: fill == tileBg ? 0.07 : 0.16, of: .white) ?? fill
        let bottom = fill.blended(withFraction: fill == tileBg ? 0.35 : 0.12, of: .black) ?? fill
        NSGradient(starting: top, ending: bottom)?.draw(in: p, angle: 90) ?? { fill.setFill(); p.fill() }()
        // A hairline highlight along the top edge.
        NSGraphicsContext.saveGraphicsState()
        p.addClip()
        NSColor.white.withAlphaComponent(0.12).setStroke()
        let edge = NSBezierPath(roundedRect: NSRect(x: 2, y: 2.6, width: 60, height: 60), xRadius: 14, yRadius: 14)
        edge.lineWidth = 1.2; edge.stroke()
        NSGraphicsContext.restoreGraphicsState()
        if let stroke { stroke.setStroke(); p.lineWidth = width; p.stroke() }
    }

    enum Align { case left, center, right }

    static func text(_ s: String, _ font: NSFont, _ color: NSColor, x: CGFloat, baseline: CGFloat,
                     align: Align = .left, kern: CGFloat = 0) {
        let a = NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color, .kern: kern])
        let w = a.size().width
        let left = align == .left ? x : align == .center ? x - w / 2 : x - w
        a.draw(at: NSPoint(x: left, y: baseline - font.ascender))
    }

    static func mono(_ size: CGFloat) -> NSFont { .monospacedSystemFont(ofSize: size, weight: .bold) }
    /// SF Pro Rounded, like the panels.
    static func sans(_ size: CGFloat, _ w: NSFont.Weight) -> NSFont {
        let f = NSFont.systemFont(ofSize: size, weight: w)
        guard let d = f.fontDescriptor.withDesign(.rounded), let r = NSFont(descriptor: d, size: size) else { return f }
        return r
    }

    /// Drawing scale (pixels per unit) of the icon being drawn, for glows that must scale with it.
    static var unit: CGFloat = 1

    /// Runs `draw` with a soft glow in `color`, like the panels' bars and rings.
    static func glow(_ color: NSColor, radius: CGFloat = 2.5, _ draw: () -> Void) {
        NSGraphicsContext.saveGraphicsState()
        let sh = NSShadow()
        sh.shadowColor = color.withAlphaComponent(0.6)
        sh.shadowBlurRadius = radius * unit
        sh.shadowOffset = .zero
        sh.set()
        draw()
        NSGraphicsContext.restoreGraphicsState()
    }

    // The Dock is often small (around 40 points), so every style keeps text at 10+ units of 64
    // and shows the numbers without decimals.

    static func num(_ p: Double?) -> String { p.map { "\(Int($0.rounded()))" } ?? "–" }

    /// Two numbers: 5-hour on top, weekly below, each with a colour pill for its level.
    static func bars(_ m: TileModel) {
        tile(tileBg, stroke: nil)
        let labelColor = m.tint == .graphite || m.tint == .usage ? NSColor.white.withAlphaComponent(0.85) : m.accent
        text(m.label, mono(10), labelColor, x: 32, baseline: 13.5, align: .center, kern: 0.5)
        func row(_ top: CGFloat, _ p: Double?, _ tag: String) {
            let c = color(p, stale: m.stale)
            glow(c) { c.setFill(); NSBezierPath(roundedRect: NSRect(x: 7, y: top, width: 6, height: 19), xRadius: 3, yRadius: 3).fill() }
            if (p ?? 0) < 99.5 { text(tag, sans(9.5, .bold), faint, x: 15.5, baseline: top + 17) }  // "100" needs the room
            text(num(p), sans(19.5, .heavy), .white, x: 58, baseline: top + 18, align: .right)
        }
        row(18, m.fiveHour, "5h")
        row(40, m.weekly, "wk")
    }

    /// Rings: outer ring for the 5-hour session, inner ring for the week, 5-hour number inside.
    static func rings(_ m: TileModel) {
        tile(tileBg, stroke: nil)
        func ring(_ r: CGFloat, _ p: Double?) {
            let c = NSPoint(x: 32, y: 32)
            let base = NSBezierPath(); base.appendArc(withCenter: c, radius: r, startAngle: 0, endAngle: 360)
            base.lineWidth = 6; track.setStroke(); base.stroke()
            guard let p, p > 0 else { return }
            let arc = NSBezierPath()
            arc.appendArc(withCenter: c, radius: r, startAngle: -90, endAngle: -90 + 360 * CGFloat(min(p, 100)) / 100, clockwise: false)
            arc.lineWidth = 6; arc.lineCapStyle = .round
            let col = color(p, stale: m.stale)
            glow(col) { col.setStroke(); arc.stroke() }
        }
        ring(24, m.fiveHour)
        ring(15.5, m.weekly)
        text(num(m.fiveHour), sans(15, .heavy), .white, x: 32, baseline: 37.5, align: .center)
    }

    /// Big number: the 5-hour % large on Claude orange, the weekly % in a pill below.
    static func number(_ m: TileModel) {
        tile(m.stale ? NSColor(srgbRed: 0x52/255, green: 0x52/255, blue: 0x5b/255, alpha: 1) : m.accent, stroke: nil)
        text(m.label, mono(10), NSColor.white.withAlphaComponent(0.9), x: 32, baseline: 14, align: .center, kern: 0.5)
        text(pct(m.fiveHour), sans(25, .heavy), .white, x: 32, baseline: 40.5, align: .center)
        NSColor.black.withAlphaComponent(0.25).setFill()
        NSBezierPath(roundedRect: NSRect(x: 8, y: 45, width: 48, height: 14), xRadius: 7, yRadius: 7).fill()
        text("wk \(pct(m.weekly))", sans(11, .bold), .white, x: 32, baseline: 56, align: .center)
    }

    static func image(_ m: TileModel, pixels: Int) -> NSImage {
        let size = NSSize(width: pixels, height: pixels)
        return NSImage(size: size, flipped: true) { r in draw(m, in: r); return true }
    }

    static func png(_ m: TileModel, pixels px: Int) -> Data? {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image(m, pixels: px).draw(in: NSRect(x: 0, y: 0, width: px, height: px))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }

    /// The static icon (shown while the app isn't running), as an .iconset folder for iconutil.
    static func writeIconset(label: String, tint: TileColor = .orange, frame: TileColor? = nil, to dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let m = TileModel(label: label, fiveHour: nil, weekly: nil, stale: true, style: .bars, tint: tint, frame: frame)
        for base in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
                try? png(m, pixels: base * scale)?.write(to: dir.appendingPathComponent(name))
            }
        }
    }
}

final class TileView: NSView {
    var model: TileModel { didSet { needsDisplay = true } }
    init(model: TileModel) { self.model = model; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) { Painter.draw(model, in: bounds) }
}

