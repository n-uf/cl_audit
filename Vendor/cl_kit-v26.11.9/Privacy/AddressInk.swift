// The AppKit drawing layer of AddressPrivacy: drawing an address in a view's draw(_:) or any NSGraphicsContext (a menu
// row, a Dock tile image). What is drawn blurred is the stand-in (AddressText.standIn), never the address; the address is
// drawn only while it is readable. (AddressLabel, the address in an alert, is in AddressLabel.swift.)
//
// Layout: an address is given the STAND-IN's room (`room`) and no more, whatever the address, so its length is never in a
// neighbour's position. A readable address longer than that is truncated (a tail ellipsis), a shorter one leaves room.

import AppKit
import CoreImage

/// Draws addresses in one font, for a view's `draw(_:)` (or any current graphics context): the address sharp while it is
/// readable, else the stand-in blurred (the blurred picture is made once per colour and kept, a few at most; `reset()` drops
/// them, for an appearance change).
public final class AddressInk {
    /// How far the blur reaches around the text: the pictures are this much larger on every side.
    public static let blurPad: CGFloat = 6
    /// The blur's radius on the picture's own text (a Gaussian, so it reads as a smudge and nothing more).
    public static let sigma: CGFloat = 2.4
    /// How many blurred pictures are kept (one per colour; the oldest goes first).
    public static let cacheLimit = 6

    public let font: NSFont
    public init(font: NSFont) { self.font = font }

    private var cache: [(NSColor, NSImage)] = []
    /// How many pictures are kept now.
    public var cached: Int { cache.count }

    /// The room an address is given while it is hidden: the stand-in's width in this font (never more, never less).
    public var room: CGFloat { ceil((AddressText.standIn as NSString).size(withAttributes: [.font: font]).width) }
    /// The room for an address under the setting: the stand-in's while the blur is on, whatever the address; its own width
    /// while the blur is off (there is nothing to hide then, and no reason to cut it).
    public func room(for address: String, blur: Bool) -> CGFloat {
        blur ? room : ceil((address as NSString).size(withAttributes: [.font: font]).width)
    }
    /// The height of a line of text in this font.
    public var lineHeight: CGFloat { ceil(("Ag" as NSString).size(withAttributes: [.font: font]).height) }

    /// Drops the pictures made (the colours of a dynamic appearance changed).
    public func reset() { cache = [] }

    /// Draws the address (`readable`: its own text, sharp, truncated to the room) or the stand-in (blurred) with its middle
    /// at `midY`, from `x` rightwards, or ending at `x` with `alignRight`. The colour is the caller's. Nothing is animated:
    /// what is drawn changes instantly.
    /// `blur`: the setting (true: the room is the stand-in's; false: the address's own, uncut).
    public func draw(address: String, readable: Bool, color: NSColor, x: CGFloat, midY: CGFloat, alignRight: Bool = false, blur: Bool = true) {
        let w = room(for: address, blur: blur)
        if readable {
            let style = NSMutableParagraphStyle()
            style.lineBreakMode = .byTruncatingTail
            style.alignment = alignRight ? .right : .left
            let h = lineHeight
            (address as NSString).draw(in: NSRect(x: alignRight ? x - w : x, y: midY - h / 2, width: w, height: h),
                                       withAttributes: [.font: font, .foregroundColor: color, .paragraphStyle: style])
        } else if let img = standIn(color) {
            let left = alignRight ? x - img.size.width + Self.blurPad : x - Self.blurPad
            img.draw(in: NSRect(x: left, y: midY - img.size.height / 2, width: img.size.width, height: img.size.height))
        }
    }

    /// The stand-in blurred, in a colour (made once).
    public func standIn(_ color: NSColor) -> NSImage? {
        if let hit = cache.first(where: { $0.0 == color }) { return hit.1 }
        guard let img = Self.blurred(AddressText.standIn, color: color, font: font) else { return nil }
        cache.append((color, img))
        if cache.count > Self.cacheLimit { cache.removeFirst(cache.count - Self.cacheLimit) }      // a handful of colours at most
        return img
    }

    /// Text drawn and blurred (a Gaussian blur), as a picture with `blurPad` of room on every side. Callers pass the
    /// stand-in: the blur of real text keeps what it says.
    public static func blurred(_ text: String, color: NSColor, font: NSFont) -> NSImage? {
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let s = (text as NSString).size(withAttributes: attrs)
        let size = NSSize(width: ceil(s.width) + 2 * blurPad, height: ceil(s.height) + 2 * blurPad)
        let sharp = NSImage(size: size, flipped: false) { _ in
            (text as NSString).draw(at: NSPoint(x: blurPad, y: blurPad), withAttributes: attrs)
            return true
        }
        guard let cg = sharp.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let ci = CIImage(cgImage: cg)
        let soft = ci.clampedToExtent().applyingGaussianBlur(sigma: Double(sigma)).cropped(to: ci.extent)
        let out = NSImage(size: size)
        out.addRepresentation(NSCIImageRep(ciImage: soft))
        return out
    }
}
