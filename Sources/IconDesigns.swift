// Icon styles that match the panel designs: Twin rings, Segmented and Pace bars.
// Same 64×64, y-down space as the other styles; colours follow the levels (green, amber, red).

import AppKit

extension Painter {
    static func darkLabel(_ m: TileModel, baseline: CGFloat = 13) {
        text(m.label, mono(10), accentOnDark(m), x: 32, baseline: baseline, align: .center, kern: 0.5)
    }

    /// Twin rings: a ring per limit side by side, its number inside, "5h"/"wk" under.
    static func twinRings(_ m: TileModel) {
        tile(tileBg, stroke: nil)
        darkLabel(m)
        for (cx, p, tag) in [(CGFloat(18.5), m.fiveHour, "5h"), (CGFloat(45.5), m.weekly, "wk")] {
            let c = NSPoint(x: cx, y: 36.5), r: CGFloat = 11.5
            let base = NSBezierPath(); base.appendArc(withCenter: c, radius: r, startAngle: 0, endAngle: 360)
            base.lineWidth = 4.5; track.setStroke(); base.stroke()
            if let p, p > 0 {
                let arc = NSBezierPath()
                arc.appendArc(withCenter: c, radius: r, startAngle: -90, endAngle: -90 + 360 * CGFloat(min(p, 100)) / 100, clockwise: false)
                arc.lineWidth = 4.5; arc.lineCapStyle = .round
                let col = color(p, stale: m.stale)
                glow(col) { col.setStroke(); arc.stroke() }
            }
            text(num(p), sans(11.5, .heavy), .white, x: cx, baseline: 40.5, align: .center)
            text(tag, sans(9, .bold), faint, x: cx, baseline: 59, align: .center)
        }
    }

    /// Segmented: per limit a large number and eight segments that light up green → amber → red.
    static func segmented(_ m: TileModel) {
        tile(tileBg, stroke: nil)
        darkLabel(m)
        func row(_ top: CGFloat, _ p: Double?, _ tag: String) {
            text(tag, sans(9.5, .bold), faint, x: 7, baseline: top + 12)
            text(num(p), sans(17, .heavy), .white, x: 58, baseline: top + 13.5, align: .right)
            let count = 8, gap: CGFloat = 1.5, w: CGFloat = (50 - gap * CGFloat(count - 1)) / CGFloat(count)
            let lit = Int(((p ?? 0) / 100 * Double(count)).rounded())
            for i in 0..<count {
                let r = NSRect(x: 7 + CGFloat(i) * (w + gap), y: top + 16.5, width: w, height: 5)
                let seg = NSBezierPath(roundedRect: r, xRadius: 1.3, yRadius: 1.3)
                if i < lit && !m.stale {
                    let zone = Double(i + 1) / Double(count) * 100
                    let c = zone > 80 ? red : zone > 50 ? amber : green
                    glow(c, radius: 1.8) { c.setFill(); seg.fill() }
                } else {
                    (i < lit ? grey : track).setFill(); seg.fill()
                }
            }
        }
        row(16, m.fiveHour, "5h")
        row(38, m.weekly, "wk")
    }

    /// Pace bars: per limit a large number and a bar with a white tick for how much of the window has passed.
    static func pace(_ m: TileModel) {
        tile(tileBg, stroke: nil)
        darkLabel(m)
        func row(_ top: CGFloat, _ p: Double?, _ elapsed: Double?, _ tag: String) {
            text(tag, sans(9.5, .bold), faint, x: 7, baseline: top + 12)
            text(num(p), sans(17, .heavy), .white, x: 58, baseline: top + 13.5, align: .right)
            let r = NSRect(x: 7, y: top + 16.5, width: 50, height: 5)
            let shape = NSBezierPath(roundedRect: r, xRadius: 2.5, yRadius: 2.5)
            track.setFill(); shape.fill()
            if let p, p > 0 {
                let c = color(p, stale: m.stale)
                let w = max(5, r.width * CGFloat(min(p, 100)) / 100)
                let fill = NSBezierPath(roundedRect: NSRect(x: r.minX, y: r.minY, width: w, height: r.height), xRadius: 2.5, yRadius: 2.5)
                glow(c, radius: 2) {
                    NSGradient(starting: c.blended(withFraction: 0.25, of: .white) ?? c, ending: c)?.draw(in: fill, angle: 0)
                }
            }
            if let e = elapsed {
                let x = r.minX + r.width * CGFloat(min(max(e, 0), 100)) / 100
                let tick = NSBezierPath(roundedRect: NSRect(x: x - 1, y: r.minY - 2.5, width: 2, height: r.height + 5), xRadius: 1, yRadius: 1)
                NSColor.black.withAlphaComponent(0.6).setStroke(); tick.lineWidth = 1; tick.stroke()
                NSColor.white.setFill(); tick.fill()
            }
        }
        row(16, m.fiveHour, m.fiveHourElapsed, "5h")
        row(38, m.weekly, m.weeklyElapsed, "wk")
    }
}
