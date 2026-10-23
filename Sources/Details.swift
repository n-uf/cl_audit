// Panels next to the Dock icon: the compact one a click shows for a few seconds, and the large one
// (double-click, ⌥-click, long press) with both limits, reset times, the login and buttons. The large
// one closes on Escape, on a click elsewhere, or on a second click. Designs: PanelDesigns.swift.

import AppKit
import SwiftUI

struct DetailsInfo {
    var name: String
    var icon: NSImage
    var login: String?
    var expected: String?
    var mismatch: Bool
    var plan: String?
    var fiveHour: Double?
    var fiveHourResets: Date?
    var weekly: Double?
    var weeklyResets: Date?
    var updated: Date?
    var source: String?
    var problem: String?
    var renewNote: String?
    var canOpenClaude: Bool
    var needsLogin: Bool
    var design: PanelDesign = .glow
    var accent: NSColor = Painter.orange
    var refreshing = false
}

struct DetailsActions {
    var openClaude: () -> Void
    var refresh: () -> Void
    var settings: () -> Void
    var logIn: () -> Void
    var close: () -> Void = {}
    var dashboard: () -> Void = {}
}

/// "Updated 4 min ago": the age of the numbers; a click fetches them again.
struct AgoButton: View {
    let date: Date?
    var source: String? = nil
    var refreshing = false
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Text(refreshing ? "Updating…" : date.map { "Updated \(DetailsFormat.ago($0))" } ?? "Not updated yet")
                .font(.system(size: 11.5)).lineLimit(1).fixedSize()
                .foregroundStyle(hover ? Color.primary : Color.secondary)
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(Capsule().fill(Color.primary.opacity(hover ? 0.07 : 0)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help("Refresh now" + (source.map { " · numbers from \($0)" } ?? ""))
    }
}

/// The ✕ in a panel's top-right corner.
struct CloseButton: View {
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark.circle.fill")
                .symbolRenderingMode(.hierarchical)
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help("Close")
    }
}

/// The large panel: double-click, ⌥-click or long press.
struct DetailsView: View {
    let info: DetailsInfo
    let actions: DetailsActions

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(nsImage: info.icon).resizable().frame(width: 52, height: 52)
                    .shadow(color: .black.opacity(0.3), radius: 4, y: 2)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Circle().fill(Color(nsColor: info.accent)).frame(width: 8, height: 8)
                        Text("Claude \(info.name)").font(.system(size: 15, weight: .semibold))
                    }
                    Text(info.login ?? "No Claude Code login").font(.caption).foregroundStyle(.secondary)
                        .hidesEmail(info.login != nil)
                    if let plan = info.plan {
                        Text(plan.capitalized + " plan").font(.caption2.weight(.medium))
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Color.primary.opacity(0.08), in: Capsule())
                    }
                }
                Spacer(minLength: 0)
                CloseButton(action: actions.close)
                    .keyboardShortcut(.cancelAction)
                    .frame(maxHeight: .infinity, alignment: .top)
            }
            .fixedSize(horizontal: false, vertical: true)

            LimitsView(limits: info.limits, design: info.design, large: true)

            if info.mismatch || info.problem != nil || info.renewNote != nil {
                VStack(alignment: .leading, spacing: 4) {
                    if info.mismatch, let want = info.expected {
                        Label(Privacy.shared.show ? "This folder is set up for \(want)" : "This folder is set up for a different account", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                    if let p = info.problem { Label(p, systemImage: "info.circle").foregroundStyle(.orange) }
                    if let n = info.renewNote { Text(n).foregroundStyle(.secondary) }
                }
                .font(.caption)
            }

            HStack(spacing: 8) {
                if info.canOpenClaude {
                    Button("Claude", action: actions.openClaude).buttonStyle(.pill(Color(nsColor: info.accent), compact: true))
                        .keyboardShortcut(.defaultAction).help("Open Claude for this account")
                }
                Button("Dashboard", action: actions.dashboard).buttonStyle(PillButtonStyle(tint: nil, compact: true))
                if info.needsLogin { Button("Log in…", action: actions.logIn).buttonStyle(.pill(.red, compact: true)) }
                Spacer(minLength: 4)
                AgoButton(date: info.updated, source: info.source, refreshing: info.refreshing, action: actions.refresh)
                Button(action: actions.settings) { Image(systemName: "gearshape") }
                    .buttonStyle(PillButtonStyle(tint: nil, compact: true)).help("Settings…")
            }
            .controlSize(.small)
        }
        .padding(16)
        .frame(width: 360)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.primary.opacity(0.12)))
    }
}

