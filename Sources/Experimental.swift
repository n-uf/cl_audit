// Experimental: the warning every page of a flow that moves sessions or accounts carries first (account switching, import,
// restoring a backup, export and Move to another Mac, making the default profile). Those flows are still unstable and can
// lose data; they are here to help with testing only. Always shown, never dismissed, and it changes nothing they do.

import SwiftUI

/// The amber caution panel at the top of such a page: the warning triangle, the title in bold, the body muted.
struct ExperimentalPanel: View {
    /// The flow, as the body's first words: "Account switching", "Export and Move to another Mac".
    let flow: String
    /// The flow names more than one thing ("… are still unstable").
    var plural = false
    @Environment(\.face) private var face

    static let title = "Experimental: may lose data"
    static func body(_ flow: String, plural: Bool = false) -> String {
        "\(flow) \(plural ? "are" : "is") still unstable and can lose data. Don't use it on anything you can't afford to lose. It's here to help with testing only."
    }

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 13)).foregroundStyle(face.caution)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(Self.title).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(face.text)
                Text(Self.body(flow, plural: plural)).font(.system(size: 11.5)).foregroundStyle(face.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(face.caution.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(face.caution.opacity(0.45), lineWidth: 1))
        .accessibilityElement(children: .combine)
    }
}
