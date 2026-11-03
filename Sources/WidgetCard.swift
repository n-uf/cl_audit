// Settings ▸ General ▸ Widget: the widget's look, built like the Dashboard cards card beside it. First how the limits
// are drawn, with the widget right under it (the real one, Widget/WidgetViews.swift, with your profiles), then the
// plate and the layout in the same strips, then switches for what it shows. Saved to usage-n-uf/widget.json, which the
// widget reads; macOS redraws the widgets on the desktop straight away.

import SwiftUI
import WidgetKit
import os

final class WidgetPrefs: ObservableObject {
    static let shared = WidgetPrefs()
    @Published private(set) var look = WidgetLook.load()

    func set(_ l: WidgetLook) {
        look = l
        do { try l.save() } catch { Logger(subsystem: "local.usage-n-uf", category: "widget").error("widget look not saved: \(error.localizedDescription, privacy: .public)") }
        WidgetCenter.shared.reloadAllTimelines()
    }
}

struct WidgetCard: View {
    @ObservedObject private var prefs = WidgetPrefs.shared
    @Environment(\.face) private var face
    @State private var profiles = AgentFiles.load()

    private func binding<V>(_ path: WritableKeyPath<WidgetLook, V>) -> Binding<V> {
        Binding(get: { prefs.look[keyPath: path] },
                set: { v in var l = prefs.look; l[keyPath: path] = v; withAnimation(.easeOut(duration: 0.15)) { prefs.set(l) } })
    }

    var body: some View {
        SCard(title: "Widget", info: "The \"Claude usage\" widget for the desktop or Notification Center: click the date in the menu bar, then Edit Widgets. It comes in three sizes; every widget uses the look set here.") {
            SRow(label: "Limits as", first: true, stacked: true) {
                // the keys and, under them, the medium widget as it will look, together in one pane
                VStack(spacing: 7) {
                    PillPicker(options: WidgetLook.Design.allCases, selection: binding(\.design), compact: true, fill: true) { $0.title }
                    ViewThatFits(in: .horizontal) {
                        preview
                        preview.scaleEffect(0.78).frame(width: 364 * 0.78, height: 170 * 0.78)
                    }
                }
                .padding(7)
                .background(SurfaceShape(surface: face.strip, radius: 7))
            }
            // under their labels, like Limits as: four and three keys don't fit beside a label in a narrow column
            SRow(label: "Look", info: "System: the Mac's own widget background, light or dark, tinted like the other widgets. Std, Black and Silver: cl_audit's faces, as in this window.", stacked: true) {
                PillPicker(options: WidgetLook.Plate.allCases, selection: binding(\.plate), compact: true, fill: true) { $0.title }
            }
            SRow(label: "Layout", info: WidgetLook.Layout.allCases.map { "\($0.title): \($0.blurb)" }.joined(separator: " "), stacked: true) {
                PillPicker(options: WidgetLook.Layout.allCases, selection: binding(\.layout), compact: true, fill: true) { $0.title }
            }
            SRow(label: "Reset times", info: "When each limit resets, after its name (\"in 3h 11m\", \"Fri 01:00\"), where there's room.") {
                Toggle("", isOn: binding(\.resets)).smallSwitch()
            }
            SRow(label: "Fable's limit", info: "Fable's own weekly limit, for plans that have one, in the large size.") {
                HStack(spacing: 8) {
                    Toggle("", isOn: binding(\.fable)).smallSwitch()
                    Text("large size").font(.system(size: 11.5)).foregroundStyle(face.muted)
                }
            }
            SRow(label: "Next resets", info: "The next three resets across your profiles, at the bottom of the large size when there's room.") {
                HStack(spacing: 8) {
                    Toggle("", isOn: binding(\.next)).smallSwitch()
                    Text("large size").font(.system(size: 11.5)).foregroundStyle(face.muted)
                }
            }
        }
        .onReceive(DistributedNotificationCenter.default().publisher(for: Store.changed)) { _ in profiles = AgentFiles.load() }
    }

    /// The medium widget with your profiles, on its plate, as macOS shows it.
    private var preview: some View {
        let plate = prefs.look.plate
        return WidgetContent(profiles: profiles, look: prefs.look, size: .medium)
            .padding(14)
            .frame(width: 364, height: 170)
            .background {
                if plate == .system { (face.light ? Color(white: 0.96) : Color(white: 0.16)) } else { WidgetPlate(plate: plate) }
            }
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Color.white.opacity(face.light ? 0 : 0.08)))
            .environment(\.colorScheme, plate == .silver ? .light : plate == .system ? (face.light ? .light : .dark) : .dark)
            .frame(maxWidth: .infinity)
    }
}
