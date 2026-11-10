// Checks for the quick chat's engine and Markdown (Checks/quick-chat/run.sh). Sample data only.

import Foundation

var passed = 0, failed = 0
func check(_ name: String, _ ok: Bool, _ got: @autoclosure () -> Any = "") {
    if ok { passed += 1 } else { failed += 1; print("FAIL \(name)  got: \(got())") }
}
func line(_ s: String) -> Data { Data(s.utf8) }
/// Runs the main run loop until `done` or the time is up.
func wait(_ seconds: Double, until done: () -> Bool) {
    let end = Date().addingTimeInterval(seconds)
    while !done(), Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
}

// MARK: parsing what Claude Code prints

check("init", QuickChatParse.event(line(#"{"type":"system","subtype":"init","session_id":"s-1","model":"claude-haiku-5-5","tools":[]}"#))
      == .started(session: "s-1", model: "claude-haiku-5-5"))
check("status is ignored", QuickChatParse.event(line(#"{"type":"system","subtype":"status","status":"requesting"}"#)) == .ignored)
check("text delta", QuickChatParse.event(line(#"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hel"}}}"#)) == .text("Hel"))
check("thinking delta", QuickChatParse.event(line(#"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"Hmm"}}}"#)) == .thinking("Hmm"))
check("block start is ignored", QuickChatParse.event(line(#"{"type":"stream_event","event":{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}}"#)) == .ignored)
check("assistant", QuickChatParse.event(line(#"{"type":"assistant","message":{"model":"claude-haiku-5-5","content":[{"type":"thinking","thinking":"x"},{"type":"text","text":"Hi"},{"type":"text","text":" there"}]}}"#))
      == .message(text: "Hi there", model: "claude-haiku-5-5", error: nil))
check("assistant, not signed in", QuickChatParse.event(line(#"{"type":"assistant","message":{"model":"<synthetic>","content":[{"type":"text","text":"Not logged in · Please run /login"}]},"error":"authentication_failed"}"#))
      == .message(text: "Not logged in · Please run /login", model: "<synthetic>", error: "authentication_failed"))
let lim = QuickChatParse.event(line(#"{"type":"rate_limit_event","rate_limit_info":{"status":"allowed","resetsAt":1794776400,"rateLimitType":"seven_day","unifiedWindows":{"seven_day":{"utilization":0.05,"resetsAt":1794776400,"status":"allowed"}}}}"#))
check("rate limit", lim == .limit(type: "seven_day", used: 0.05, status: "allowed", resets: Date(timeIntervalSince1970: 1794776400)), lim)
check("result", QuickChatParse.event(line(#"{"type":"result","subtype":"success","is_error":false,"result":"Hi","duration_ms":1742,"session_id":"s-1"}"#))
      == .done(isError: false, text: "Hi", ms: 1742, session: "s-1"))
check("result, an error", QuickChatParse.event(line(#"{"type":"result","is_error":true,"result":"Not logged in","duration_ms":5,"session_id":"s-1"}"#))
      == .done(isError: true, text: "Not logged in", ms: 5, session: "s-1"))
check("garbage is ignored", QuickChatParse.event(line("not json")) == .ignored)
check("an unknown type is ignored", QuickChatParse.event(line(#"{"type":"post_turn_summary"}"#)) == .ignored)

// the message Claude Code reads: one JSON line, whatever the text holds
let tricky = "Quote \" backslash \\ newline\nand emoji 🙂 and <tags>"
let ul = QuickChatParse.userLine(tricky)
check("user line ends in a newline", ul.last == 0x0A)
let back = (try? JSONSerialization.jsonObject(with: ul.dropLast())) as? [String: Any]
check("user line reads back", (back?["message"] as? [String: Any])?["content"] as? String == tricky, back as Any)
check("user line is one line", !ul.dropLast().contains(0x0A))

// model names
for (id, want) in [("claude-haiku-5-5", "Haiku 5.5"), ("claude-sonnet-5-5-20261001", "Sonnet 5.5"), ("claude-opus-5-5", "Opus 5.5"),
                   ("claude-fable-5-1", "Fable 5.1"), ("claude-haiku-4-5-20251001", "Haiku 4.5"), ("", ""), ("<synthetic>", "<synthetic>")] {
    check("model name \(id)", QuickChatParse.modelName(id) == want, QuickChatParse.modelName(id))
}

// MARK: the command

let cmd = QuickChatCommand(claude: "/opt/sample/bin/claude", configDir: "/Users/sample/.claude-work", isDefaultDir: false,
                           workFolder: "/tmp/sample-work", model: "haiku")
let a = cmd.arguments
func after(_ flag: String, _ args: [String]) -> String? { args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
check("print mode", a.first == "-p")
check("stream-json in", after("--input-format", a) == "stream-json")
check("stream-json out", after("--output-format", a) == "stream-json")
check("no tools", after("--tools", a) == "")
check("no settings files", after("--setting-sources", a) == "")
check("no MCP servers", a.contains("--strict-mcp-config"))
check("no slash commands", a.contains("--disable-slash-commands"))
check("its own system prompt", after("--system-prompt", a) == QuickChatCommand.systemPrompt)
check("the model", after("--model", a) == "haiku")
check("thinking off", after("--settings", a) == #"{"alwaysThinkingEnabled":false}"# && !a.contains("--effort"), a)
check("no resume at first", !a.contains("--resume"))
check("never bare (it would skip the Keychain sign-in)", !a.contains("--bare"))
var c2 = cmd; c2.model = ""; c2.effort = "high"; c2.resume = "s-1"
let a2 = c2.arguments
check("the profile's own model", !a2.contains("--model"))
check("thinking high", after("--effort", a2) == "high" && after("--settings", a2) == #"{"alwaysThinkingEnabled":true}"#, a2)
check("resume", after("--resume", a2) == "s-1")

let base = ["PATH": "/usr/bin:/bin", "HOME": "/Users/sample", "LANG": "en_GB.UTF-8", "LC_CTYPE": "UTF-8", "HTTPS_PROXY": "http://proxy.example:8080",
            "ANTHROPIC_API_KEY": "sk-sample", "CLAUDE_CODE_OAUTH_TOKEN": "sample", "CLAUDE_CODE_OAUTH_REFRESH_TOKEN": "sample",
            "ANTHROPIC_AUTH_TOKEN": "sample", "CLAUDE_CONFIG_DIR": "/Users/sample/.claude-other", "ANTHROPIC_BASE_URL": "https://example.com",
            "CLAUDE_CODE_USE_BEDROCK": "1", "AWS_BEARER_TOKEN_BEDROCK": "sample", "CLAUDE_CODE_USE_VERTEX": "1", "ANTHROPIC_VERTEX_PROJECT_ID": "sample",
            "CLAUDE_CODE_ENABLE_TELEMETRY": "1", "OTEL_EXPORTER_OTLP_ENDPOINT": "https://collector.example", "ANTHROPIC_CUSTOM_HEADERS": "X: y",
            "ANTHROPIC_MODEL": "opus", "NODE_OPTIONS": "--require /tmp/x.js"]
let env = cmd.environment(base)
check("its environment carries none of the API key or token variables",env["ANTHROPIC_API_KEY"] == nil && env["ANTHROPIC_AUTH_TOKEN"] == nil && env["CLAUDE_CODE_OAUTH_TOKEN"] == nil
      && env["CLAUDE_CODE_OAUTH_REFRESH_TOKEN"] == nil)
check("no other endpoint", env["ANTHROPIC_BASE_URL"] == nil)
check("no other provider", env["CLAUDE_CODE_USE_BEDROCK"] == nil && env["AWS_BEARER_TOKEN_BEDROCK"] == nil && env["CLAUDE_CODE_USE_VERTEX"] == nil
      && env["ANTHROPIC_VERTEX_PROJECT_ID"] == nil)
check("no telemetry export", env["CLAUDE_CODE_ENABLE_TELEMETRY"] == nil && env["OTEL_EXPORTER_OTLP_ENDPOINT"] == nil)
check("no headers, model or node options from outside", env["ANTHROPIC_CUSTOM_HEADERS"] == nil && env["ANTHROPIC_MODEL"] == nil && env["NODE_OPTIONS"] == nil)
check("language and proxy kept", env["LANG"] == "en_GB.UTF-8" && env["LC_CTYPE"] == "UTF-8" && env["HTTPS_PROXY"] == "http://proxy.example:8080")
check("nothing but the allowed, the folder, the PATH and the off switches",
      Set(env.keys).subtracting(QuickChatCommand.passed).subtracting(["CLAUDE_CONFIG_DIR", "PATH", "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC",
                                                                      "DISABLE_TELEMETRY", "DISABLE_ERROR_REPORTING"]).allSatisfy { $0.hasPrefix("LC_") },
      env.keys.sorted())
check("the profile's folder", env["CLAUDE_CONFIG_DIR"] == "/Users/sample/.claude-work")
check("claude's folder first on the PATH", env["PATH"]?.hasPrefix("/opt/sample/bin:") == true, env["PATH"] ?? "")
check("non-essential traffic off", env["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"] == "1" && env["DISABLE_TELEMETRY"] == "1")
check("HOME kept", env["HOME"] == "/Users/sample")
var dflt = cmd; dflt.isDefaultDir = true; dflt.configDir = "/Users/sample/.claude"
check("the default folder runs without CLAUDE_CONFIG_DIR", dflt.environment(base)["CLAUDE_CONFIG_DIR"] == nil)

// the folder Claude Code keeps a work folder's sessions under (seen with Claude Code 2.1.318)
check("project key", QuickChatCommand.projectKey("/Users/sample/Library/Application Support/usage-n-uf/quick-chat/main")
      == "-Users-sample-Library-Application-Support-usage-n-uf-quick-chat-main")
check("project key, dots and dashes", QuickChatCommand.projectKey("/private/tmp/a-1/.b_c") == "-private-tmp-a-1--b-c")
// Claude Code counts UTF-16 units: an emoji is two, so two dashes; an accented letter one
check("project key, beyond ASCII", QuickChatCommand.projectKey("/Users/Dé/😀b") == "-Users-D----b", QuickChatCommand.projectKey("/Users/Dé/😀b"))

// MARK: Markdown

typealias B = QuickChatBlock
check("paragraphs", QuickChatMarkdown.blocks("One\ntwo\n\nThree") == [B.paragraph("One\ntwo"), .paragraph("Three")])
check("code, closed", QuickChatMarkdown.blocks("Use:\n```zsh\nls -la\necho hi\n```\nDone.")
      == [.paragraph("Use:"), .code(language: "zsh", text: "ls -la\necho hi"), .paragraph("Done.")])
check("code, still streaming", QuickChatMarkdown.blocks("Use:\n```swift\nlet a = 1") == [.paragraph("Use:"), .code(language: "swift", text: "let a = 1")])
check("code with no language", QuickChatMarkdown.blocks("```\nx\n```") == [.code(language: "", text: "x")])
check("code keeps blank lines and indents", QuickChatMarkdown.blocks("```\na\n\n    b\n```") == [.code(language: "", text: "a\n\n    b")])
check("tilde fence", QuickChatMarkdown.blocks("~~~py\nprint(1)\n~~~") == [.code(language: "py", text: "print(1)")])
check("bullets", QuickChatMarkdown.blocks("Opts:\n- one\n- two\n  more\n* three") == [.paragraph("Opts:"), .bullets(["one", "two more", "three"])])
check("numbered", QuickChatMarkdown.blocks("3. c\n4. d") == [.numbered(start: 3, items: ["c", "d"])])
check("heading", QuickChatMarkdown.blocks("## Steps\nText") == [.heading(level: 2, text: "Steps"), .paragraph("Text")])
check("not a heading", QuickChatMarkdown.blocks("#hashtag") == [.paragraph("#hashtag")])
check("quote", QuickChatMarkdown.blocks("> a\n> b\nc") == [.quote("a\nb"), .paragraph("c")])
check("rule", QuickChatMarkdown.blocks("a\n\n---\n\nb") == [.paragraph("a"), .rule, .paragraph("b")])
check("empty", QuickChatMarkdown.blocks("") == [])
check("a year is not a list", QuickChatMarkdown.blocks("2026. A year.") == [.paragraph("2026. A year.")])
check("inline code", QuickChatMarkdown.inline("use `ls`").runs.contains { $0.inlinePresentationIntent?.contains(.code) == true })
let links = QuickChatMarkdown.inline("[web](https://example.com) [mail](mailto:a@example.com) [file](file:///etc/hosts) [app](sample-app://x)")
let kept = links.runs.compactMap { $0.link?.scheme }
check("only web and mail links stay links", kept == ["https", "mailto"], kept)
check("a dropped link keeps its words", String(links.characters).contains("file") && String(links.characters).contains("app"))

// MARK: the process, against the stand-in

let stub = ProcessInfo.processInfo.environment["QC_STUB_PATH"] ?? ""
let work = ProcessInfo.processInfo.environment["QC_WORK"] ?? NSTemporaryDirectory() + "qc-work"
let argsFile = work + "-args.txt"
check("the stand-in is there", FileManager.default.isExecutableFile(atPath: stub), stub)

func run(_ mode: String, _ body: (QuickChatProcess, () -> [QuickChatEvent], () -> (Int32, String)?) -> Void) {
    // the stand-in's settings: beside the work folder, since `claude` gets only an allowlisted environment
    try? FileManager.default.createDirectory(atPath: work, withIntermediateDirectories: true)
    try? "mode=\(mode)\nargs=\(argsFile)\n".write(toFile: (work as NSString).deletingLastPathComponent + "/stub.conf", atomically: true, encoding: .utf8)
    try? FileManager.default.removeItem(atPath: argsFile)
    let p = QuickChatProcess(QuickChatCommand(claude: stub, configDir: "/Users/sample/.claude-work", isDefaultDir: false,
                                              workFolder: work, model: "haiku"))
    var events: [QuickChatEvent] = []
    var exit: (Int32, String)?
    p.onEvent = { events.append($0) }
    p.onExit = { exit = ($0, $1) }
    do { try p.start() } catch { check("\(mode): starts", false, error); return }
    body(p, { events }, { exit })
    p.stop()
    wait(3) { exit != nil }
}

func done(_ es: [QuickChatEvent]) -> Int { es.filter { if case .done = $0 { return true }; return false }.count }

run("ok") { p, events, exit in
    wait(3) { events().contains { if case .started = $0 { return true }; return false } }
    check("ok: started", events().first == .started(session: "00000000-0000-4000-8000-000000000001", model: "claude-haiku-5-5"), events())
    check("ok: sent", p.send("first question"))
    wait(5) { done(events()) == 1 }
    let texts = events().compactMap { if case .text(let t) = $0 { return t }; return nil }.joined()
    check("ok: streamed", texts == "Answer 1", texts)
    check("ok: the limit seen", events().contains(.limit(type: "seven_day", used: 0.62, status: "allowed", resets: Date(timeIntervalSince1970: 1794776400))))
    check("ok: done", events().contains(.done(isError: false, text: "Answer 1", ms: 1200, session: "00000000-0000-4000-8000-000000000001")))
    let pid = p.pid
    check("ok: a follow-up", p.send("second question"))
    wait(5) { done(events()) == 2 }
    check("ok: the same process answered", p.isRunning && p.pid == pid && events().contains(.done(isError: false, text: "Answer 2", ms: 1200, session: "00000000-0000-4000-8000-000000000001")))
    let recorded = (try? String(contentsOfFile: argsFile, encoding: .utf8)) ?? ""
    check("ok: ran in the work folder", recorded.contains("PWD \(work)") || recorded.contains("PWD /private\(work)"), recorded)
    check("ok: on the profile's folder", recorded.contains("ENV CLAUDE_CONFIG_DIR=/Users/sample/.claude-work"))
    check("ok: traffic off", recorded.contains("ENV TRAFFIC=1"))
    check("ok: tools off", recorded.contains("ARG [--tools]\nARG []\n"))
    check("ok: no key passed on", recorded.contains("ENV KEY=<unset>") && recorded.contains("ENV TOKEN=<unset>"))
    check("ok: started once", recorded.components(separatedBy: "PID ").count == 2)
    check("ok: no exit yet", exit() == nil)
}

setenv("ANTHROPIC_API_KEY", "sk-sample-should-not-pass", 1)
setenv("CLAUDE_CODE_OAUTH_TOKEN", "sample-should-not-pass", 1)
run("auth") { p, events, exit in
    p.send("hi")
    wait(5) { done(events()) == 1 }
    check("auth: the error", events().contains(.message(text: "Not logged in · Please run /login", model: "<synthetic>", error: "authentication_failed")), events())
    check("auth: an error result", events().contains { if case .done(true, _, _, _) = $0 { return true }; return false })
    let recorded = (try? String(contentsOfFile: argsFile, encoding: .utf8)) ?? ""
    check("auth: the Mac's API key and token not passed on", recorded.contains("ENV KEY=<unset>") && recorded.contains("ENV TOKEN=<unset>"), recorded)
}
unsetenv("ANTHROPIC_API_KEY")
unsetenv("CLAUDE_CODE_OAUTH_TOKEN")

run("crash") { p, events, exit in
    p.send("hi")
    wait(5) { exit() != nil }
    check("crash: the half answer arrived", events().contains(.text("Half an ans")))
    check("crash: its exit", exit()?.0 == 3, exit() as Any)
    check("crash: what it said", exit()?.1.contains("sample failure for the checks") == true, exit() as Any)
    check("crash: sending again fails quietly", p.send("again") == false)
}

run("slow") { p, events, exit in
    p.send("hi")
    wait(5) { events().contains(.text("Half an ans")) }
    let t0 = Date()
    p.stop()
    wait(5) { exit() != nil }
    check("slow: Stop ends it", exit() != nil && Date().timeIntervalSince(t0) < 3, Date().timeIntervalSince(t0))
    check("slow: Stop twice is harmless", { p.stop(); return true }())
}

// a `claude` that isn't there: start throws, nothing crashes
let missing = QuickChatProcess(QuickChatCommand(claude: "/nonexistent/claude", configDir: "/x", isDefaultDir: false, workFolder: work, model: ""))
check("a missing claude throws", (try? missing.start()) == nil)
check("a missing claude can't be sent to", missing.send("hi") == false)

try? FileManager.default.removeItem(atPath: argsFile)
print("quick chat checks: \(passed)/\(passed + failed) passed")
exit(failed == 0 ? 0 : 1)
