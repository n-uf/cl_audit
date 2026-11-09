// Runs the app's own SecretScan over the files named on the command line: prints each file with a hit, and the number of hits.
// Exit 1 when there is any. The suites build their fake keys at run time, so the committed files hold none.
import Foundation

var hits = 0, files = 0
for path in CommandLine.arguments.dropFirst() {
    guard let kinds = SecretScan.scan(path: path) else { continue }
    files += 1
    if !kinds.isEmpty { hits += kinds.count; print("HIT \(path): \(kinds.map { "\($0)" }.sorted().joined(separator: ", "))") }
}
print("secret scan: \(files) files, \(hits) hits")
exit(hits == 0 ? 0 : 1)
