// Faces: the window's front-panel faceplates, as on the home site (Settings ▸ General ▸ Face).
//   Std     a dark brushed chassis, graphite modules, gunmetal keys, cyan display windows
//   Black   the same parts on a black anodised plate with a horizontal hairline; chamfered modules, sunken key strips
//   Silver  a light brushed silver plate with dark printing, silver keys, white-lit display windows; the window
//           takes the Mac's light appearance
// Views read the chosen face from the environment (`\.face`). The Dock icons and their panels keep their own look.

import AppKit
import SwiftUI

enum Face: String, CaseIterable, Identifiable {
    case std, black, silver
    var id: String { rawValue }
    var title: String { self == .std ? "Std" : self == .black ? "Black" : "Silver" }
    var isLight: Bool { self == .silver }
    var appearance: NSAppearance? { NSAppearance(named: isLight ? .aqua : .darkAqua) }
    var theme: FaceTheme { FaceTheme.of(self) }
}

/// The chosen face, app-wide, kept with the other preferences.
final class FacePrefs: ObservableObject {
    static let shared = FacePrefs()
    private let d = UserDefaults.standard
    /// The cl_audit window, so a light face also gives it the light appearance (sheets, menus, popovers).
    weak var window: NSWindow? { didSet { apply() } }

    @Published var face: Face { didSet { d.set(face.rawValue, forKey: "face"); apply() } }

    private init() { face = Face(rawValue: d.string(forKey: "face") ?? "") ?? .std }

    func apply() { window?.appearance = face.appearance }
}

// MARK: - Tokens

extension Color {
    /// 0xRRGGBB in sRGB.
    static func hex(_ v: UInt32, _ a: Double = 1) -> Color {
        Color(.sRGB, red: Double((v >> 16) & 0xff) / 255, green: Double((v >> 8) & 0xff) / 255, blue: Double(v & 0xff) / 255, opacity: a)
    }
    static func white(_ a: Double) -> Color { Color.white.opacity(a) }
    static func black(_ a: Double) -> Color { Color.black.opacity(a) }
}

/// Fine brushing: alternating 1 pt light and dark lines.
struct GrainSpec: Hashable {
    var vertical: Bool
    var hi: Double
    var lo: Double
}

/// A raised surface: a top-to-bottom gradient, brushing, a bevel (light top edge, dark bottom edge), an outline,
/// a hard bottom edge (keys) and a drop shadow.
struct Finish {
    var stops: [Gradient.Stop]
    var grain: GrainSpec? = nil
    var hi: Color = .clear
    var lo: Color = .clear
    var ring: Color? = nil
    var edge: Color? = nil
    var shadow: Color = .clear
    var shadowRadius: CGFloat = 0
    var shadowY: CGFloat = 0

    static func stops(_ c: (UInt32, Double)...) -> [Gradient.Stop] { c.map { .init(color: .hex($0.0), location: $0.1) } }
}

/// A recess in the plate: its fill, an inner shadow, an inner outline and a light lip under it.
struct Well {
    var stops: [Gradient.Stop]
    var grain: GrainSpec? = nil
    var inner: Color = .black(0.75)
    var innerRadius: CGFloat = 1.5
    var innerY: CGFloat = 1
    var ring: Color? = nil        // inside the edge
    var outerRing: Color? = nil   // around it
    var lip: Color = .white(0.05)

    static func flat(_ c: Color) -> [Gradient.Stop] { [.init(color: c, location: 0), .init(color: c, location: 1)] }
}

enum Surface {
    case raised(Finish)
    case recessed(Well)
}

struct FaceTheme {
    let face: Face
    /// False for the default value outside the cl_audit window (the Dock icons' panels keep their own look).
    var active = true
    var light: Bool { face.isLight }

    // printing
    var text: Color
    var soft: Color
    var muted: Color
    var faint: Color
    var print: Color           // printed uppercase labels
    var rule: Color            // engraved line, dark part
    var ruleHi: Color          // and its light lip
    var link: Color
    var caution: Color
    var danger: Color
    var ok: Color
    var levelGreen: Color
    var levelAmber: Color
    var levelRed: Color

    // surfaces
    var chassis: Finish
    var module: Finish
    var moduleRadius: CGFloat
    var strip: Surface         // key strips and the profile strip
    var win: Well              // content windows inside a module
    var chart: Well
    var track: Well
    var trackLegend: Color
    var segOff: Color

