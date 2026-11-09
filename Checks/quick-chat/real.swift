// One real question through the quick chat's engine and the installed `claude` (Checks/quick-chat/real.sh).
// QC_CLAUDE: the claude to run; QC_CONFIG: the folder (a throwaway one by default: Claude Code then says it isn't
// signed in, which is what this checks without an account); QC_MODEL, QC_EFFORT; QC_WORK: the work folder.

import Foundation

let env = ProcessInfo.processInfo.environment
guard let claude = env["QC_CLAUDE"], let config = env["QC_CONFIG"], let work = env["QC_WORK"] else {
    print("needs QC_CLAUDE, QC_CONFIG and QC_WORK"); exit(64)
}
let isDefault = config == NSHomeDirectory() + "/.claude"
let cmd = QuickChatCommand(claude: claude, configDir: config, isDefaultDir: isDefault, workFolder: work,
                           model: env["QC_MODEL"] ?? "haiku", effort: env["QC_EFFORT"].flatMap { $0.isEmpty ? nil : $0 })
let p = QuickChatProcess(cmd)
var events: [QuickChatEvent] = []
var exitInfo: (Int32, String)?
p.onEvent = { events.append($0) }
p.onExit = { exitInfo = ($0, $1) }
let t0 = Date()
do { try p.start() } catch { print("couldn't start: \(error)"); exit(1) }
p.send(env["QC_QUESTION"] ?? "Reply with the single word: pong")
let end = Date().addingTimeInterval(90)
while Date() < end, exitInfo == nil, !events.contains(where: { if case .done = $0 { return true }; return false }) {
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
}
let secs = String(format: "%.1f", Date().timeIntervalSince(t0))
p.stop()
let stopEnd = Date().addingTimeInterval(5)
while exitInfo == nil, Date() < stopEnd { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
for e in events {
    switch e {
    case .started(_, let m): print("started: model \(m) (\(QuickChatParse.modelName(m)))")
    case .text(let t): print("text: \(t.debugDescription)")
    case .thinking(let t): print("thinking: \(t.count) characters")
    case .message(let t, let m, let err): print("message: \(t.prefix(80).debugDescription) model \(m) error \(err ?? "none")")
    case .limit(let type, let used, let status, _): print("limit: \(type ?? "?") used \(used.map { String($0) } ?? "?") \(status ?? "?")")
    case .done(let isError, let t, let ms, _): print("done: error \(isError), \(ms) ms, \(t.prefix(80).debugDescription)")
    case .ignored: break
    }
}
print("after \(secs) s; exit \(exitInfo.map { "\($0.0)" } ?? "none")\(exitInfo.map { $0.1.isEmpty ? "" : ", stderr: \($0.1)" } ?? "")")
