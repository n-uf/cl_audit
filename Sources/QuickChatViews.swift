// QuickChatViews: the quick chat's bar and chat window (QuickChat.swift), in Claude's own dark colours rather than
// cl_audit's front panel: it should feel like Claude. The bar is a field over one row of keys; the first message turns it
// into a chat window: the account line on top, the chat, and the field at the bottom. Answers are Markdown in a serif,
// code blocks have Copy, and each answer says which model gave it.

import AppKit
import SwiftUI

/// Claude's dark colours.
enum QCColor {
    static func hex(_ v: UInt32, _ a: Double = 1) -> Color {
        Color(.sRGB, red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255, opacity: a)
    }
    static let window = hex(0x262624)
    static let surface = hex(0x30302E)
    static let bubble = hex(0x141413)
    static let code = hex(0x1F1E1D)
    static let line = hex(0xDEDCD1, 0.16)
    static let text = hex(0xFAF9F5)
    static let soft = hex(0xC2C0B6)
    static let muted = hex(0x9C9A92)
    static let accent = hex(0xD97757)
    static let send = hex(0xC6613F)
    static let hover = hex(0xFAF9F5, 0.07)
    static let inlineCode = hex(0xF0B39A)
    static let codeText = hex(0xE8E6DC)
    static let crimson = hex(0xEB445B)
}

/// Set while drawing to a picture (`--render-quick-chat`): the field is drawn as text, the chat without a scroll view.
private struct QCRenderingKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var qcRendering: Bool {
        get { self[QCRenderingKey.self] }
        set { self[QCRenderingKey.self] = newValue }
    }
}

private struct QCSizeKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) { value = nextValue() }
}

struct QuickChatRoot: View {
    static let width: CGFloat = 520
    static let windowHeight: CGFloat = 580
    @ObservedObject var model: QuickChatModel
    var onSize: (CGSize) -> Void = { _ in }

    var body: some View {
        Group {
            if model.isWindow { QCWindow(model: model) } else { QCBar(model: model) }
        }
        .frame(width: Self.width)
        .fixedSize(horizontal: false, vertical: true)
        .background(GeometryReader { g in Color.clear.preference(key: QCSizeKey.self, value: g.size) })
        .onPreferenceChange(QCSizeKey.self) { s in DispatchQueue.main.async { onSize(s) } }
        .environment(\.colorScheme, .dark)
    }
}

// MARK: - The bar

struct QCBar: View {
    @ObservedObject var model: QuickChatModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let p = model.barProblem { QCProblemView(problem: p, model: model, answered: false) }
            QCField(model: model, placeholder: "Ask anything", size: 17)
                .padding(.horizontal, 8)
            QCControls(model: model, inBar: true)
        }
        .padding(EdgeInsets(top: 16, leading: 10, bottom: 10, trailing: 10))
        .background(RoundedRectangle(cornerRadius: 24, style: .continuous).fill(QCColor.surface.opacity(0.97)))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(QCColor.line))
    }
}

// MARK: - The chat window

struct QCWindow: View {
    @ObservedObject var model: QuickChatModel
    @Environment(\.qcRendering) private var rendering

    var body: some View {
        VStack(spacing: 0) {
            QCHeader(model: model)
            if rendering {
                VStack(alignment: .leading, spacing: 0) { turns }
                    .padding(.horizontal, 20)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .clipped()
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            turns
                            Color.clear.frame(height: 1).id("end")
                        }
                        .padding(.horizontal, 20)
                        .padding(.bottom, 12)
                    }
                    .onChange(of: model.scrollTick) { _ in proxy.scrollTo("end", anchor: .bottom) }
                    .onAppear { proxy.scrollTo("end", anchor: .bottom) }
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                QCField(model: model, placeholder: "Reply…", size: 15).padding(.horizontal, 8)
                QCControls(model: model, inBar: false)
            }
            .padding(EdgeInsets(top: 12, leading: 8, bottom: 8, trailing: 8))
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(QCColor.surface))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(QCColor.line))
            .padding([.horizontal, .bottom], 12)
        }
        .frame(height: QuickChatRoot.windowHeight)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(QCColor.window.opacity(0.98)))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(QCColor.line))
    }

    @ViewBuilder private var turns: some View {
        ForEach(Array(model.turns.enumerated()), id: \.element.id) { i, t in
            QCTurnView(turn: t, last: i == model.turns.count - 1, model: model)
        }
    }
}

