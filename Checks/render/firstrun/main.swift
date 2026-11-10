// Renders the first-run page to PNGs, Std and Silver, width 708. Throwaway HOME only;
// no app is launched, nothing is shown on screen (an unshown window), Terminal and the Dock aren't touched.

import AppKit
import SwiftUI

let home = NSHomeDirectory()
guard home.hasSuffix("/Checks/.work/render/firstrun/home") else { print("refusing: HOME is \(home)"); exit(2) }
let fm = FileManager.default
func p(_ rel: String) -> String { (home as NSString).appendingPathComponent(rel) }
func resetHome() {
    for n in (try? fm.contentsOfDirectory(atPath: home)) ?? [] { try? fm.removeItem(atPath: p(n)) }
    try? fm.createDirectory(atPath: p("Library/Application Support"), withIntermediateDirectories: true)
}
func write(_ rel: String, _ text: String, exec: Bool = false) {
    let path = p(rel)
    try? fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    try? text.write(toFile: path, atomically: true, encoding: .utf8)
    if exec { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path) }
}
func fakeAccount(dir: String, uuid: String, email: String, orgType: String, orgName: String, plan: String) {
    let json: [String: Any] = ["oauthAccount": ["accountUuid": uuid, "emailAddress": email, "organizationUuid": "00000000-0000-4000-8000-0000000000ff",
                                                "organizationType": orgType, "organizationName": orgName, "planDisplayName": plan]]
    let file = p("\(dir.dropFirst(2))/.claude.json")
    try? fm.createDirectory(atPath: (file as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    try? JSONSerialization.data(withJSONObject: json).write(to: URL(fileURLWithPath: file))
    write("\(dir.dropFirst(2))/settings.json", "{}")
}
func wait(_ cond: () -> Bool) { let end = Date().addingTimeInterval(8); while !cond() && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) } }

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : p("../out")
try? fm.createDirectory(atPath: out, withIntermediateDirectories: true)

func render<V: View>(_ name: String, face: Face, width: CGFloat = 708, @ViewBuilder _ content: () -> V) {
    let root = ZStack(alignment: .topLeading) {
        ChassisBackground()
        content().padding(.horizontal, 16).padding(.vertical, 14).frame(width: width, alignment: .topLeading)
    }
    .frame(width: width)
    .face(face)
    let host = NSHostingView(rootView: root)
    host.frame = NSRect(x: 0, y: 0, width: width, height: 10)
    let win = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    win.appearance = face.appearance
    win.contentView = host
    host.layoutSubtreeIfNeeded()
    let h = max(200, ceil(host.fittingSize.height))
    host.frame = NSRect(x: 0, y: 0, width: width, height: h)
    win.setContentSize(host.frame.size)
    host.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.4))
    host.layoutSubtreeIfNeeded()
    guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { print("no bitmap for \(name)"); return }
    host.cacheDisplay(in: host.bounds, to: rep)
    let file = "\(out)/\(name)-\(face.rawValue).png"
    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: file))
    print("wrote \(file) (\(Int(width))×\(Int(h)))")
}

_ = NSApplication.shared
SettingsModel.followsDock = false
let none = ClaudeLocator.Lookup(candidates: { [] }, npmPrefix: { nil }, shell: { nil }, appCopy: { nil })

func scenario(_ name: String, setup: (SettingsModel) -> Void = { _ in }, prepare: () -> Void) {
    for w in [CGFloat(708), 340] {
        for face in [Face.std, .silver] {
            resetHome()
            prepare()
            let m = SettingsModel()
            m.detectClaude(force: true); wait { m.claudeLooked }
            setup(m)
            render("\(name)-w\(Int(w))", face: face, width: w) { FirstRunPage(model: m, width: w) }
        }
    }
}

// 1. Claude Code missing
scenario("1-missing") { ClaudeLocator.current = none }

// 2. found, with its version
scenario("2-found") {
    write(".local/bin/claude", "#!/bin/sh\necho \"2.1.211 (Claude Code)\"\n", exec: true)
    ClaudeLocator.current = ClaudeLocator.Lookup(candidates: { [p(".local/bin/claude")] }, npmPrefix: { nil }, shell: { nil }, appCopy: { nil })
}

// 3. found, only the Claude app's copy
scenario("3-from-app") {
    write("Library/Application Support/Claude/claude-code/2.1.211/abc/claude.app/Contents/MacOS/claude", "#!/bin/sh\necho \"2.1.211 (Claude Code)\"\n", exec: true)
    ClaudeLocator.current = ClaudeLocator.Lookup(candidates: { [] }, npmPrefix: { nil }, shell: { nil },
                                                 appCopy: { p("Library/Application Support/Claude/claude-code/2.1.211/abc/claude.app/Contents/MacOS/claude") })
}

// 4. step 2 with one signed-in folder found
func foundFolder() {
    write(".local/bin/claude", "#!/bin/sh\necho \"2.1.211 (Claude Code)\"\n", exec: true)
    ClaudeLocator.current = ClaudeLocator.Lookup(candidates: { [p(".local/bin/claude")] }, npmPrefix: { nil }, shell: { nil }, appCopy: { nil })
    fakeAccount(dir: "~/.claude-work", uuid: "00000000-0000-4000-8000-000000000001", email: "jane.sample@example.invalid",
                orgType: "team", orgName: "Sample Studio", plan: "Max")
}
scenario("4-account", prepare: foundFolder)

// 4b. waiting for a sign-in
scenario("4b-signing-in", setup: { m in
    m.firstRun.signInDir = "~/.claude-new"; m.firstRun.signInAsked = Date(); m.firstRun.email = "jane.sample@example.invalid"
}) { write(".local/bin/claude", "#!/bin/sh\necho \"2.1.211 (Claude Code)\"\n", exec: true)
     ClaudeLocator.current = ClaudeLocator.Lookup(candidates: { [p(".local/bin/claude")] }, npmPrefix: { nil }, shell: { nil }, appCopy: { nil }) }

// 5. step 3: name and colour
scenario("5-name", setup: { m in m.firstRunPick("~/.claude-work") }, prepare: foundFolder)

// 6. the install help as a sheet (what Install… opens elsewhere in Settings)
for w in [CGFloat(472), 340] { for face in [Face.std, .silver] {
    resetHome(); ClaudeLocator.current = none
    let m = SettingsModel(); m.detectClaude(force: true); wait { m.claudeLooked }
    render("6-install-sheet-w\(Int(w))", face: face, width: w) { ClaudeInstallCard(model: m, title: "Install Claude Code") }
} }

// 7. the inline reason, in a card as it sits above the sign-in keys
for w in [CGFloat(420), 340] { for face in [Face.std, .silver] {
    resetHome(); ClaudeLocator.current = none
    let m = SettingsModel(); m.detectClaude(force: true); wait { m.claudeLooked }
    render("7-inline-reason-w\(Int(w))", face: face, width: w) {
        SCard(title: "Claude Code") {
            VStack(alignment: .leading, spacing: 8) {
                ClaudeMissingLine(model: m)
                HStack(spacing: 6) {
                    Text("jane.sample@example.invalid").font(.system(size: 12))
                    Spacer()
                    Button("Sign in…") {}.buttonStyle(PillButtonStyle(tint: nil, compact: true))
                }
            }
        }
    }
} }

// 8 and 8b (the Add account pop-up) went with Add account: a profile's accounts are found on this Mac by themselves.
print("done")
