// The cl_audit widget: every profile's 5-hour and weekly limits on the desktop or in Notification Center.
//
// A separate, sandboxed program (an app extension inside cl_audit.app, built by build.sh, not part of Sources/). It only
// reads what cl_audit writes: usage-n-uf/accounts.json for the profile names, status/<id>.json for the numbers and
// widget.json for its look, through one read-only sandbox exception for that folder. No Keychain, no network, no
// writing. What it draws is WidgetViews.swift, which cl_audit's Settings use as the widget's preview too.

import SwiftUI
import WidgetKit

struct UsageEntry: TimelineEntry {
    let date: Date
    let profiles: [WidgetProfile]
    let look: WidgetLook
}

struct UsageProvider: TimelineProvider {
    func placeholder(in context: Context) -> UsageEntry { UsageEntry(date: Date(), profiles: AgentFiles.demo, look: WidgetLook()) }

    func getSnapshot(in context: Context, completion: @escaping (UsageEntry) -> Void) {
        let real = AgentFiles.load()
        completion(UsageEntry(date: Date(), profiles: context.isPreview && real.isEmpty ? AgentFiles.demo : real, look: WidgetLook.load()))
    }

    /// The files as they are now; macOS asks again in about five minutes (more rarely when it saves power), and at once
    /// when cl_audit changes the look.
    func getTimeline(in context: Context, completion: @escaping (Timeline<UsageEntry>) -> Void) {
        let now = Date()
        completion(Timeline(entries: [UsageEntry(date: now, profiles: AgentFiles.load(), look: WidgetLook.load())],
                            policy: .after(now.addingTimeInterval(5 * 60))))
    }
}

struct UsageWidgetView: View {
    let entry: UsageEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        WidgetContent(profiles: entry.profiles, look: entry.look,
                      size: family == .systemSmall ? .small : family == .systemLarge ? .large : .medium, now: entry.date)
            .containerBackground(for: .widget) {
                if entry.look.plate == .system { Rectangle().fill(.background) } else { WidgetPlate(plate: entry.look.plate) }
            }
            .environment(\.colorScheme, entry.look.plate == .silver ? .light : entry.look.plate == .system ? colorSchemeOfSystem : .dark)
    }

    @Environment(\.colorScheme) private var colorSchemeOfSystem
}

struct UsageWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "local.usage-n-uf.limits", provider: UsageProvider()) { UsageWidgetView(entry: $0) }
            .configurationDisplayName("Claude usage")
            .description("Every cl_audit profile's 5-hour and weekly limits, and when a full one is back. Its look is in cl_audit ▸ Settings ▸ General ▸ Widget.")
            .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

@main
struct UsageWidgets: WidgetBundle {
    var body: some Widget { UsageWidget() }
}