/// The account line: the profile and the address of its account in use (masked unless Privacy shows addresses), then
/// New chat and Hide.
struct QCHeader: View {
    @ObservedObject var model: QuickChatModel
    @ObservedObject private var privacy = Privacy.shared

    var body: some View {
        HStack(spacing: 8) {
            if let t = model.target {
                Text(t.name).font(.system(size: 12.5, weight: .semibold)).foregroundColor(QCColor.text)
                if let e = t.email {
                    Text(Privacy.masked(e)).font(.system(size: 12)).foregroundColor(QCColor.muted).lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer(minLength: 8)
            QCIconButton(symbol: "square.and.pencil", help: "New chat") { model.newChat() }
            QCIconButton(symbol: "xmark", help: "Hide (Esc)") { model.hide() }
        }
        .padding(EdgeInsets(top: 10, leading: 18, bottom: 6, trailing: 10))
    }
}

// MARK: - One question and its answer

struct QCTurnView: View {
    let turn: QuickChatTurn
    let last: Bool
    @ObservedObject var model: QuickChatModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Spacer(minLength: 70)
                Text(turn.question)
                    .font(.system(size: 14.5))
                    .foregroundColor(QCColor.text)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(QCColor.bubble))
            }
            .padding(.top, 14)
            if !turn.answer.isEmpty {
                QCAnswer(text: turn.answer)
            }
            if turn.phase == .waiting || turn.phase == .streaming { QCPulse() }
            if turn.phase == .done || turn.phase == .stopped { footer }
            if let p = turn.problem, turn.phase == .failed {
                QCProblemView(problem: p, model: model, answered: !turn.answer.isEmpty, last: last)
            }
        }
        .padding(.bottom, 4)
    }

    private var footer: some View {
        HStack(spacing: 2) {
            QCCopyIcon(text: turn.answer)
            if last { QCIconButton(symbol: "arrow.clockwise", help: "Ask again", small: true) { model.again() } }
            Text(words).font(.system(size: 12)).foregroundColor(QCColor.muted).padding(.leading, 6)
        }
        .padding(.leading, -7)
    }

    private var words: String {
        let who = turn.model.isEmpty ? "Claude" : turn.model
        if turn.phase == .stopped { return "\(who) · stopped by you" }
        var s = "answered by \(who)"
        if let th = turn.thinkingTitle { s += ", thinking \(th.lowercased())" }
        if let sec = turn.seconds { s += " · " + QCFormat.seconds(sec) }
        return s
    }
}

enum QCFormat {
    /// 2.4 s, 12 s, 1 min 5 s.
    static func seconds(_ s: Double) -> String {
        if s < 10 { return String(format: "%.1f s", s) }
        if s < 60 { return "\(Int(s.rounded())) s" }
        let m = Int(s) / 60, r = Int(s) % 60
        return r == 0 ? "\(m) min" : "\(m) min \(r) s"
    }
}

/// An answer's Markdown, block by block (QuickChatMarkdown.swift).
struct QCAnswer: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(QuickChatMarkdown.blocks(text).enumerated()), id: \.offset) { _, b in block(b) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func block(_ b: QuickChatBlock) -> some View {
        switch b {
        case .paragraph(let s):
            prose(s)
        case .heading(let level, let s):
            Text(Self.inline(s)).font(.system(size: level <= 2 ? 17 : 15.5, weight: .semibold, design: .serif))
                .foregroundColor(QCColor.text).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
        case .bullets(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, it in
                    HStack(alignment: .firstTextBaseline, spacing: 8) { Text("•").foregroundColor(QCColor.muted); prose(it) }
                }
            }
        case .numbered(let start, let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { i, it in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(start + i).").font(.system(size: 15, design: .serif)).foregroundColor(QCColor.muted)
                        prose(it)
                    }
                }
            }
        case .quote(let s):
            prose(s).padding(.leading, 12)
                .overlay(Rectangle().fill(QCColor.line).frame(width: 2), alignment: .leading)
        case .code(let lang, let code):
            QCCodeBlock(language: lang, code: code)
        case .rule:
            Rectangle().fill(QCColor.line).frame(height: 1)
        }
    }

    private func prose(_ s: String) -> some View {
        Text(Self.inline(s))
            .font(.system(size: 15.5, design: .serif))
            .foregroundColor(QCColor.text)
            .lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }

    /// Inline Markdown, with `code` in the mono font and a warm colour.
    static func inline(_ s: String) -> AttributedString {
        var a = QuickChatMarkdown.inline(s)
        for run in a.runs where run.inlinePresentationIntent?.contains(.code) == true {
            a[run.range].font = .system(size: 13.5, design: .monospaced)
            a[run.range].foregroundColor = QCColor.inlineCode
        }
        return a
    }
}