    // keys
    var key: Finish
    var keyDown: Finish
    var legend: Color
    var legendShadow: Color
    var legendShadowY: CGFloat
    var pageKey: Finish
    var pageKeyDown: Finish
    var pageLegend: Color
    var primary: Finish
    var ledOff: Color

    // display windows
    var display: Well
    var displayText: Color
    var displayGlow: Bool
    var displaySheen: Bool

    // menus stay dark recesses in every face
    var menuFill: Color

    static let led = Color(.sRGB, red: 1, green: 122 / 255, blue: 61 / 255, opacity: 1)          // the orange LED / strip
    static let ledOn = Color(.sRGB, red: 74 / 255, green: 222 / 255, blue: 128 / 255, opacity: 1) // a switch that is on
    static let glow = Color(.sRGB, red: 127 / 255, green: 249 / 255, blue: 234 / 255, opacity: 1)

    static let std = FaceTheme.of(.std)

    static func of(_ face: Face) -> FaceTheme {
        let gunmetal = Finish(stops: Finish.stops((0x74746f, 0), (0x52524e, 1)), grain: GrainSpec(vertical: true, hi: 0.06, lo: 0.06),
                              hi: .white(0.28), lo: .black(0.35), ring: .hex(0x2e2e2c), edge: .hex(0x121211),
                              shadow: .black(0.45), shadowRadius: 3.5, shadowY: 3)
        var gunmetalDown = gunmetal
        gunmetalDown.stops = Finish.stops((0x6a6a65, 0), (0x4a4a46, 1)); gunmetalDown.grain = GrainSpec(vertical: true, hi: 0.05, lo: 0.06)
        gunmetalDown.hi = .white(0.2); gunmetalDown.lo = .black(0.3); gunmetalDown.shadowRadius = 2; gunmetalDown.shadowY = 2
        let anodised = Finish(stops: Finish.stops((0x3b3b3e, 0), (0x1d1d1f, 1)), grain: GrainSpec(vertical: true, hi: 0.035, lo: 0.05),
                              hi: .white(0.14), lo: .black(0.6), ring: .black, edge: .black,
                              shadow: .black(0.5), shadowRadius: 3.5, shadowY: 3)
        var anodisedDown = anodised
        anodisedDown.hi = .white(0.08); anodisedDown.shadowRadius = 2; anodisedDown.shadowY = 2
        let aluLight = Finish(stops: Finish.stops((0xe4e4e0, 0), (0xbdbdb8, 1)), grain: GrainSpec(vertical: true, hi: 0.12, lo: 0.035),
                              hi: .white(0.8), lo: .black(0.25), ring: .hex(0x1a1a1a), edge: .hex(0x111111),
                              shadow: .black(0.35), shadowRadius: 3, shadowY: 2)
        let darkWin = Well(stops: Well.flat(.black(0.27)))
        let darkDisplay = Well(stops: Finish.stops((0x030607, 0), (0x0a1113, 0.7), (0x0c1517, 1)), inner: .black(0.9), innerRadius: 1.5, innerY: 1,
                               ring: .white(0.035), outerRing: .black(0.55), lip: .white(0.07))
        let raisedStrip = Finish(stops: Finish.stops((0x3a3a3d, 0), (0x2c2c2f, 1)), grain: GrainSpec(vertical: true, hi: 0.028, lo: 0.035),
                                 hi: .white(0.1), lo: .black(0.4), ring: .hex(0x0b0b0c), shadow: .black(0.3), shadowRadius: 6, shadowY: 4)

        var t = FaceTheme(
            face: face,
            text: .hex(0xececee), soft: .hex(0xececee, 0.82), muted: .hex(0x9a9aa0), faint: .hex(0x6e6e74),
            print: .white(0.5), rule: .black(0.45), ruleHi: .white(0.035),
            link: .hex(0xe8a07f), caution: .hex(0xf59e0b), danger: .hex(0xf87171), ok: .hex(0x22c55e),
            levelGreen: Color(nsColor: Painter.green), levelAmber: Color(nsColor: Painter.amber), levelRed: Color(nsColor: Painter.red),
            chassis: Finish(stops: Finish.stops((0x232325, 0), (0x1b1b1d, 0.3), (0x19191b, 1)), grain: GrainSpec(vertical: true, hi: 0.028, lo: 0.035)),
            module: Finish(stops: Finish.stops((0x29292b, 0), (0x222224, 1)), grain: GrainSpec(vertical: true, hi: 0.028, lo: 0.035),
                           hi: .white(0.07), lo: .black(0.35), ring: .hex(0x0c0c0d), shadow: .black(0.25), shadowRadius: 6, shadowY: 4),
            moduleRadius: 10,
            strip: .raised(raisedStrip),
            win: darkWin,
            chart: Well(stops: Well.flat(.hex(0x0e1011))),
            track: Well(stops: Well.flat(.black(0.3)), inner: .black(0.7)),
            trackLegend: .hex(0x9a9aa0),
            segOff: .black(0.38),
            key: gunmetal, keyDown: gunmetalDown, legend: .hex(0xf1f1f0), legendShadow: .black(0.35), legendShadowY: -1,
            pageKey: anodised, pageKeyDown: anodisedDown, pageLegend: .hex(0xe9e9e9),
            primary: aluLight, ledOff: .hex(0x3a3532),
            display: darkDisplay, displayText: FaceTheme.glow, displayGlow: true, displaySheen: true,
            menuFill: .hex(0x121315))

        switch face {
        case .std:
            break
        case .black:
            t.print = .white(0.62)
            t.chassis = Finish(stops: Finish.stops((0x1d1d1f, 0), (0x141416, 0.4), (0x111113, 1)), grain: GrainSpec(vertical: false, hi: 0.025, lo: 0.05))
            t.module = Finish(stops: Finish.stops((0x2b2b2d, 0), (0x1e1e20, 0.6), (0x19191b, 1)), grain: GrainSpec(vertical: false, hi: 0.035, lo: 0.05),
                              hi: .white(0.14), lo: .black(0.6), ring: .hex(0x050505), shadow: .black(0.4), shadowRadius: 8, shadowY: 6)
            t.moduleRadius = 4
            t.strip = .recessed(Well(stops: Finish.stops((0x19191b, 0), (0x121214, 1)), grain: GrainSpec(vertical: false, hi: 0.03, lo: 0.05),
                                     inner: .black(0.75), innerRadius: 1.5, innerY: 1, ring: .black(0.5), lip: .white(0.07)))
            t.win = Well(stops: Well.flat(.black(0.2)), inner: .black(0.55), innerRadius: 1, innerY: 1, ring: .white(0.04), lip: .white(0.06))
            t.chart = t.win
        case .silver:
            t.text = .hex(0x1c1c1e); t.soft = .hex(0x2c2c2f); t.muted = .hex(0x46464b); t.faint = .hex(0x5e5e63)
            t.print = .hex(0x141414, 0.62); t.rule = .black(0.22); t.ruleHi = .white(0.45)
            t.link = .hex(0xa8461a); t.caution = .hex(0x8a4f00); t.danger = .hex(0xb42318); t.ok = .hex(0x11743a)
            t.levelGreen = .hex(0x13803a); t.levelAmber = .hex(0xb25f00); t.levelRed = .hex(0xc0271b)
            t.chassis = Finish(stops: Finish.stops((0xd0d2d3, 0), (0xc2c4c5, 0.45), (0xb9bbbc, 1)), grain: GrainSpec(vertical: false, hi: 0.2, lo: 0.025))
            t.module = Finish(stops: Finish.stops((0xe0e2e3, 0), (0xd0d2d3, 0.55), (0xc6c8c9, 1)), grain: GrainSpec(vertical: false, hi: 0.24, lo: 0.025),
                              hi: .white(0.95), lo: .black(0.18), ring: .black(0.32), shadow: .black(0.16), shadowRadius: 5, shadowY: 3)
            t.moduleRadius = 4
            let silverRecess = Well(stops: Finish.stops((0xa9a9a4, 0), (0xb9b9b4, 1)), grain: GrainSpec(vertical: false, hi: 0.14, lo: 0.03),
                                    inner: .black(0.35), innerRadius: 1.5, innerY: 1, ring: .black(0.12), lip: .white(0.6))
            t.strip = .recessed(silverRecess)
            t.track = silverRecess
            t.trackLegend = .hex(0x3e3e42)
            t.win = Well(stops: Finish.stops((0xf6f7f8, 0), (0xeceef0, 1)), inner: .black(0.12), innerRadius: 2.5, innerY: 3,
                         ring: .black(0.16), lip: .white(0.7))
            t.chart = t.win
            t.segOff = .black(0.11)
            let silver = Finish(stops: Finish.stops((0xededeb, 0), (0xc8c8c3, 1)), grain: GrainSpec(vertical: true, hi: 0.14, lo: 0.03),
                                hi: .white(0.95), lo: .black(0.18), ring: .hex(0x6d6d69), edge: .hex(0x4c4c49),
                                shadow: .black(0.22), shadowRadius: 3, shadowY: 3)
            var silverDown = silver
            silverDown.stops = Finish.stops((0xdadad6, 0), (0xbababa, 1)); silverDown.grain = GrainSpec(vertical: true, hi: 0.12, lo: 0.03)
            silverDown.hi = .white(0.6); silverDown.lo = .black(0.15); silverDown.shadow = .clear
            t.key = silver; t.keyDown = silverDown
            t.legend = .hex(0x232323); t.legendShadow = .white(0.55); t.legendShadowY = 1
            t.pageKey = silver; t.pageKeyDown = silverDown; t.pageLegend = .hex(0x232323)
            t.ledOff = .hex(0x8c8c88)
            t.display = Well(stops: Finish.stops((0xfbfcfc, 0), (0xeef0f1, 1)), inner: .black(0.14), innerRadius: 2, innerY: 2,
                             ring: .black(0.2), lip: .white(0.7))
            t.displayText = .hex(0x1c1e20)
            t.displayGlow = false
            t.displaySheen = false
            t.menuFill = .hex(0x141517)
        }
        return t
    }
}

