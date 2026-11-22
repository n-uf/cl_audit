// ClaudeAuth · a running claude's trail: the account the record named as the process started, then the process's own
// word (its `initialize` account). A process keeps the account it started on, whatever the record says later, so what it
// reports belongs to that account (FolderSignIn.answer(record:trail:)).

import Foundation
import ProfileCore

/// One running claude's trail. Make one as the process starts (the record read just before), give it the process's word
/// once its `initialize` answer comes, and drop it when the process ends.
public struct ProcessTrail: Equatable {
    /// The account the folder's record named just before the process started (guessed); nil when it named nobody. Its
    /// organisation id stays the one the process started on, so a rename while it runs never cuts its numbers.
    public let launchedOn: SignedInAccount?
    /// The process's own word, once it said it (verified); nil until then, and when it names nobody (a key, a token).
    public private(set) var word: SignedInAccount?

    public init(launchedOn: SignedInAccount?) { self.launchedOn = launchedOn?.names == true ? launchedOn : nil }

    /// The process said who it is (SignedInAccount.process of its `initialize` account). A word that names nobody, or a
    /// record passed for one, leaves the trail as it was.
    public mutating func said(_ word: SignedInAccount?) {
        guard let word, word.names, word.origin != .record else { return }
        self.word = word
    }

    /// The process's account as the trail knows it: its word, with the launch record's ids, organisation id and plan
    /// when the word names the very seat the process started on (by the organisation's name, case not counting); the
    /// word as it is otherwise (another account, or a seat not known: nothing taken). nil while it has said nothing.
    public var verified: SignedInAccount? {
        guard let word else { return nil }
        guard let l = launchedOn, word.match(l) == .seat else { return word }
        return word.filled(from: l)
    }
}
