// The SwiftUI layer of AddressPrivacy, on top of AddressText and AddressPrivacy: the views that draw an address blurred
// until it is revealed.

import SwiftUI
import AppKit

/// An address that is hidden at rest and readable while the pointer is on it (or while `revealed`, when a key around it
/// carries the pointer, or a peek). What is blurred is the stand-in (AddressText.standIn), never the address; the address is
/// drawn only while it is revealed, and there is no cross-fade between the two (an instant swap: a recording must never catch
/// a half-blurred frame).
///
/// Layout: the view is as wide as the STAND-IN, whatever the address (`reserve`; false where the text flows, in a sentence,
/// where it is as wide as what it draws). A revealed address longer than that is truncated, a shorter one leaves room: its
/// length is never in a neighbour's position.
///
/// Accessibility: the view is an element of its own, labelled "hidden address" (the address itself while the blur is off);
/// what is around it stays readable.
///
/// `blur`: a test override of the setting (nil: the app's, AddressPrivacy.shared); it reaches what is drawn and what is
/// spoken. The font, weight and colour are the caller's.
public struct BlurredAddress: View {
    public let address: String
    public var size: CGFloat
    public var revealed: Bool
    public var reserve: Bool
    public var blur: Bool?
    @State private var gate = AddressHoverGate()
    @ObservedObject private var privacy = AddressPrivacy.shared

    public init(address: String, size: CGFloat = 12.5, revealed: Bool = false, reserve: Bool = true, blur: Bool? = nil) {
        self.address = address; self.size = size; self.revealed = revealed; self.reserve = reserve; self.blur = blur
    }

    /// Whether the address is blurred now: the override, or the app's setting.
    public var blurred: Bool { blur ?? privacy.blur }
    /// Whether the address is drawn readable now.
    public var readable: Bool { gate.isOn(at: privacy.hoverEnded) || revealed || !blurred }

    /// The text the view draws: the address while readable, else the stand-in (the body draws exactly this).
    public static func drawn(address: String, readable: Bool, blur: Bool) -> String {
        AddressText.drawn(address: address, revealed: readable, blur: blur)
    }
    /// What the view says to accessibility: "hidden address" while blurred, the address when the blur is off. (Never the
    /// address because of a hover: VoiceOver gets the words for the setting, not for where the pointer is.)
    public static func spoken(address: String, blur: Bool) -> String { AddressText.sentence(address: address, blur: blur) }

    /// The blur radius for a text size: none while the address is meant to be read (or the blur is turned off).
    public static func blurRadius(size: CGFloat, revealed: Bool, blur: Bool = true) -> CGFloat {
        revealed || !blur ? 0 : (size * 0.21 * 100).rounded() / 100
    }

    public var body: some View {
        let text = Text(Self.drawn(address: address, readable: readable, blur: blurred)).lineLimit(1).truncationMode(.tail)
            .blur(radius: Self.blurRadius(size: size, revealed: readable, blur: blurred))
        Group {
            if reserve && blurred {
                // the room is the stand-in's alone (nothing drawn there); the text is laid over it and truncated to it
                // (with the blur off there is nothing to hide: the address takes the room it needs)
                Text(AddressText.standIn).lineLimit(1).hidden()
                    .overlay(alignment: .leading) { text }
            } else {
                text
            }
        }
        .contentShape(Rectangle())
        .onHover { gate.pointer($0) }
        .onChange(of: privacy.hoverEnded) { gate.sync($0) }
        .onChange(of: address) { _ in gate.reset() }
        .onDisappear { gate.reset() }
        .transaction { $0.animation = nil }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.spoken(address: address, blur: blurred))
    }
}

/// The label of a key with an address in it ("Try again as <address>"): the address is hidden until the pointer is on the
/// key, and "hidden address" in the key's accessibility label. The key's own style sets the font and colour.
public struct AddressKeyLabel: View {
    public let title: String
    public let address: String
    public var size: CGFloat
    public var blur: Bool?
    @State private var gate = AddressHoverGate()
    @ObservedObject private var privacy = AddressPrivacy.shared

    public init(title: String, address: String, size: CGFloat = 11.5, blur: Bool? = nil) {
        self.title = title; self.address = address; self.size = size; self.blur = blur
    }

    public var body: some View {
        HStack(spacing: 0) {
            Text(title)
            BlurredAddress(address: address, size: size, revealed: gate.isOn(at: privacy.hoverEnded), blur: blur)
        }
        .onHover { gate.pointer($0) }
        .onChange(of: privacy.hoverEnded) { gate.sync($0) }
        .onDisappear { gate.reset() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title + BlurredAddress.spoken(address: address, blur: blur ?? privacy.blur))
    }
}