private struct FaceKey: EnvironmentKey {
    static let defaultValue: FaceTheme = { var t = FaceTheme.of(.std); t.active = false; return t }()
}

extension EnvironmentValues {
    var face: FaceTheme {
        get { self[FaceKey.self] }
        set { self[FaceKey.self] = newValue }
    }
}

extension View {
    /// The chosen face for everything inside, and the matching light or dark scheme.
    func face(_ f: Face) -> some View {
        environment(\.face, f.theme).environment(\.colorScheme, f.isLight ? .light : .dark)
    }
}

// MARK: - Drawing

/// Brushing lines, tiled.
struct GrainView: View {
    let spec: GrainSpec
    private static var cache: [GrainSpec: NSImage] = [:]

    var body: some View {
        Image(nsImage: Self.image(spec)).resizable(resizingMode: .tile)
    }

    static func image(_ s: GrainSpec) -> NSImage {
        if let i = cache[s] { return i }
        let size = s.vertical ? NSSize(width: 2, height: 1) : NSSize(width: 1, height: 2)
        let img = NSImage(size: size, flipped: false) { _ in
            NSColor.white.withAlphaComponent(s.hi).setFill()
            NSRect(x: 0, y: 0, width: 1, height: 1).fill()
            NSColor.black.withAlphaComponent(s.lo).setFill()
            (s.vertical ? NSRect(x: 1, y: 0, width: 1, height: 1) : NSRect(x: 0, y: 1, width: 1, height: 1)).fill()
            return true
        }
        cache[s] = img
        return img
    }
}

