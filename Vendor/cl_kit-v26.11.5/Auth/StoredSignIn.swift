// ClaudeAuth · the stored sign-in: where an app reads the folder's sign-in itself, behind one protocol. ClaudeAuth never
// names the store here: cl_audit passes its Keychain reader (Keychain.swift), cl_quick passes none
// and doesn't compile Keychain.swift at all (it never reads the Keychain: it knows the account from a running claude's
// `initialize` answer and takes the record for a guess).

import Foundation
import ProfileCore

/// Reads the folder's stored sign-in (a token with its expiry and plan, none, refused, or unreadable), never writing it.
/// Blocks (a locked store can keep it waiting): call off the main thread.
public protocol StoredSignInReader {
    func read(_ folder: AuthFolder, user: String) -> Login
}
