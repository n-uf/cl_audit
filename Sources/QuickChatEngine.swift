// QuickChatEngine: the quick chat's talk with Claude Code (issue #11).
//
// One `claude` process per chat, kept open between messages: print mode with stream-json in and out, no tools, no MCP
// servers, no settings files, no slash commands, and Claude Code's non-essential traffic off. It runs on the profile's
// own folder (CLAUDE_CONFIG_DIR), so it answers on the account the profile has in use (and counts against its limits),
// and in quick chat's own work folder, so its sessions stay apart from the profile's others. Nothing else is sent anywhere.
//
// Everything here but `QuickChatProcess` is a plain function of its input, for the checks (Checks/quick-chat).

import Foundation

// MARK: - What Claude Code prints

/// One line Claude Code printed (stream-json), as the quick chat needs it.
enum QuickChatEvent: Equatable {
    /// The session started: its id and the model that answers ("claude-haiku-5-5").
    case started(session: String, model: String)
    /// A piece of the answer as it streams.
    case text(String)
    /// A piece of its thinking as it streams.
    case thinking(String)
    /// A whole message from Claude: its text, the model, and an error Claude Code reports with it
    /// ("authentication_failed", "rate_limit", …).
    case message(text: String, model: String, error: String?)
    /// The account's limit as Claude Code saw it: the share used (0…1) of the window it names, and when it resets.
    case limit(type: String?, used: Double?, status: String?, resets: Date?)
    /// The answer is done (or failed): Claude Code's last words, how long it took, the session.
    case done(isError: Bool, text: String, ms: Int, session: String)
    case ignored
}

enum QuickChatParse {
    /// One line of stream-json output. Lines it doesn't know are ignored, never an error.
    static func event(_ line: Data) -> QuickChatEvent {
        guard let o = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any], let type = o["type"] as? String else {
            return .ignored
        }
        switch type {
        case "system":
            guard o["subtype"] as? String == "init", let s = o["session_id"] as? String else { return .ignored }
            return .started(session: s, model: o["model"] as? String ?? "")
        case "stream_event":
            guard let e = o["event"] as? [String: Any], e["type"] as? String == "content_block_delta",
                  let d = e["delta"] as? [String: Any] else { return .ignored }
            switch d["type"] as? String {
            case "text_delta": return (d["text"] as? String).map { .text($0) } ?? .ignored
            case "thinking_delta": return (d["thinking"] as? String).map { .thinking($0) } ?? .ignored
            default: return .ignored
            }
        case "assistant":
            guard let m = o["message"] as? [String: Any] else { return .ignored }
            let blocks = m["content"] as? [[String: Any]] ?? []
            let text = blocks.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined()
            return .message(text: text, model: m["model"] as? String ?? "", error: o["error"] as? String)
        case "rate_limit_event":
            guard let info = o["rate_limit_info"] as? [String: Any] else { return .ignored }
            let kind = info["rateLimitType"] as? String
            let window = (info["unifiedWindows"] as? [String: Any])?[kind ?? ""] as? [String: Any]
            let used = (window?["utilization"] as? NSNumber)?.doubleValue ?? (info["utilization"] as? NSNumber)?.doubleValue
            let resets = ((window?["resetsAt"] ?? info["resetsAt"]) as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
            return .limit(type: kind, used: used, status: (window?["status"] ?? info["status"]) as? String, resets: resets)
        case "result":
            return .done(isError: o["is_error"] as? Bool ?? false, text: o["result"] as? String ?? "",
                         ms: (o["duration_ms"] as? NSNumber)?.intValue ?? 0, session: o["session_id"] as? String ?? "")
        default:
            return .ignored
        }
    }

    /// One message for Claude Code's input (stream-json), ending in a newline.
    static func userLine(_ text: String) -> Data {
        let o: [String: Any] = ["type": "user", "message": ["role": "user", "content": text]]
        var d = (try? JSONSerialization.data(withJSONObject: o)) ?? Data()
        d.append(0x0A)
        return d
    }

    /// Claude Code refused because a limit of the account is full: its error says so ("rate_limit"), or its words do
    /// ("Claude AI usage limit reached|1794776400", "You've hit your limit · resets 5pm", "5-hour limit reached").
    static func isLimit(error: String?, text: String) -> Bool {
        if let e = error?.lowercased(), e.contains("rate_limit") || e.contains("usage_limit") { return true }
        let t = text.lowercased()
        return t.contains("usage limit reached") || t.contains("hit your limit") || t.contains("limit reached")
            || t.contains("out of extra usage")
    }

