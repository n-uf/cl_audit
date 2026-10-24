// Status styles: tile, gauge and bar colours follow the usage levels (green under 50%, amber 50–79%,
// red from 80%, grey when the numbers are old). The big number is the 5-hour session; the week always
// gets its own colour from its own level. Same 64×64, y-down space as the other styles.

import AppKit

extension Painter {
    // Deeper level colours, so white text on them stays readable.
    static let deepGreen = TileColor.hex(0x16a34a)
    static let deepAmber = TileColor.hex(0xd97706)
    static let deepRed = TileColor.hex(0xdc2626)
    static let deepGrey = TileColor.hex(0x52525b)

    static func level(_ p: Double?, stale: Bool) -> NSColor {
        guard let p, !stale else { return deepGrey }
        return p >= 80 ? deepRed : p >= 50 ? deepAmber : deepGreen
    }

    static var tileRect: NSRect { NSRect(x: 2, y: 2, width: 60, height: 60) }

    /// The account colour where it sits on the dark tile (white when it wouldn't show).
    static func accentOnDark(_ m: TileModel) -> NSColor {
        m.tint == .usage || m.tint == .graphite ? NSColor.white.withAlphaComponent(0.85) : m.accent
    }

    static func whiteLabel(_ m: TileModel, baseline: CGFloat = 14) {
        text(m.label, mono(10), NSColor.white.withAlphaComponent(0.9), x: 32, baseline: baseline, align: .center, kern: 0.5)
    }

    static func bigNumber(_ p: Double?, baseline: CGFloat = 40.5, size: CGFloat = 25, color: NSColor = .white) {
        text(pct(p), sans(size, .heavy), color, x: 32, baseline: baseline, align: .center, fit: 50)
    }

    /// The week as a pill in its own level colour, outlined so it shows on a tile of the same colour.
    static func weekPill(_ m: TileModel) {
        let r = NSRect(x: 8, y: 45, width: 48, height: 14)
        let p = NSBezierPath(roundedRect: r, xRadius: 7, yRadius: 7)
        level(m.weekly, stale: m.stale).setFill(); p.fill()
        p.lineWidth = 1.5; NSColor.white.withAlphaComponent(0.85).setStroke(); p.stroke()
        text("wk \(pct(m.weekly))", sans(11, .bold), .white, x: 32, baseline: 56, align: .center, fit: 42)
    }