/// A raised plate, key or module.
struct RaisedShape: View {
    let finish: Finish
    var radius: CGFloat
    var pressed = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let outer = RoundedRectangle(cornerRadius: radius + 1, style: .continuous)
        ZStack {
            if let edge = finish.edge { outer.fill(edge).padding(-1).offset(y: pressed ? 1 : 2) }
            if let ring = finish.ring { outer.fill(ring).padding(-1) }
            shape.fill(LinearGradient(stops: finish.stops, startPoint: .top, endPoint: .bottom))
            if let g = finish.grain { GrainView(spec: g).clipShape(shape) }
            // the bevel: a light top edge and a dark bottom edge, following the corners
            shape.strokeBorder(finish.hi, lineWidth: 1)
                .mask(VStack(spacing: 0) { Rectangle().frame(height: radius + 1); Spacer(minLength: 0) })
            shape.strokeBorder(finish.lo, lineWidth: 1)
                .mask(VStack(spacing: 0) { Spacer(minLength: 0); Rectangle().frame(height: radius + 1) })
        }
        .compositingGroup()
        .shadow(color: finish.shadow, radius: finish.shadowRadius, y: finish.shadowY)
    }
}

/// A recess in the plate.
struct WellShape: View {
    let well: Well
    var radius: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        ZStack {
            shape.fill(well.lip).offset(y: 1)
            if let o = well.outerRing { RoundedRectangle(cornerRadius: radius + 1, style: .continuous).fill(o).padding(-1) }
            shape.fill(LinearGradient(stops: well.stops, startPoint: .top, endPoint: .bottom))
            if let g = well.grain { GrainView(spec: g).clipShape(shape) }
            shape.fill(Color.clear.shadow(.inner(color: well.inner, radius: well.innerRadius, y: well.innerY)))
            if let r = well.ring { shape.strokeBorder(r, lineWidth: 1) }
        }
    }
}