struct QCCodeBlock: View {
    let language: String
    let code: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language.isEmpty ? "code" : language).font(.system(size: 12)).foregroundColor(QCColor.muted)
                Spacer()
                QCCopyLabel(text: code)
            }
            .padding(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 4))
            Rectangle().fill(QCColor.line).frame(height: 1)
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(size: 12.5, design: .monospaced))
                    .foregroundColor(QCColor.codeText)
                    .textSelection(.enabled)
                    .fixedSize()
                    .padding(EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12))
            }
        }
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(QCColor.code))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(QCColor.line))
    }
}

/// Claude's waiting mark: an orange dot that breathes.
struct QCPulse: View {
    @State private var on = false
    var body: some View {
        Circle().fill(QCColor.accent).frame(width: 9, height: 9)
            .opacity(on ? 1 : 0.3)
            .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: on)
            .onAppear { on = true }
    }
}

// MARK: - Why an answer didn't come

struct QCProblemView: View {
    let problem: QuickChatProblem
    @ObservedObject var model: QuickChatModel
    var answered: Bool
    var last = true

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle().fill(QCColor.crimson).frame(width: 8, height: 8).padding(.top, 5)
            VStack(alignment: .leading, spacing: 7) {
                (Text(title).fontWeight(.semibold).foregroundColor(QCColor.text) + Text(more.isEmpty ? "" : " " + more))
                    .font(.system(size: 13)).foregroundColor(QCColor.soft).fixedSize(horizontal: false, vertical: true)
                if let d = detail {
                    Text(d).font(.system(size: 11.5, design: .monospaced)).foregroundColor(QCColor.muted)
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 8) { keys }
            }
            Spacer(minLength: 0)
        }
        .padding(EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12))
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(QCColor.crimson.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(QCColor.crimson.opacity(0.38)))
    }

    private var title: String {
        switch problem {
        case .notInstalled: return ClaudeInstall.missing + "."
        case .notSignedIn(let name, _): return "\(name)'s Claude Code isn't signed in."
        case .stopped: return "Claude Code stopped before the answer was done."
        case .refused(let text): return text
        case .noProfile: return "There's no profile to chat on yet."
        }
    }

    private var more: String {
        switch problem {
        case .notInstalled: return "The quick chat answers through it."
        case .notSignedIn: return "Sign in from its settings, then try again."
        case .stopped: return answered ? "What arrived is kept above." : ""
        case .refused: return ""
        case .noProfile: return "Set one up in cl_audit."
        }
    }

    private var detail: String? {
        if case .stopped(let d) = problem { return d }
        return nil
    }

    @ViewBuilder private var keys: some View {
        switch problem {
        case .notInstalled:
            QCButton(title: "Install…") { NSWorkspace.shared.open(ClaudeInstall.docs) }
            QCButton(title: "Try again", ghost: true) { retry() }
        case .notSignedIn(_, let id):
            QCButton(title: "Open its settings") { model.openProfileSettings(id) }
            QCButton(title: "Try again", ghost: true) { retry() }
        case .stopped, .refused:
            if last { QCButton(title: "Retry") { retry() } }
        case .noProfile:
            QCButton(title: "Open cl_audit") { Installer.openDashboard() }
        }
    }

    private func retry() { if model.isWindow { model.again() } else { model.barProblem = nil; model.send() } }
}

// MARK: - The keys

/// The row under the field: the model, then the send (or stop) key.
struct QCControls: View {
    @ObservedObject var model: QuickChatModel
    var inBar: Bool

