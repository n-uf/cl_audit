// Style: the app's own buttons and segmented pickers, instead of macOS's blue accent controls.
// Main actions are soft pills tinted with the account's colour; everything else is neutral glass.

import SwiftUI

struct PillButtonStyle: ButtonStyle {
    var tint: Color? = nil          // nil = neutral
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        PillBody(configuration: configuration, tint: tint, compact: compact)
    }

    private struct PillBody: View {
        let configuration: Configuration
        let tint: Color?
        let compact: Bool
        @State private var hover = false
        @Environment(\.isEnabled) private var enabled

        var body: some View {
            let base = tint ?? Color.primary
            configuration.label
                .font(.system(size: compact ? 11.5 : 12.5, weight: tint == nil ? .medium : .semibold))
                .lineLimit(1).fixedSize()
                .padding(.horizontal, compact ? 9 : 12).padding(.vertical, compact ? 3.5 : 5)
                .foregroundStyle(tint == nil ? Color.primary.opacity(0.9) : Color.primary)
                .background(
                    Capsule().fill(base.opacity(tint == nil ? (hover ? 0.13 : 0.08) : (hover ? 0.34 : 0.24))))
                .overlay(Capsule().stroke(base.opacity(tint == nil ? 0.10 : 0.55), lineWidth: 1))
                .scaleEffect(configuration.isPressed ? 0.97 : 1)
                .opacity(enabled ? (configuration.isPressed ? 0.85 : 1) : 0.4)
                .contentShape(Capsule())
                .onHover { hover = $0 }
                .animation(.easeOut(duration: 0.12), value: hover)
        }
    }
}

extension ButtonStyle where Self == PillButtonStyle {
    static var pill: PillButtonStyle { PillButtonStyle() }
    static func pill(_ tint: Color, compact: Bool = false) -> PillButtonStyle { PillButtonStyle(tint: tint, compact: compact) }
}

/// A segmented picker drawn as neutral pills, the selected one lifted with a soft highlight.
struct PillPicker<Value: Hashable>: View {
    let options: [Value]
    @Binding var selection: Value
    var compact = false
    let title: (Value) -> String

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { o in
                let on = o == selection
                Button { selection = o } label: {
                    Text(title(o))
                        .font(.system(size: compact ? 11 : 12, weight: on ? .semibold : .regular))
                        .lineLimit(1).fixedSize()
                        .foregroundStyle(on ? Color.primary : Color.secondary)
                        .padding(.horizontal, compact ? 7 : 11).padding(.vertical, compact ? 3 : 4)
                        .background(Capsule().fill(on ? Color.primary.opacity(0.16) : Color.clear))
                        .overlay(Capsule().stroke(on ? Color.primary.opacity(0.12) : Color.clear, lineWidth: 1))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(Capsule().fill(Color.primary.opacity(0.06)))
        .animation(.easeOut(duration: 0.15), value: selection)
    }
}