struct SurfaceShape: View {
    let surface: Surface
    var radius: CGFloat
    var body: some View {
        switch surface {
        case .raised(let f): RaisedShape(finish: f, radius: radius)
        case .recessed(let w): WellShape(well: w, radius: radius)
        }
    }
}

/// The orange light strip along the top edge of a latched key (or another colour: a profile's).
struct LampStrip: View {
    var color: Color = FaceTheme.led
    var body: some View {
        Capsule().fill(color).frame(height: 2)
            .shadow(color: color.opacity(0.8), radius: 1.5)
            .shadow(color: color.opacity(0.45), radius: 4)
            .padding(.horizontal, 5).padding(.top, 3)
            .frame(maxHeight: .infinity, alignment: .top)
            .allowsHitTesting(false)
    }
}

/// A small round LED.
struct LED: View {
    let color: Color
    var lit = true
    var size: CGFloat = 6
    @Environment(\.face) private var face
    var body: some View {
        Circle().fill(lit ? color : face.ledOff).frame(width: size, height: size)
            .shadow(color: lit ? color.opacity(0.85) : .clear, radius: 3)
            .overlay(Circle().fill(Color.clear.shadow(.inner(color: .black(lit ? 0 : 0.5), radius: 0.5, y: 0.5))))
    }
}

enum KeyKind { case plain, page, primary }

/// The face of a key, around any content: up, pressed, or latched (held down, its strip lit).
struct KeyLook<Content: View>: View {
    var kind: KeyKind = .plain
    var pressed = false
    var latched = false
    var lamp: Color = FaceTheme.led
    var height: CGFloat = 24
    var radius: CGFloat = 3
    var hPad: CGFloat = 10
    @ViewBuilder let content: Content
    @Environment(\.face) private var face

    var body: some View {
        let down = pressed || latched
        let finish: Finish = {
            switch kind {
            case .plain: return down ? face.keyDown : face.key
            case .page: return down ? face.pageKeyDown : face.pageKey
            case .primary: return face.primary
            }
        }()
        let legend: Color = kind == .primary ? .hex(0x232323) : kind == .page ? (latched && !face.light ? .white : face.pageLegend) : face.legend
        content
            .font(.system(size: 10, weight: .semibold))
            .tracking(1)
            .textCase(.uppercase)
            .lineLimit(1).fixedSize()
            .foregroundStyle(legend)
            .shadow(color: kind == .primary ? .clear : face.legendShadow, radius: 0, y: face.legendShadowY)
            .padding(.horizontal, hPad)
            .padding(.top, latched || kind == .primary ? 2.5 : 0)
            .frame(height: height)
            .background(RaisedShape(finish: finish, radius: radius, pressed: down))
            .overlay { if latched { LampStrip(color: lamp) } else if kind == .primary { LampStrip(color: lamp).padding(.horizontal, 1) } }
            .offset(y: down ? 1 : 0)
            .padding(.bottom, 2)      // room for the hard edge under the key
    }
}

/// A printed label on the plate: small, spaced capitals.
struct Printed: View {
    let text: String
    var size: CGFloat = 9.5
    @Environment(\.face) private var face
    var body: some View {
        Text(text).font(.system(size: size, weight: .semibold)).tracking(size * 0.16).textCase(.uppercase)
            .foregroundStyle(face.print).lineLimit(1).fixedSize()
    }
}

/// An engraved line: a dark line with a light lip under it.
struct EngravedRule: View {
    var dark: Color? = nil
    @Environment(\.face) private var face
    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(dark ?? face.rule).frame(height: 1)
            Rectangle().fill(face.ruleHi).frame(height: 1)
        }
        .frame(height: 2)
    }
}

/// A display window: recessed glass with glowing monospaced capitals (on Silver, lit white with dark printing).
struct DisplayWindow: View {
    let text: String
    var dim: String? = nil
    var tone: Tone = .normal
    var height: CGFloat = 22
    var size: CGFloat = 10
    @Environment(\.face) private var face

