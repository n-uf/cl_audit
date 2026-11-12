// Experimental: the warning every page of a flow that moves sessions or accounts carries first (account switching, import,
// restoring a backup, export and Move to another Mac, making the default profile). Those flows are still unstable and can
// lose data; they are here to help with testing only. Always shown, never dismissed, and it changes nothing they do.
// Each flow's final button opens a consent sheet first (ExperimentalConsent): Cancel leaves everything as it was; Continue,
// with its box ticked, appends one line to consent.log in cl_audit's own folder and then starts the run as before.

import AppKit
import os
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

// MARK: consent before it runs

/// A risky run waiting for consent: the flow's final button makes one instead of starting, and the run starts only from
/// Continue on the consent sheet (with its box ticked). Asked every time; nothing is remembered.
struct ConsentRequest: Identifiable {
    let id = UUID()
    let flow: String
    var plural = false
    let run: () -> Void

    init(flow: String, plural: Bool = false, run: @escaping () -> Void) { self.flow = flow; self.plural = plural; self.run = run }

    /// Continue: only with the box ticked. The line goes into consent.log first, then the run starts (its own start path,
    /// as the button had it). Returns whether it ran.
    @discardableResult
    func proceed(understood: Bool, now: Date = Date()) -> Bool {
        guard understood else { return false }
        ConsentLog.accepted(flow, now: now)
        run()
        return true
    }
}

/// consent.log in cl_audit's own folder (Store.folder): one line per Continue, "<UTC date>\t<flow>\t<version>\taccepted".
/// No address, account id or path. Owner-only (0600), appended, never through a link (O_NOFOLLOW) and only into a plain
/// file of this user's.
enum ConsentLog {
    static var url: URL { Store.folder.appendingPathComponent("consent.log") }

    static func line(_ flow: String, now: Date = Date(), version: String = Store.version) -> String {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]
        // the flow is one of the app's own names; tabs and line breaks can't come in
        let clean = flow.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ")
        return "\(f.string(from: now))\t\(clean)\t\(version)\taccepted\n"
    }

    static func accepted(_ flow: String, now: Date = Date()) {
        let fm = FileManager.default
        try? fm.createDirectory(at: Store.folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let fd = Darwin.open(url.path, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { Logger(subsystem: "local.usage-n-uf", category: "consent").error("consent.log not written: \(errno, privacy: .public)"); return }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_uid == getuid() else { return }
        _ = fchmod(fd, 0o600)
        let data = Array(line(flow, now: now).utf8)
        _ = data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
    }
}

/// The sheet before a risky run: what can go wrong, the licence's No Liability, a box to tick, Cancel (Return and Esc) and
/// Continue (only with the box ticked).
struct ExperimentalConsent: View {
    let flow: String
    var plural = false
    let onCancel: () -> Void
    let onContinue: () -> Void
    @State var understood = false
    @Environment(\.face) private var face

    static let title = "Experimental feature: risk of data loss"
    static let license = URL(string: "https://github.com/n-uf/cl_audit/blob/main/LICENSE")!
    static let box = "I understand the risk and use this feature at my own risk."

    static func paragraphs(_ flow: String, plural: Bool = false) -> [String] {
        [ "\(flow) \(plural ? "are" : "is") experimental. \(plural ? "They are" : "It is") still unstable and may lose or damage data, such as sessions, transcripts, settings or sign-ins, and Undo may not bring everything back.",
          "Use \(plural ? "them" : "it") only for testing, never on anything you can't afford to lose. Before you go on, make your own copy of anything you need.",
          "cl_audit is provided as is, without warranty of any kind. As far as the law allows, its authors aren't liable for any loss or damage that comes from using it (PolyForm Perimeter License 1.0.1, No Liability)." ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 15)).foregroundStyle(face.caution)
                Text(Self.title).font(.system(size: 15, weight: .semibold)).foregroundStyle(face.text)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(Self.paragraphs(flow, plural: plural), id: \.self) { p in
                Text(p).font(.system(size: 12)).foregroundStyle(face.muted).fixedSize(horizontal: false, vertical: true)
            }
            Button("Read the license") { NSWorkspace.shared.open(Self.license) }
                .buttonStyle(.link).font(.system(size: 12))
            Toggle(Self.box, isOn: $understood).toggleStyle(.checkbox).font(.system(size: 12)).foregroundStyle(face.text)
            HStack(spacing: 10) {
                Spacer()
                // Esc cancels too (a key with no face of its own)
                Button("", action: onCancel).keyboardShortcut(.cancelAction).frame(width: 0, height: 0).opacity(0).accessibilityHidden(true)
                Button("Cancel", action: onCancel).keyboardShortcut(.defaultAction)
                    .buttonStyle(PillButtonStyle(tint: nil, compact: true)).fixedSize()
                Button("Continue", action: onContinue).disabled(!understood)
                    .buttonStyle(.pill(FaceTheme.ledAmber, compact: true)).fixedSize()
            }
        }
        .padding(18)
        .background(ChassisBackground())
    }
}

extension View {
    /// The consent sheet for `request` (nil: none): Cancel drops it and nothing runs; Continue (the box ticked) logs it
    /// and runs it.
    func experimentalConsent(_ request: Binding<ConsentRequest?>, width: CGFloat = 460) -> some View {
        sheet(item: request) { r in
            ConsentSheet(request: r, width: width, close: { request.wrappedValue = nil })
                .face(FacePrefs.shared.face)
        }
    }
}

/// The sheet around the view (its box is the view's own state, off each time it opens).
private struct ConsentSheet: View {
    let request: ConsentRequest
    let width: CGFloat
    let close: () -> Void

    var body: some View {
        ExperimentalConsent(flow: request.flow, plural: request.plural,
                            onCancel: close,
                            onContinue: { close(); request.proceed(understood: true) })
            .frame(width: width)
    }
}
