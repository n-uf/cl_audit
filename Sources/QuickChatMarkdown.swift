// QuickChatMarkdown: an answer's Markdown as blocks the chat window draws (QuickChatViews.swift). Paragraphs, headings,
// lists, quotes, rules and fenced code; the inline part (bold, italics, `code`, links) is left to Foundation's own
// Markdown. While an answer streams, a fence that isn't closed yet is still a code block, so code never flashes as text.

import Foundation

enum QuickChatBlock: Equatable {
    case paragraph(String)
    case heading(level: Int, text: String)
    case bullets([String])
    case numbered(start: Int, items: [String])
    case quote(String)
    case code(language: String, text: String)
    case rule
}

enum QuickChatMarkdown {
    static func blocks(_ source: String) -> [QuickChatBlock] {
        var out: [QuickChatBlock] = []
        var para: [String] = [], quote: [String] = []
        var bullets: [String] = [], numbered: [String] = [], start = 1
        func flush() {
            if !para.isEmpty { out.append(.paragraph(para.joined(separator: "\n"))); para = [] }
            if !quote.isEmpty { out.append(.quote(quote.joined(separator: "\n"))); quote = [] }
            if !bullets.isEmpty { out.append(.bullets(bullets)); bullets = [] }
            if !numbered.isEmpty { out.append(.numbered(start: start, items: numbered)); numbered = [] }
        }
        let lines = source.components(separatedBy: "\n")
        var i = 0
        while i < lines.count {
            let line = lines[i]
            let t = line.trimmingCharacters(in: .whitespaces)
            if let fence = Self.fence(t) {
                flush()
                var code: [String] = []
                i += 1
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(fence.marker) {
                    code.append(lines[i]); i += 1
                }
                i += 1
                out.append(.code(language: fence.language, text: code.joined(separator: "\n")))
                continue
            }
            if t.isEmpty { flush(); i += 1; continue }
            if let h = Self.heading(t) { flush(); out.append(.heading(level: h.level, text: h.text)); i += 1; continue }
            if t == "---" || t == "***" || t == "___" { flush(); out.append(.rule); i += 1; continue }
            if t.hasPrefix(">") {
                if !para.isEmpty || !bullets.isEmpty || !numbered.isEmpty { flush() }
                quote.append(String(t.dropFirst()).trimmingCharacters(in: .whitespaces)); i += 1; continue
            }
            if let item = Self.bullet(t) {
                if !para.isEmpty || !quote.isEmpty || !numbered.isEmpty { flush() }
                bullets.append(item); i += 1; continue
            }
            if let n = Self.number(t) {
                if !para.isEmpty || !quote.isEmpty || !bullets.isEmpty { flush() }
                if numbered.isEmpty { start = n.number }
                numbered.append(n.text); i += 1; continue
            }
            // a list item's next line, indented, belongs to it
            if line.hasPrefix("  "), !bullets.isEmpty { bullets[bullets.count - 1] += " " + t; i += 1; continue }
            if line.hasPrefix("  "), !numbered.isEmpty { numbered[numbered.count - 1] += " " + t; i += 1; continue }
            if !bullets.isEmpty || !numbered.isEmpty || !quote.isEmpty { flush() }
            para.append(t); i += 1
        }
        flush()
        return out
    }

    /// "```swift" or "~~~": the marker that closes it, and the language named ("" when none).
    static func fence(_ t: String) -> (marker: String, language: String)? {
        for m in ["```", "~~~"] where t.hasPrefix(m) {
            return (m, String(t.dropFirst(3)).trimmingCharacters(in: .whitespaces).split(separator: " ").first.map(String.init) ?? "")
        }
        return nil
    }

    static func heading(_ t: String) -> (level: Int, text: String)? {
        let hashes = t.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes), t.dropFirst(hashes).first == " " else { return nil }
        return (hashes, String(t.dropFirst(hashes + 1)))
    }

    static func bullet(_ t: String) -> String? {
        for m in ["- ", "* ", "+ ", "• "] where t.hasPrefix(m) { return String(t.dropFirst(2)) }
        return nil
    }

    static func number(_ t: String) -> (number: Int, text: String)? {
        let digits = t.prefix { $0.isNumber }
        guard !digits.isEmpty, digits.count <= 3, let n = Int(digits) else { return nil }
        let rest = t.dropFirst(digits.count)
        guard rest.hasPrefix(". ") || rest.hasPrefix(") ") else { return nil }
        return (n, String(rest.dropFirst(2)))
    }

    /// The inline part (bold, italics, `code`, links) as Foundation reads it; the plain text when it can't.
    static func inline(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }
}