    enum Tone { case normal, amber, ok, warn }

    var body: some View {
        let color: Color = {
            switch tone {
            case .normal: return face.displayText
            case .amber: return face.light ? .hex(0xa85f00) : .hex(0xffb24a)
            case .ok: return face.light ? .hex(0x11743a) : FaceTheme.ledOn
            case .warn: return face.light ? .hex(0xb42318) : .hex(0xff8a7a)
            }
        }()
        HStack(spacing: 7) {
            Text(text).foregroundStyle(color)
                .shadow(color: face.displayGlow ? color.opacity(0.75) : .clear, radius: 1.5)
                .shadow(color: face.displayGlow ? color.opacity(0.35) : .clear, radius: 4.5)
            if let dim { Text(dim).foregroundStyle(color.opacity(face.light ? 0.45 : 0.4)) }
        }
        .font(.system(size: size, weight: .semibold, design: .monospaced))
        .tracking(size * 0.14)
        .textCase(.uppercase)
        .lineLimit(1).fixedSize()
        .padding(.horizontal, 9)
        .frame(height: height)
        .background(DisplayGlass(radius: 4))
    }
}

/// The glass of a display window, for other content too.
struct DisplayGlass: View {
    var radius: CGFloat = 4
    @Environment(\.face) private var face
    var body: some View {
        WellShape(well: face.display, radius: radius)
            .overlay {
                if face.displaySheen {
                    LinearGradient(colors: [.white(0.07), .clear], startPoint: .top, endPoint: .bottom)
                        .mask(VStack(spacing: 0) { Rectangle().frame(maxHeight: .infinity); Color.clear.frame(maxHeight: .infinity) })
                        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                        .allowsHitTesting(false)
                }
            }
    }
}

/// The on/off switch: a small key with an LED, latched down with the LED green while on.
struct LEDSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        LEDSwitchKey(on: configuration.isOn) { configuration.isOn.toggle() }
    }
}

struct LEDSwitchKey: View {
    let on: Bool
    var blinking = false
    let action: () -> Void
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: action) {
            KeyLook(pressed: on, height: 22, radius: 4, hPad: 0) {
                Group {
                    if blinking {
                        TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
                            LED(color: FaceTheme.ledOn, lit: Int(ctx.date.timeIntervalSinceReferenceDate * 2) % 2 == 0)
                        }
                    } else {
                        LED(color: FaceTheme.ledOn, lit: on)
                    }
                }
                .frame(width: 30)
            }
        }
        .buttonStyle(.plain)
        .opacity(enabled ? 1 : 0.45)
        .accessibilityValue(on ? "on" : "off")
    }
}

/// A menu's button: a dark recess with the value and small arrows; the list that opens is macOS's own.
struct MenuWell: View {
    let text: String
    var mono = false
    @Environment(\.face) private var face
    var body: some View {
        HStack(spacing: 7) {
            Text(text).font(mono ? .system(size: 11.5, design: .monospaced) : .system(size: 12)).lineLimit(1)
            Image(systemName: "chevron.up.chevron.down").font(.system(size: 7.5, weight: .semibold)).opacity(0.8)
        }
        .foregroundStyle(Color.hex(0xececee))
        .padding(.leading, 9).padding(.trailing, 8)
        .frame(height: 22)
        .background(WellShape(well: Well(stops: Well.flat(face.menuFill), inner: .black(0.75), lip: face.light ? .white(0.6) : .white(0.05)), radius: 4))
        .contentShape(Rectangle())
    }
}

extension View {
    /// A Menu drawn with a MenuWell (or another custom) label.
    func faceMenu() -> some View { menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize() }

    /// A module: the raised plate of a card.
    func module(padding: CGFloat = 14) -> some View { modifier(ModuleBackground(pad: padding)) }

    /// A content window: a recess in a module.
    func faceWindow(radius: CGFloat = 6, chart: Bool = false) -> some View { modifier(WindowBackground(radius: radius, chart: chart)) }
}

private struct ModuleBackground: ViewModifier {
    let pad: CGFloat
    @Environment(\.face) private var face
    func body(content: Content) -> some View {
        content.padding(pad).background(RaisedShape(finish: face.module, radius: face.moduleRadius))
    }
}