/// The compact panel a plain click shows for a few seconds while Claude opens.
struct CompactView: View {
    let info: DetailsInfo
    var onClose: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Circle().fill(Color(nsColor: info.accent)).frame(width: 8, height: 8)
                Text("Claude \(info.name)").font(.system(size: 13, weight: .semibold))
                Spacer()
                if let plan = info.plan { Text(plan.capitalized).font(.caption).foregroundStyle(.secondary) }
                if let onClose { CloseButton(action: onClose) }
            }
            LimitsView(limits: info.limits, design: info.design, large: false)
            if info.mismatch || info.problem != nil {
                Text(info.mismatch ? "Login is a different account" : info.problem ?? "")
                    .font(.caption2).foregroundStyle(.orange).lineLimit(1)
            }
        }
        .padding(14)
        .frame(width: 262)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.primary.opacity(0.12)))
    }
}

/// A bar that keeps its level colour even while the app isn't in front (system progress bars turn grey).
/// `marker` draws a white tick at that % (the pace design uses it for time elapsed).
struct LevelBar: View {
    let p: Double?
    var height: CGFloat = 6
    var glow = true
    var marker: Double? = nil

    var body: some View {
        let c = Color(nsColor: Painter.color(p, stale: false))
        let frac = CGFloat(min(max(p ?? 0, 0), 100)) / 100
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.12))
                if frac > 0 {
                    Capsule()
                        .fill(LinearGradient(colors: [c.opacity(0.7), c], startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(height, g.size.width * frac))
                        .shadow(color: glow ? c.opacity(0.5) : .clear, radius: 4)
                }
                if let m = marker {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Color.white)
                        .frame(width: 2.5, height: height + 8)
                        .shadow(color: .black.opacity(0.5), radius: 1)
                        .offset(x: g.size.width * CGFloat(min(max(m, 0), 100)) / 100 - 1.25)
                }
            }
        }
        .frame(height: height)
    }
}

enum DetailsFormat {
    /// "4 h 12 min" until the reset.
    static func short(_ d: Date) -> String {
        let m = max(0, Int(d.timeIntervalSinceNow / 60))
        return m < 60 ? "\(m) min" : m < 48 * 60 ? "\(m / 60) h \(m % 60) min" : "\(m / 1440) days"
    }

    static func ago(_ d: Date) -> String {
        let m = Int(Date().timeIntervalSince(d) / 60)
        return m < 1 ? "just now" : m < 60 ? "\(m) min ago" : "\(m / 60) h \(m % 60) min ago"
    }

    /// "in 2 h 10 min · 21:40" (or "· Mon 09:00" when it isn't today).
    static func until(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = Calendar.current.isDate(d, inSameDayAs: Date()) ? "HH:mm" : "EEE HH:mm"
        let m = max(0, Int(d.timeIntervalSinceNow / 60))
        let left = m < 60 ? "\(m) min" : m < 48 * 60 ? "\(m / 60) h \(m % 60) min" : "\(m / 1440) days"
        return "in \(left) · \(f.string(from: d))"
    }
}

/// Hosts a panel's SwiftUI content and lets the first click through: a panel that isn't the active
/// window (e.g. opened by a long press while the Dock menu has focus) would otherwise spend that click
/// on becoming active, and buttons wouldn't react.
final class PanelHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// A panel that never takes focus, so Claude can come to the front while it shows.
final class PeekPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class DetailsPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { orderOut(nil) }
}

