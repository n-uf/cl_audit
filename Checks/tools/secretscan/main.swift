// Runs the app's own SecretScan (Sources/SecretScan.swift, the engines' one secret scan) over the files named on the command line:
// prints each file with a hit, and the number of hits. Exit 1 when there is any. The suites build their fake keys at run time, so
// the committed files hold none.
//
//   cl_audit-checks-scan FILE...            each file whole, as an export looks at it
//   cl_audit-checks-scan --lines FILE...    each line on its own, with its number ("HIT path:line: kinds"): what leakscan.py and
//                                           render/atlas.py ask for (they carry no key patterns of their own; $SECRETSCAN names
//                                           this tool for them)
import Foundation

var args = Array(CommandLine.arguments.dropFirst())
let byLine = args.first == "--lines"
if byLine { args.removeFirst() }
var hits = 0, files = 0
for path in args {
    if byLine {
        // (a file of the repository or a page the checks made: a few MB at most; one larger isn't read, and counts as a hit)
        guard let r = SafeRead.read(path, max: 256 << 20, whole: true) else { print("UNREAD \(path)"); hits += 1; continue }
        files += 1
        var line = 0
        for piece in r.data.split(separator: 0x0A, omittingEmptySubsequences: false) {
            line += 1
            let kinds = SecretScan.scan(Data(piece))
            if !kinds.isEmpty { hits += kinds.count; print("HIT \(path):\(line): \(kinds.map { "\($0)" }.sorted().joined(separator: ", "))") }
        }
        continue
    }
    guard let kinds = SecretScan.scan(path: path) else { continue }
    files += 1
    if !kinds.isEmpty { hits += kinds.count; print("HIT \(path): \(kinds.map { "\($0)" }.sorted().joined(separator: ", "))") }
}
print("secret scan: \(files) files, \(hits) hits")
exit(hits == 0 ? 0 : 1)