private struct WindowBackground: ViewModifier {
    let radius: CGFloat
    let chart: Bool
    @Environment(\.face) private var face
    func body(content: Content) -> some View {
        content.background(WellShape(well: chart ? face.chart : face.win, radius: radius))
    }
}

/// The window's chassis, filling it under the title bar.
struct ChassisBackground: View {
    @Environment(\.face) private var face
    var body: some View {
        ZStack {
            LinearGradient(stops: face.chassis.stops, startPoint: .top, endPoint: .bottom)
            if let g = face.chassis.grain { GrainView(spec: g) }
        }
        .ignoresSafeArea()
    }
}

// MARK: - Page keys and the face picture

/// Dashboard / Settings: black anodised keys (silver on Silver), the current page latched with the orange strip.
struct PageKeys<Value: Hashable>: View {
    let options: [Value]
    @Binding var selection: Value
    let title: (Value) -> String

    var body: some View {
        HStack(spacing: 6) {
            ForEach(options, id: \.self) { o in
                Button { selection = o } label: {
                    KeyLook(kind: .page, latched: o == selection, height: 28, hPad: 13) { Text(title(o)) }
                }
                .buttonStyle(PressableKey())
            }
        }
    }
}

/// A plain button whose label draws its own key; it only adds the hand cursor area.
struct PressableKey: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.brightness(configuration.isPressed ? -0.04 : 0).contentShape(Rectangle())
    }
}

/// A small picture of a face: its chassis, a key, a display window and a meter.
struct FacePicture: View {
    let face: Face
    var body: some View {
        let t = face.theme
        ZStack(alignment: .topLeading) {
            RaisedShape(finish: Finish(stops: t.module.stops, grain: t.module.grain, hi: t.module.hi, lo: t.module.lo, ring: t.module.ring), radius: 4)
            HStack(spacing: 6) {
                RaisedShape(finish: t.key, radius: 2).frame(width: 30, height: 11)
                DisplayGlass(radius: 2).frame(height: 11)
            }
            .padding(.horizontal, 8).padding(.top, 8)
            HStack(spacing: 2) {
                ForEach(0..<10, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 1).fill(i < 5 ? t.levelGreen : i < 6 ? t.levelAmber : t.segOff)
                }
            }
            .frame(height: 5).padding(.horizontal, 8).frame(maxHeight: .infinity, alignment: .bottom).padding(.bottom, 8)
        }
        .frame(height: 44)
        .environment(\.face, t)
    }
}

/// Settings ▸ General ▸ Face: a picture of each face over its key; the chosen one latched.
struct FacePicker: View {
    @ObservedObject private var prefs = FacePrefs.shared
    @Environment(\.face) private var face

    var body: some View {
        HStack(spacing: 8) {
            ForEach(Face.allCases) { f in
                let on = prefs.face == f
                Button { prefs.face = f } label: {
                    VStack(spacing: 7) {
                        FacePicture(face: f)
                        KeyLook(kind: .page, latched: on, height: 22, hPad: 12) { Text(f.title) }
                    }
                    .padding(.horizontal, 7).padding(.top, 7).padding(.bottom, 4)
                    .background { if on { WellShape(well: face.win, radius: 6) } }
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressableKey())
                .help(f == .silver ? "Silver: a light face; the window takes the Mac's light appearance" : "\(f.title) face")
            }
        }
    }
}

/// A radio choice's mark: a small LED, lit orange when chosen.
struct LEDRadio: View {
    let on: Bool
    var body: some View { LED(color: FaceTheme.led, lit: on, size: 7).frame(width: 12, height: 12) }
}

extension FaceTheme {
    /// A usage level's colour for text: Painter's, a little darker on the light Silver plate.
    func levelColor(_ p: Double?) -> Color {
        let ns = Painter.color(p, stale: false)
        guard active && light else { return Color(nsColor: ns) }
        if ns == Painter.red { return levelRed }
        if ns == Painter.amber { return levelAmber }
        if ns == Painter.green { return levelGreen }
        return Color(nsColor: ns)
    }

    /// An unlit meter segment or an empty bar: sunk into the plate (outside the window: the panels' own grey).
    var meterOff: AnyShapeStyle {
        active ? AnyShapeStyle(segOff.shadow(.inner(color: .black(light ? 0.12 : 0.5), radius: 0.6, y: 0.6)))
               : AnyShapeStyle(Color.primary.opacity(0.1))
    }
}