extension DetailsController {
    /// A sample panel as a PNG, for checking the designs (`--render-panel`).
    @MainActor static func renderSample(to path: String, design: PanelDesign, large: Bool) {
        let m = TileModel(label: "MAIN", fiveHour: 24, weekly: 58, stale: false, style: .bars)
        let info = DetailsInfo(name: "main", icon: Painter.image(m, pixels: 128), login: "you@example.com", expected: nil,
                               mismatch: false, plan: "max", fiveHour: 24,
                               fiveHourResets: Date().addingTimeInterval(3 * 3600 + 57 * 60),
                               weekly: 58, weeklyResets: Date().addingTimeInterval(2 * 3600 + 7 * 60), updated: Date(),
                               source: "Anthropic", problem: nil, renewNote: nil, canOpenClaude: true, needsLogin: false,
                               design: design, accent: Painter.orange)
        let actions = DetailsActions(openClaude: {}, refresh: {}, settings: {}, logIn: {})
        let view = Group {
            if large { DetailsView(info: info, actions: actions) } else { CompactView(info: info) }
        }
        .padding(20).background(Color(white: 0.12)).environment(\.colorScheme, .dark)
        let r = ImageRenderer(content: view)
        r.scale = 2
        if let tiff = r.nsImage?.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
    }
}

final class DetailsController {
    /// Posted (to every icon app) when one of them opens a panel, so the others close theirs.
    static let panelOpened = Notification.Name("local.usage-n-uf.panel-opened")
    private let me = Bundle.main.bundleIdentifier ?? "usage"
    private var othersObserver: NSObjectProtocol?

    init() {
        othersObserver = DistributedNotificationCenter.default().addObserver(
            forName: Self.panelOpened, object: nil, queue: .main) { [weak self] note in
            guard let self, (note.object as? String) != self.me else { return }
            self.endPeek()
            if self.isShown { self.close() }
        }
    }

    private func announce() {
        DistributedNotificationCenter.default().postNotificationName(Self.panelOpened, object: me, userInfo: nil,
                                                                     deliverImmediately: true)
    }

    private var panel: DetailsPanel?
    private var closedAt = Date.distantPast
    private var observer: NSObjectProtocol?

    var isShown: Bool { panel?.isVisible == true }

    /// Opens the panel if it isn't showing (a double-click must not close it again).
    func open(_ info: DetailsInfo, _ actions: DetailsActions) {
        if !isShown { show(info, actions) }
    }

    func toggle(_ info: DetailsInfo, _ actions: DetailsActions) {
        if isShown { close(); return }
        // The click on the icon that closed the panel (by taking focus) shouldn't reopen it.
        if Date().timeIntervalSince(closedAt) < 0.4 { return }
        show(info, actions)
    }

    func close() {
        panel?.orderOut(nil)
        closedAt = Date()
        stopClickWatch()
    }

    /// For a long press: the Dock is showing its menu, so the panel comes up without taking focus
    /// (the menu has it) and closes on the next click outside it.
    func openBesideDockMenu(_ info: DetailsInfo, _ actions: DetailsActions) {
        endPeek()
        if !isShown { show(info, actions, takeFocus: false) }
    }

    // Clicks outside the panel close it, also while another app (the Dock) has focus.
    private var globalClicks: Any?
    private var localClicks: Any?