    /// A horizontal progress bar: dark track, fill length = value, fill colour = its level, optional text on top.
    static func progressBar(_ r: NSRect, _ p: Double?, stale: Bool, text t: String?, size: CGFloat = 11) {
        let radius = r.height / 2
        let shape = NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius)
        NSColor.black.withAlphaComponent(0.45).setFill(); shape.fill()
        NSGraphicsContext.saveGraphicsState()
        shape.addClip()
        let c = level(p, stale: stale)
        let filled = NSRect(x: r.minX, y: r.minY, width: r.width * CGFloat(min(p ?? 0, 100)) / 100, height: r.height)
        NSGradient(starting: c.blended(withFraction: 0.25, of: .white) ?? c, ending: c)?.draw(in: filled, angle: 0)
        NSGraphicsContext.restoreGraphicsState()
        shape.lineWidth = 1; NSColor.white.withAlphaComponent(0.8).setStroke(); shape.stroke()
        if let t { text(t, sans(size, .bold), .white, x: r.midX, baseline: r.midY + size * 0.36, align: .center, fit: r.width - 6) }
    }

    /// A vertical progress bar filling from the bottom, with its number inside.
    static func battery(_ r: NSRect, _ p: Double?, stale: Bool) {
        let shape = NSBezierPath(roundedRect: r, xRadius: 5, yRadius: 5)
        NSColor.black.withAlphaComponent(0.45).setFill(); shape.fill()
        NSGraphicsContext.saveGraphicsState()
        shape.addClip()
        let c = level(p, stale: stale)
        let h = r.height * CGFloat(min(p ?? 0, 100)) / 100
        NSGradient(starting: c.blended(withFraction: 0.25, of: .white) ?? c, ending: c)?
            .draw(in: NSRect(x: r.minX, y: r.maxY - h, width: r.width, height: h), angle: 90)
        NSGraphicsContext.restoreGraphicsState()
        shape.lineWidth = 1; NSColor.white.withAlphaComponent(0.8).setStroke(); shape.stroke()
        text(num(p), sans(13.5, .heavy), .white, x: r.midX, baseline: r.midY + 5, align: .center, fit: r.width - 4)
    }

    // 1 · Status tile: tile = 5-hour level, week pill in its own colour.
    static func statusTile(_ m: TileModel) {
        tile(level(m.fiveHour, stale: m.stale), stroke: nil)
        whiteLabel(m)
        bigNumber(m.fiveHour)
        weekPill(m)
    }

    // 3 / P5 · Gauge: a dark tile filling from the bottom (height = 5-hour %, colour = its level).
    static func gauge(_ m: TileModel, weekBar: Bool) {
        tile(tileBg, stroke: nil)
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: tileRect, xRadius: 14, yRadius: 14).addClip()
        level(m.fiveHour, stale: m.stale).withAlphaComponent(weekBar ? 0.9 : 1).setFill()
        let h = 60 * CGFloat(min(m.fiveHour ?? 0, 100)) / 100
        NSRect(x: 2, y: 62 - h, width: 60, height: h).fill()
        NSGraphicsContext.restoreGraphicsState()
        text(m.label, mono(10), accentOnDark(m), x: 32, baseline: 14, align: .center, kern: 0.5)
        bigNumber(m.fiveHour)
        if weekBar {
            progressBar(NSRect(x: 8, y: 45, width: 48, height: 14), m.weekly, stale: m.stale, text: "wk \(pct(m.weekly))")
        } else {
            weekPill(m)
        }
    }

    // 4 · Worst of two: tile = whichever limit is closer to running out.
    static func worst(_ m: TileModel) {
        let worst: Double? = (m.fiveHour == nil && m.weekly == nil) ? nil : max(m.fiveHour ?? 0, m.weekly ?? 0)
        tile(level(worst, stale: m.stale), stroke: nil)
        whiteLabel(m)
        bigNumber(m.fiveHour)
        weekPill(m)
    }

    // P1 · Status + week bar: tile = 5-hour level, the week as a progress bar.
    static func statusBar(_ m: TileModel) {
        tile(level(m.fiveHour, stale: m.stale), stroke: nil)
        whiteLabel(m)
        bigNumber(m.fiveHour)
        progressBar(NSRect(x: 8, y: 45, width: 48, height: 14), m.weekly, stale: m.stale, text: "wk \(pct(m.weekly))")
    }

    // P2 · Number + bars: 5-hour number in its level colour, two thin bars (5-hour, week) below.
    static func thinBars(_ m: TileModel) {
        tile(tileBg, stroke: nil)
        text(m.label, mono(10), accentOnDark(m), x: 32, baseline: 14, align: .center, kern: 0.5)
        let numberColor = m.stale ? grey : level(m.fiveHour, stale: false).blended(withFraction: 0.15, of: .white) ?? .white
        bigNumber(m.fiveHour, baseline: 36, size: 21, color: numberColor)
        progressBar(NSRect(x: 8, y: 41, width: 48, height: 8), m.fiveHour, stale: m.stale, text: nil)
        progressBar(NSRect(x: 8, y: 51, width: 48, height: 8), m.weekly, stale: m.stale, text: nil)
    }

    // P4 · Batteries: two vertical bars, left 5-hour, right week, number inside each.
    static func batteries(_ m: TileModel) {
        tile(tileBg, stroke: nil)
        text(m.label, mono(10), accentOnDark(m), x: 32, baseline: 14, align: .center, kern: 0.5)
        battery(NSRect(x: 8, y: 18, width: 22, height: 40), m.fiveHour, stale: m.stale)
        battery(NSRect(x: 34, y: 18, width: 22, height: 40), m.weekly, stale: m.stale)
    }
}