    /// "claude-haiku-5-5" → "Haiku 5.5"; "claude-sonnet-5-5-20261001" → "Sonnet 5.5"; anything else as it is.
    static func modelName(_ id: String) -> String {
        var parts = id.split(separator: "-").map(String.init)
        if parts.first == "claude" { parts.removeFirst() }
        if let last = parts.last, last.count == 8, last.allSatisfy(\.isNumber) { parts.removeLast() }
        guard let family = parts.first, family.first?.isLetter == true else { return id }
        let version = parts.dropFirst().filter { $0.allSatisfy(\.isNumber) }
        let name = family.prefix(1).uppercased() + family.dropFirst()
        return version.isEmpty ? name : name + " " + version.joined(separator: ".")
    }
}

// MARK: - The command

/// How the quick chat runs `claude` for one chat.
struct QuickChatCommand: Equatable {
    var claude: String
    /// The profile's Claude Code folder, expanded; the default ~/.claude runs without CLAUDE_CONFIG_DIR, as Terminal does.
    var configDir: String
    var isDefaultDir: Bool
    /// Quick chat's own folder for this profile: Claude Code runs here, so its sessions are listed apart.
    var workFolder: String
    /// "haiku", "sonnet", "opus", or "" for the profile's own default.
    var model: String
    /// nil: thinking off; otherwise Claude Code's effort ("low", "medium", "high", "xhigh").
    var effort: String? = nil
    /// The session to go on with: after Stop, a crash, or a process closed while the chat sat idle.
    var resume: String? = nil

    static let systemPrompt = """
        You are Claude, answering in a small floating chat window on the user's Mac. Answer directly and briefly unless \
        asked for more. Use Markdown; put code in fenced blocks with the language named. You have no tools here.
        """