    var body: some View {
        HStack(spacing: 4) {
            QCChip(title: model.modelTitle)
            Spacer(minLength: 4)
            if model.busy {
                Button(action: model.stop) {
                    Image(systemName: "stop.fill").font(.system(size: 11, weight: .bold))
                        .frame(width: 34, height: 34).foregroundColor(QCColor.bubble)
                        .background(Circle().fill(QCColor.text))
                }
                .buttonStyle(.plain).help("Stop")
            } else {
                let empty = model.field.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                Button(action: model.send) {
                    Image(systemName: "arrow.up").font(.system(size: 14, weight: .semibold))
                        .frame(width: 34, height: 34)
                        .foregroundColor(empty ? QCColor.text.opacity(0.38) : .white)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(empty ? QCColor.text.opacity(0.1) : QCColor.send))
                }
                .buttonStyle(.plain).disabled(empty).help("Send (Return)")
            }
        }
    }
}

struct QCChip: View {
    let title: String
    var body: some View {
        Text(title).font(.system(size: 13, weight: .medium)).foregroundColor(QCColor.soft)
            .padding(.horizontal, 9).frame(height: 30)
    }
}

struct QCButton: View {
    let title: String
    var ghost = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: 12.5, weight: .semibold))
                .foregroundColor(ghost ? QCColor.text : QCColor.bubble)
                .padding(.horizontal, 12).frame(height: 28)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(ghost ? QCColor.hover : QCColor.text))
        }
        .buttonStyle(.plain)
    }
}

struct QCIconButton: View {
    let symbol: String
    let help: String
    var small = false
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: small ? 12 : 13, weight: .medium))
                .frame(width: small ? 28 : 30, height: small ? 28 : 30)
                .foregroundColor(hover ? QCColor.text : QCColor.muted)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hover ? QCColor.hover : .clear))
        }
        .buttonStyle(.plain).help(help).onHover { hover = $0 }
    }
}

/// Copy under an answer: its icon turns into a tick for a moment.
struct QCCopyIcon: View {
    let text: String
    @State private var done = false
    var body: some View {
        QCIconButton(symbol: done ? "checkmark" : "doc.on.doc", help: "Copy", small: true) {
            QCCopy.put(text); done = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { done = false }
        }
    }
}

/// Copy in a code block's header: "Copy", then "Copied" for a moment.
struct QCCopyLabel: View {
    let text: String
    @State private var done = false
    var body: some View {
        Button {
            QCCopy.put(text); done = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { done = false }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: done ? "checkmark" : "doc.on.doc").font(.system(size: 11))
                Text(done ? "Copied" : "Copy").font(.system(size: 12))
            }
            .foregroundColor(QCColor.muted).padding(.horizontal, 8).frame(height: 26)
        }
        .buttonStyle(.plain)
    }
}

enum QCCopy {
    static func put(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
}

// MARK: - The field

/// The message field: grows to six lines, Return sends, Shift-Return adds a line, Esc hides the chat.
struct QCField: View {
    @ObservedObject var model: QuickChatModel
    let placeholder: String
    let size: CGFloat
    @State private var height: CGFloat = 24
    @Environment(\.qcRendering) private var rendering

    var body: some View {
        if rendering {
            Text(model.field.isEmpty ? placeholder : model.field)
                .font(.system(size: size)).foregroundColor(model.field.isEmpty ? QCColor.muted : QCColor.text)
                .frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
        } else {
            QCTextField(text: $model.field, height: $height, placeholder: placeholder, size: size, focusTick: model.focusTick,
                        onSubmit: { model.send() }, onEscape: { model.hide() })
                .frame(height: height)
        }
    }
}

struct QCTextField: NSViewRepresentable {
    @Binding var text: String
    @Binding var height: CGFloat
    let placeholder: String
    let size: CGFloat
    let focusTick: Int
    let onSubmit: () -> Void
    let onEscape: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.borderType = .noBorder
        let tv = QCTextView()
        tv.delegate = context.coordinator
        tv.isRichText = false
        tv.allowsUndo = true
        tv.drawsBackground = false
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.textContainerInset = .zero
        tv.textContainer?.lineFragmentPadding = 0
        tv.textContainer?.widthTracksTextView = true
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.insertionPointColor = NSColor(QCColor.accent)
        scroll.documentView = tv
        context.coordinator.textView = tv
        apply(tv)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let tv = context.coordinator.textView else { return }
        if tv.string != text { tv.string = text }
        apply(tv)
        if context.coordinator.focusTick != focusTick {
            context.coordinator.focusTick = focusTick
            DispatchQueue.main.async { tv.window?.makeFirstResponder(tv) }
        }
        context.coordinator.measure()
    }