    private func startClickWatch() {
        stopClickWatch()
        let shownAt = Date()
        let outside: (NSPoint) -> Bool = { [weak self] point in
            guard let f = self?.panel?.frame else { return false }
            return !f.contains(point) && Date().timeIntervalSince(shownAt) > 0.3
        }
        globalClicks = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            if outside(NSEvent.mouseLocation) { self?.close() }
        }
        localClicks = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] e in
            if e.window !== self?.panel, outside(NSEvent.mouseLocation) { self?.close() }
            return e
        }
    }

    private func stopClickWatch() {
        if let g = globalClicks { NSEvent.removeMonitor(g); globalClicks = nil }
        if let l = localClicks { NSEvent.removeMonitor(l); localClicks = nil }
    }

    // MARK: compact peek

    private var peekPanel: PeekPanel?
    private var peekTimer: Timer?

    func peek(_ info: DetailsInfo, seconds: Double) {
        let host = PanelHostingView(rootView: CompactView(info: info, onClose: { [weak self] in self?.endPeek(animated: true) }))
        let size = host.fittingSize
        let p = peekPanel ?? PeekPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                       backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .popUpMenu
        p.hidesOnDeactivate = false          // stays up while Claude comes to the front
        p.ignoresMouseEvents = false        // its ✕ can be clicked
        p.isReleasedWhenClosed = false
        p.contentView = host
        p.setFrame(Self.frame(for: size), display: true)
        p.alphaValue = 1
        announce()
        p.orderFrontRegardless()
        peekPanel = p
        peekTimer?.invalidate()
        peekTimer = Timer.scheduledTimer(withTimeInterval: max(seconds, PeekDuration.range.lowerBound), repeats: false) { [weak self] _ in
            self?.endPeek(animated: true)
        }
    }

    func endPeek(animated: Bool = false) {
        peekTimer?.invalidate(); peekTimer = nil
        guard let p = peekPanel, p.isVisible else { return }
        if animated {
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.25; p.animator().alphaValue = 0 },
                                                 completionHandler: { p.orderOut(nil); p.alphaValue = 1 })
        } else {
            p.orderOut(nil)
        }
    }

    /// Refresh keeps the panel open; the other actions close it first.
    private func wrap(_ actions: DetailsActions) -> DetailsActions {
        DetailsActions(
            openClaude: { [weak self] in self?.close(); actions.openClaude() },
            refresh: actions.refresh,
            settings: { [weak self] in self?.close(); actions.settings() },
            logIn: { [weak self] in self?.close(); actions.logIn() },
            close: { [weak self] in self?.close() },
            dashboard: { [weak self] in self?.close(); actions.dashboard() })
    }

    /// New numbers for a panel that's open (after a refresh), without closing or moving it.
    func update(_ info: DetailsInfo, _ actions: DetailsActions) {
        guard isShown, let host = panel?.contentView as? PanelHostingView<DetailsView> else { return }
        host.rootView = DetailsView(info: info, actions: wrap(actions))
    }

    private func show(_ info: DetailsInfo, _ actions: DetailsActions, takeFocus: Bool = true) {
        let wrapped = wrap(actions)
        let host = PanelHostingView(rootView: DetailsView(info: info, actions: wrapped))
        let size = host.fittingSize

        let p = panel ?? DetailsPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                      backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .popUpMenu
        p.isReleasedWhenClosed = false
        p.contentView = host
        p.setFrame(Self.frame(for: size), display: true)
        if observer == nil {
            observer = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: p,
                                                              queue: .main) { [weak self] _ in self?.close() }
        }
        panel = p
        p.hidesOnDeactivate = false
        announce()
        startClickWatch()
        if takeFocus {
            NSApp.activate(ignoringOtherApps: true)
            p.makeKeyAndOrderFront(nil)
        } else {
            p.orderFrontRegardless()
        }
    }

    /// Next to the Dock icon that was clicked, on whichever side the Dock is.
    static func frame(for size: NSSize) -> NSRect {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
        let full = screen.frame, visible = screen.visibleFrame, gap: CGFloat = 8
        func clampX(_ x: CGFloat) -> CGFloat { min(max(x, visible.minX + gap), visible.maxX - size.width - gap) }
        func clampY(_ y: CGFloat) -> CGFloat { min(max(y, visible.minY + gap), visible.maxY - size.height - gap) }
        var origin: NSPoint
        if visible.minX > full.minX + 4 {            // Dock on the left
            origin = NSPoint(x: visible.minX + gap, y: clampY(mouse.y - size.height / 2))
        } else if visible.maxX < full.maxX - 4 {     // Dock on the right
            origin = NSPoint(x: visible.maxX - size.width - gap, y: clampY(mouse.y - size.height / 2))
        } else if visible.minY > full.minY + 4 {     // Dock at the bottom
            origin = NSPoint(x: clampX(mouse.x - size.width / 2), y: visible.minY + gap)
        } else {                                     // Dock hidden: just above the pointer
            origin = NSPoint(x: clampX(mouse.x - size.width / 2), y: min(mouse.y + 70, visible.maxY - size.height - gap))
        }
        return NSRect(origin: origin, size: size)
    }
}