    var arguments: [String] {
        var a = ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
                 "--include-partial-messages", "--tools", "", "--strict-mcp-config", "--setting-sources", "",
                 "--disable-slash-commands", "--system-prompt", Self.systemPrompt]
        if !model.isEmpty { a += ["--model", model] }
        if let effort { a += ["--effort", effort, "--settings", #"{"alwaysThinkingEnabled":true}"#] }
        else { a += ["--settings", #"{"alwaysThinkingEnabled":false}"#] }
        if let resume, !resume.isEmpty { a += ["--resume", resume] }
        return a
    }

    /// What `claude` takes from the Mac's environment: who and where the user is, the language, and the network's
    /// proxies and certificates. Nothing else: no key or token, no other provider (Bedrock, Vertex, Foundry and their
    /// credentials), no model override, no custom headers and no telemetry export, so it answers on the folder's own
    /// sign-in and sends nothing but the chat.
    static let passed: Set<String> = ["HOME", "USER", "LOGNAME", "SHELL", "TMPDIR", "LANG", "TERM", "__CF_USER_TEXT_ENCODING",
                                      "HTTPS_PROXY", "https_proxy", "HTTP_PROXY", "http_proxy", "NO_PROXY", "no_proxy",
                                      "ALL_PROXY", "all_proxy", "SSL_CERT_FILE", "SSL_CERT_DIR", "NODE_EXTRA_CA_CERTS"]

    /// The environment `claude` gets: the allowed part of the Mac's (`passed`), the profile's folder, `claude`'s own
    /// folder first on the PATH (an npm install needs its `node`), and Claude Code's non-essential traffic (telemetry,
    /// error reports, update checks) off.
    func environment(_ base: [String: String]) -> [String: String] {
        var env = base.filter { Self.passed.contains($0.key) || $0.key.hasPrefix("LC_") }
        if !isDefaultDir { env["CLAUDE_CONFIG_DIR"] = configDir }
        let own = (claude as NSString).deletingLastPathComponent
        env["PATH"] = [own, "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", base["PATH"] ?? ""]
            .filter { !$0.isEmpty }.joined(separator: ":")
        env["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"] = "1"
        env["DISABLE_TELEMETRY"] = "1"
        env["DISABLE_ERROR_REPORTING"] = "1"
        return env
    }

    /// The folder name Claude Code keeps this work folder's sessions under, in the profile's folder: every UTF-16 unit
    /// that isn't an ASCII letter or digit becomes "-", as Claude Code counts them (~/.claude/projects/<this>/).
    static func projectKey(_ folder: String) -> String {
        String(folder.utf16.map { u -> Character in
            guard u < 128, let s = Unicode.Scalar(u), s.properties.isAlphabetic || ("0"..."9").contains(s) else { return "-" }
            return Character(s)
        })
    }
}

// MARK: - The process

/// One `claude` for one chat: started once, sent each message, read line by line. Its events and its end come on the
/// main thread. A `claude` that dies never takes the agent with it: writes to a closed pipe fail quietly (SIGPIPE is
/// ignored) and its end is reported with the last of what it wrote to stderr.
final class QuickChatProcess {
    let command: QuickChatCommand
    var onEvent: (QuickChatEvent) -> Void = { _ in }
    /// Its exit status and the end of its stderr.
    var onExit: (Int32, String) -> Void = { _, _ in }

    private let process = Process()
    private let input = Pipe(), output = Pipe(), errors = Pipe()
    private let lock = NSLock()
    private var errTail = Data()
    private var stopping = false

    init(_ command: QuickChatCommand) { self.command = command }

    var isRunning: Bool { process.isRunning }
    var pid: Int32 { process.processIdentifier }

    func start(environment base: [String: String] = ProcessInfo.processInfo.environment) throws {
        signal(SIGPIPE, SIG_IGN)
        // the profile's Claude Code folder gone: no claude for it (it would make the folder again)
        guard ClaudeCLI.mayLaunch("quick chat", command.isDefaultDir ? "~/.claude" : command.configDir) else {
            throw CocoaError(.fileNoSuchFile)
        }
        try FileManager.default.createDirectory(atPath: command.workFolder, withIntermediateDirectories: true)
        process.executableURL = URL(fileURLWithPath: command.claude)
        process.arguments = command.arguments
        process.environment = command.environment(base)
        process.currentDirectoryURL = URL(fileURLWithPath: command.workFolder)
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        let out = output.fileHandleForReading, err = errors.fileHandleForReading
        // stdout: whole lines, parsed off the main thread, delivered on it; at its end, the process's exit. Read with
        // read(2), which reports a failed read as an error rather than raising
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var buffer = Data()
            while let chunk = Self.read(out) {
                buffer.append(chunk)
                while let nl = buffer.firstIndex(of: 0x0A) {
                    let line = buffer[buffer.startIndex..<nl]
                    buffer.removeSubrange(buffer.startIndex...nl)
                    let e = QuickChatParse.event(Data(line))
                    if e != .ignored { DispatchQueue.main.async { self?.onEvent(e) } }
                }
            }
            if !buffer.isEmpty {
                let e = QuickChatParse.event(buffer)
                if e != .ignored { DispatchQueue.main.async { self?.onEvent(e) } }
            }
            guard let self else { return }
            self.process.waitUntilExit()
            usleep(50_000)      // the last of stderr
            let status = self.process.terminationStatus
            let tail = self.stderrTail()
            DispatchQueue.main.async { self.onExit(status, tail) }
        }
        // stderr: only its last 4 KB is kept, for "what happened"
        DispatchQueue.global(qos: .utility).async { [weak self] in
            while let chunk = Self.read(err) {
                guard let self else { return }
                self.lock.lock()
                self.errTail.append(chunk)
                if self.errTail.count > 4096 { self.errTail = self.errTail.suffix(4096) }
                self.lock.unlock()
            }
        }
    }

    /// What's there to read, as soon as some is; nil at the end or on an error.
    private static func read(_ h: FileHandle) -> Data? {
        var buf = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = Darwin.read(h.fileDescriptor, &buf, buf.count)
            if n > 0 { return Data(buf[0..<n]) }
            if n < 0, errno == EINTR { continue }
            return nil
        }
    }

    /// Sends one message. False when the process is gone (the pipe is closed).
    @discardableResult
    func send(_ text: String) -> Bool {
        lock.lock(); let closed = stopping; lock.unlock()
        guard !closed, process.isRunning else { return false }
        do { try input.fileHandleForWriting.write(contentsOf: QuickChatParse.userLine(text)); return true }
        catch { return false }
    }

    /// Ends it: closes its input, then asks it to stop, then stops it.
    func stop() {
        lock.lock(); let already = stopping; stopping = true; lock.unlock()
        guard !already, process.isRunning else { return }
        try? input.fileHandleForWriting.close()
        process.terminate()
        // the fallback holds the process itself: the chat lets go of this object right after Stop
        let p = process
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) {
            if p.isRunning { kill(p.processIdentifier, SIGKILL) }
        }
    }

    /// The end of what it wrote to stderr: its last few non-empty lines, at most 400 characters.
    func stderrTail() -> String {
        lock.lock(); let d = errTail; lock.unlock()
        let text = String(decoding: d, as: UTF8.self)
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return String(lines.suffix(3).joined(separator: " · ").suffix(400))
    }
}
