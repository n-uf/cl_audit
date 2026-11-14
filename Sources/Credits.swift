// Credits: usage credits, which carry a profile on past its plan limits. Read from Anthropic's usage reply ("spend",
// or the older "extra_usage"). Shown only while they're being spent: credits are on and a plan limit is full, or the
// amount spent went up within the last hour. The agent alerts once when a profile starts spending them, and once when
// they run out.

import AppKit
import ProfileCore
import SwiftUI

// (Credits, the data and its rules, is ProfileCore's: Core/Limits.swift. cl_audit's words for it are here.)

extension Credits {
    /// "$4.20 spent", "$4.20 of $50.00 spent".
    var spentWords: String? {
        guard let used else { return nil }
        return cap.map { "\(money(used)) of \(money($0)) spent" } ?? "\(money(used)) spent"
    }

    /// "Using usage credits · $4.20 spent".
    var line: String { "Using usage credits" + (spentWords.map { " · \($0)" } ?? "") }
}

/// The line under the limits while credits are being spent.
struct CreditsLine: View {
    let credits: Credits
    @Environment(\.face) private var face
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "creditcard.fill").font(.system(size: 10.5, weight: .semibold))
            Text(credits.line).font(.system(size: 11.5, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.85)
        }
        .foregroundStyle(face.active ? face.caution : Color(nsColor: .systemOrange))
        .frame(maxWidth: .infinity, alignment: .leading)
        .help("Claude Code goes on past the plan limits with usage credits, which are paid for. Anthropic's usage page has the details.")
    }
}
