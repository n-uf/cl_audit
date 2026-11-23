// Runs · the short ask: start `claude` on a folder, ask it who it is (its `initialize` answer's account) and, when wanted,
// its usage (`get_usage`), then stop it. No model message is ever sent, so nothing goes to a model; nothing is kept (no
// session, no tools, no MCP servers, no settings files, no slash commands). A timeout ends it whatever it does. The kit's
// part is the process and the two answers as data; whose account and numbers they are is ClaudeAuth's and ProfileCore's.
// A chat's own `claude` (a stream engine that sends messages) stays in the app.

import Foundation

public enum ClaudeAsk {
    /// `claude`'s arguments for the ask: stream-json in and out, nothing kept, nothing loaded, no tools.
    public static let arguments = ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
                                   "--no-session-persistence", "--tools", "", "--strict-mcp-config", "--setting-sources", "",
                                   "--disable-slash-commands"]

    /// The two requests' ids.
    public static let initializeID = "ask-1", usageID = "ask-2"

    /// One usage window of `get_usage`'s answer.
    public struct Window: Equatable {
        /// 0…100 (clamped), as Claude Code gives it; nil when it doesn't.
        public var used: Double?
        public var resets: Date?
        /// A `locked_reason` is given: the window refuses.
        public var locked: Bool
        public init(used: Double?, resets: Date?, locked: Bool) { self.used = used; self.resets = resets; self.locked = locked }
    }

    /// `get_usage`'s answer: the plan's two windows (every other key is left alone).
    public struct Limits: Equatable {
        /// `rate_limits_available` (or rate limits given): false when the account has none to say.
        public var available: Bool
        public var fiveHour: Window?
        public var week: Window?
        public init(available: Bool, fiveHour: Window?, week: Window?) { self.available = available; self.fiveHour = fiveHour; self.week = week }
    }

    /// How the ask ended.
    public enum End: Equatable {
        /// Every answer asked for came (an error answer to `get_usage` counts: it said no).
        case answered
        /// The time ran out first.
        case timedOut
        /// `claude` ended before answering.
        case exited
        /// `claude` couldn't start (not there, the folder not there).
        case couldNotStart
    }

    /// How `claude` came to an end after the ask: by itself, once its input was closed, by SIGTERM, or by SIGKILL.
    public enum Stop: Equatable {
        /// It ended before the ask stopped it (it had ended, or its output had and it ended within `grace`).
        case byItself
        /// It ended once its input was closed (the usual end: a stream-json `claude` ends at the end of its input).
        case inputClosed
        /// It ended on SIGTERM, `grace` after its input was closed.
        case terminated
        /// It was killed (SIGKILL), `grace` after SIGTERM.
        case killed
    }

    /// `initialize`'s answer, its named fields only: whether it named an account and a model list, as `claude` said them.
    public struct Initialize: Equatable {
        /// The `account` object's `email` and `organization` (non-empty strings only); nil: no `account` object at all.
        public var account: [String: String]?
        /// The models' `value`s, in order; nil: no `models` list at all (an empty list is []).
        public var models: [String]?
        public init(account: [String: String]?, models: [String]?) { self.account = account; self.models = models }
    }

    public struct Answer: Equatable {
        /// `initialize`'s `account`: `email` and `organization` (its name), each only when given and not empty; nil when
        /// no answer came. Empty when it names nobody (a key, a token). As a running claude's own word, for ClaudeAuth's
        /// `SignedInAccount.process`.
        public var account: [String: String]?
        /// `get_usage`'s answer, when asked for and given.
        public var limits: Limits?
        /// `get_usage` answered with an error (its text).
        public var usageError: String?
        public var end: End
        /// `initialize`'s answer as it came (an account without a model list, models without an account); nil: none came.
        public var initialize: Initialize?
        /// How `claude` ended after the ask; nil when it couldn't start.
        public var stop: Stop?
        /// Its exit status, as the process ended: the status, or the signal's number when `signaled`; nil: not known.
        public var exitStatus: Int32?
        /// It ended by a signal (SIGTERM, SIGKILL, or its own crash).
        public var signaled: Bool
        public init(account: [String: String]? = nil, limits: Limits? = nil, usageError: String? = nil, end: End,
                    initialize: Initialize? = nil, stop: Stop? = nil, exitStatus: Int32? = nil, signaled: Bool = false) {
            self.account = account; self.limits = limits; self.usageError = usageError; self.end = end
            self.initialize = initialize; self.stop = stop; self.exitStatus = exitStatus; self.signaled = signaled
        }
    }

    /// Asks `claude` once. `environment`: the run's (ClaudeEnvironment.make; the traceless pair is always added here);
    /// `folder`: where it runs, a folder (made by the caller: never made here). `usage`: ask `get_usage` too. Ends on every answer asked for, on `claude`'s end, or
    /// after `timeout`; then `claude` is stopped step by step, each step `grace` after the last one: its input closed, then
    /// SIGTERM, then SIGKILL (`Answer.stop` says which step ended it, `exitStatus` how). SIGTERM comes only a grace after
    /// the input closed. Blocks up to `timeout` + 2 × `grace` + 2 s (the kill's end waited for): off the main thread.
    public static func ask(claude: String, environment: [String: String], folder: String, usage: Bool,
                           timeout: TimeInterval = 25, grace: TimeInterval = 1.5) -> Answer {
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder, isDirectory: &isFolder), isFolder.boolValue else { return Answer(end: .couldNotStart) }
        // always traceless, whatever the caller passed: the ask never leaves a marker or a memory folder in the profile's folder
        var env = environment
        for (k, v) in ClaudeEnvironment.traceless { env[k] = v }
        let run = RunningProgram(Program(claude, arguments, environment: env, folder: .at(folder), timeout: .infinity))
        let state = Collected(wantsUsage: usage)
        let done = DispatchSemaphore(value: 0), ended = DispatchSemaphore(value: 0)
        run.onOutput = { chunk in
            guard let chunk else { state.exited(); done.signal(); return }
            if state.take(chunk) { done.signal() }
        }
        // its end as the process ends, not as its output ends (something it started may hold the output open)
        run.onTermination = { status, signaled in state.finished(status: status, signaled: signaled); ended.signal() }
        do { try run.start() } catch { return Answer(end: .couldNotStart) }
        var lines = controlLine(id: initializeID, subtype: "initialize")
        if usage { lines.append(controlLine(id: usageID, subtype: "get_usage")) }
        _ = run.write(lines)
        let timedOut = done.wait(timeout: .now() + timeout) == .timedOut
        // the stop, step by step: what ends it is said (an end already under way is waited for a moment first)
        let g = max(0, grace)
        func endsWithin(_ t: TimeInterval) -> Bool { ended.wait(timeout: .now() + t) == .success }
        let stop: Stop
        if endsWithin(0) || (state.outputEnded && endsWithin(g)) { stop = .byItself }
        else {
            run.closeInput()
            if endsWithin(g) { stop = .inputClosed }
            else {
                // a signal only to a process still running (never to a pid it may have left behind)
                if run.isRunning { kill(run.pid, SIGTERM) }
                if endsWithin(g) { stop = .terminated }
                else {
                    if run.isRunning { kill(run.pid, SIGKILL) }
                    // its end not heard back within 2 s: it was killed all the same
                    if !endsWithin(2) { state.finished(status: SIGKILL, signaled: true) }
                    stop = .killed
                }
            }
        }
        return state.answer(timedOut: timedOut, stop: stop)
    }

    /// One control request for `claude`'s input, ending in a newline.
    public static func controlLine(id: String, subtype: String) -> Data {
        let o: [String: Any] = ["type": "control_request", "request_id": id, "request": ["subtype": subtype]]
        var d = (try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys])) ?? Data()
        d.append(0x0A)
        return d
    }

    /// One line of `claude`'s output, as the ask reads it.
    public enum Event: Equatable {
        /// `initialize` answered: its account (see `Answer.account`).
        case account([String: String])
        case limits(Limits)
        /// A request answered with an error.
        case error(id: String, text: String)
        case ignored
    }

    /// One output line: a `control_response` to one of the ask's two requests; anything else is ignored. `initialize`'s
    /// answer counts when it has an account (with or without models) or models (an account not given: it names nobody, a
    /// key or a token); with neither it is ignored.
    public static func event(_ line: Data) -> Event {
        guard let o = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any], o["type"] as? String == "control_response",
              let r = o["response"] as? [String: Any], let id = r["request_id"] as? String,
              id == initializeID || id == usageID else { return .ignored }
        if r["subtype"] as? String == "error" { return .error(id: id, text: (r["error"] as? String) ?? "refused") }
        let answer = r["response"] as? [String: Any] ?? [:]
        if id == initializeID {
            // an answer with neither models nor an account says nothing about who it is: not an answer that names nobody
            guard answer["account"] is [String: Any] || answer["models"] is [Any] else { return .ignored }
            let a = answer["account"] as? [String: Any]
            var who: [String: String] = [:]
            for k in ["email", "organization"] {
                if let v = (a?[k] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty { who[k] = v }
            }
            return .account(who)
        }
        return .limits(limits(answer))
    }

    /// `get_usage`'s answer: `rate_limits.five_hour` and `.seven_day`, each `{utilization: 0…100, resets_at: ISO 8601,
    /// locked_reason}`.
    public static func limits(_ u: [String: Any]) -> Limits {
        let all = u["rate_limits"] as? [String: Any]
        func window(_ key: String) -> Window? {
            guard let w = (all?[key] ?? u[key]) as? [String: Any] else { return nil }
            let used = ((w["utilization"] as? NSNumber)?.doubleValue).flatMap { $0.isFinite ? min(100, max(0, $0)) : nil }
            let reason = w["locked_reason"]
            return Window(used: used, resets: (w["resets_at"] as? String).flatMap(isoDate),
                          locked: !(reason == nil || reason is NSNull || (reason as? String)?.isEmpty == true))
        }
        return Limits(available: (u["rate_limits_available"] as? Bool) ?? (all != nil), fiveHour: window("five_hour"), week: window("seven_day"))
    }

    /// "2026-11-12T18:00:00Z", with or without fractional seconds (any number of digits, dropped) or an offset.
    public static func isoDate(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        if let d = f.date(from: s) { return d }
        guard let dot = s.firstIndex(of: "."), s[s.index(after: dot)...].first?.isNumber == true else { return nil }
        var end = s.index(after: dot)
        while end < s.endIndex, s[end].isNumber { end = s.index(after: end) }
        return f.date(from: String(s[..<dot]) + String(s[end...]))
    }

    /// What has come so far, from the output queue.
    final class Collected {
        private let lock = NSLock()
        private var buffer = Data()
        private var account: [String: String]?, limits: Limits?, usageError: String?, initializeError = false
        private var initialize: Initialize?
        private var ended = false
        private var exit: (status: Int32, signaled: Bool)?
        let wantsUsage: Bool

        init(wantsUsage: Bool) { self.wantsUsage = wantsUsage }

        /// A chunk of output: true once every answer asked for has come.
        func take(_ chunk: Data) -> Bool {
            lock.lock(); defer { lock.unlock() }
            buffer.append(chunk)
            while let nl = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[buffer.startIndex..<nl])
                buffer.removeSubrange(buffer.startIndex...nl)
                if initialize == nil { initialize = ClaudeAsk.initializeAnswer(line) }
                switch ClaudeAsk.event(line) {
                case .account(let a): account = a
                case .limits(let l): limits = l
                case .error(let id, let text): if id == ClaudeAsk.usageID { usageError = text } else { initializeError = true }
                case .ignored: break
                }
            }
            return complete
        }

        func exited() { lock.lock(); ended = true; lock.unlock() }

        /// Its output has ended (it has ended, or is ending, by itself).
        var outputEnded: Bool { lock.lock(); defer { lock.unlock() }; return ended }

        func finished(status: Int32, signaled: Bool) { lock.lock(); exit = (status, signaled); lock.unlock() }

        private var complete: Bool {
            let said = account != nil || initializeError
            return said && (!wantsUsage || limits != nil || usageError != nil)
        }

        func answer(timedOut: Bool, stop: Stop) -> Answer {
            lock.lock(); defer { lock.unlock() }
            let end: End = complete ? .answered : ended && stop == .byItself ? .exited : timedOut ? .timedOut : .exited
            return Answer(account: account, limits: limits, usageError: usageError, end: end, initialize: initialize, stop: stop,
                          exitStatus: exit?.status, signaled: exit?.signaled ?? false)
        }
    }

    /// `initialize`'s answer in one output line, its named fields only (`Initialize`); nil for any other line, an error
    /// answer, or one with neither an account nor a model list.
    public static func initializeAnswer(_ line: Data) -> Initialize? {
        guard let o = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any], o["type"] as? String == "control_response",
              let r = o["response"] as? [String: Any], r["request_id"] as? String == initializeID, r["subtype"] as? String != "error",
              let answer = r["response"] as? [String: Any] else { return nil }
        let a = answer["account"] as? [String: Any], m = answer["models"] as? [Any]
        guard a != nil || m != nil else { return nil }
        let account = a.map { a -> [String: String] in
            var who: [String: String] = [:]
            for k in ["email", "organization"] {
                if let v = (a[k] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty { who[k] = v }
            }
            return who
        }
        let models = m.map { $0.compactMap { ($0 as? [String: Any])?["value"] as? String } }
        return Initialize(account: account, models: models)
    }
}
