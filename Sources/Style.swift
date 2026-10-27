// Style: the app's own buttons and segmented pickers, drawn as front-panel parts in the chosen face (Faces.swift)
// instead of macOS's blue accent controls. A button is a key; a tinted one carries an LED in its colour; the one
// primary action (Apply) is the aluminium key with the lit orange slot. A picker is a recessed track with the
// chosen item a raised key.

import SwiftUI

struct PillButtonStyle: ButtonStyle {
    var tint: Color? = nil          // nil = plain key; a colour = an LED of that colour on the key
    var compact = false
    var primary = false

    func makeBody(configuration: Configuration) -> some View {
        KeyBody(configuration: configuration, tint: tint, compact: compact, primary: primary)
    }

    private struct KeyBody: View {
        let configuration: Configuration
        let tint: Color?
        let compact: Bool
        let primary: Bool
        @State private var hover = false
        @Environment(\.isEnabled) private var enabled

        var body: some View {
            KeyLook(kind: primary ? .primary : .plain, pressed: configuration.isPressed,
                    height: compact ? 22 : 26, radius: compact ? 3 : 4, hPad: compact ? 9 : 12) {
                HStack(spacing: 6) {
                    if let tint, !primary { LED(color: tint) }
                    configuration.label
                }
            }
            .brightness(hover && enabled ? 0.03 : 0)
            .opacity(enabled ? 1 : 0.45)
            .contentShape(Rectangle())
            .onHover { hover = $0 }
        }
    }
}

extension ButtonStyle where Self == PillButtonStyle {
    static var pill: PillButtonStyle { PillButtonStyle() }
    static func pill(_ tint: Color, compact: Bool = false) -> PillButtonStyle { PillButtonStyle(tint: tint, compact: compact) }
    /// The one primary action on a page (Apply).
    static func primaryKey(compact: Bool = false) -> PillButtonStyle { PillButtonStyle(compact: compact, primary: true) }
}

/// A segmented picker: printed choices on a recessed track, the chosen one a raised key.
struct PillPicker<Value: Hashable>: View {
    let options: [Value]
    @Binding var selection: Value
    var compact = false
    var fill = false            // stretch the choices across the width
    let title: (Value) -> String
    @Environment(\.face) private var face

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { o in
                let on = o == selection
                Button { selection = o } label: {
                    Text(title(o))
                        .font(.system(size: compact ? 9 : 9.5, weight: .semibold)).tracking(1).textCase(.uppercase)
                        .lineLimit(1).fixedSize()
                        .foregroundStyle(on ? face.legend : face.trackLegend)
                        .shadow(color: on ? face.legendShadow : .clear, radius: 0, y: face.legendShadowY)
                        .padding(.horizontal, fill ? 6 : compact ? 8 : 10)      // stretched choices share any extra width
                        .frame(maxWidth: fill ? .infinity : nil)
                        .frame(height: compact ? 20 : 22)
                        .background { if on { RaisedShape(finish: face.key, radius: 3) } }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(WellShape(well: face.track, radius: 5))
        .animation(.easeOut(duration: 0.12), value: selection)
    }
}