    private func apply(_ tv: QCTextView) {
        let font = NSFont.systemFont(ofSize: size)
        tv.font = font
        tv.textColor = NSColor(QCColor.text)
        tv.typingAttributes = [.font: font, .foregroundColor: NSColor(QCColor.text)]
        tv.placeholder = NSAttributedString(string: placeholder, attributes: [.font: font, .foregroundColor: NSColor(QCColor.muted)])
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: QCTextField
        weak var textView: QCTextView?
        var focusTick = -1
        init(_ p: QCTextField) { parent = p }

        func textDidChange(_ n: Notification) {
            guard let tv = textView else { return }
            parent.text = tv.string
            measure()
        }

        func textView(_ tv: NSTextView, doCommandBy sel: Selector) -> Bool {
            switch sel {
            case #selector(NSResponder.insertNewline(_:)):
                if NSApp.currentEvent?.modifierFlags.contains(.shift) == true { tv.insertNewlineIgnoringFieldEditor(nil); return true }
                parent.onSubmit()
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                parent.onEscape()
                return true
            default:
                return false
            }
        }

        /// One line up to six: the field grows with the text, then scrolls.
        func measure() {
            guard let tv = textView, let lm = tv.layoutManager, let tc = tv.textContainer else { return }
            lm.ensureLayout(for: tc)
            let line = (tv.font ?? .systemFont(ofSize: parent.size)).boundingRectForFont.height
            let used = max(line, lm.usedRect(for: tc).height)
            let h = min(ceil(used), ceil(line * 6))
            if abs(h - parent.height) > 0.5 { DispatchQueue.main.async { self.parent.height = h } }
        }
    }
}

final class QCTextView: NSTextView {
    var placeholder: NSAttributedString? { didSet { needsDisplay = true } }
    override func draw(_ r: NSRect) {
        super.draw(r)
        if string.isEmpty, let p = placeholder { p.draw(at: NSPoint(x: textContainerOrigin.x, y: textContainerOrigin.y)) }
    }
    override func becomeFirstResponder() -> Bool { needsDisplay = true; return super.becomeFirstResponder() }
}

// MARK: - A picture of it, for checking (`--render-quick-chat OUT.png STATE`)

enum QuickChatRender {
    @MainActor static func write(to path: String, state: String) {
        let m = QuickChatModel()
        var e = AccountEntry(id: "main", name: "Main", label: "MAIN", configDir: "~/.claude-sample")
        e.seat = Seat(account: "sample", email: "ultra-1@example.com")
        m.target = QuickChatTarget(e)
        m.knownModels[.haiku] = "Haiku 5.5"
        let q1 = "How do I find which process is using port 3000 on macOS?"
        let a1 = "Use `lsof`:\n```zsh\nlsof -nP -iTCP:3000 -sTCP:LISTEN\n```\nThe **PID** column is the process. Stop it with `kill <PID>`.\n- `-nP` keeps addresses and ports as numbers, which is faster.\n- `-sTCP:LISTEN` shows only the server, not its clients."
        var t1 = QuickChatTurn(question: q1, answer: a1, model: "Haiku 5.5"); t1.phase = .done; t1.seconds = 2.4
        switch state {
        case "typing": m.field = q1
        case "notinstalled": m.field = q1; m.barProblem = .notInstalled
        case "streaming": var t = t1; t.answer = String(a1.prefix(90)); t.phase = .streaming; m.turns = [t]
        case "answer": m.turns = [t1]
        case "failed": var t = t1; t.answer = String(a1.prefix(60)); t.phase = .failed
            t.problem = .stopped(detail: "claude exited with code 1: API Error: Connection error."); m.turns = [t]
        case "notsigned": var t = QuickChatTurn(question: q1); t.phase = .failed; t.problem = .notSignedIn(profile: "Main", id: "main"); m.turns = [t]
        default: break
        }
        let view = QuickChatRoot(model: m).environment(\.qcRendering, true).padding(30).background(Color(white: 0.1))
        let r = ImageRenderer(content: view)
        r.scale = 2
        if let tiff = r.nsImage?.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
    }
}
