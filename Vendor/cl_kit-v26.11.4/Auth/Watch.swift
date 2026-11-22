// ClaudeAuth · the sign-in watch: whether Claude Code signed the folder in to another account since the last look. The
// record (.claude.json) is looked at by one stat each time and read again only when its date, size or file changed.
// Signing out (nobody named) isn't a change; signing in to another account after it is.

import Foundation

/// The record's date, size and file (Claude Code writes it by renaming a new file over it): equal while it is unchanged.
public struct RecordStamp: Equatable {
    public var modified: Date?
    public var size: UInt64?
    public var file: UInt64?

    public init(modified: Date? = nil, size: UInt64? = nil, file: UInt64? = nil) {
        self.modified = modified; self.size = size; self.file = file
    }

    /// No record there.
    public static let none = RecordStamp()

    /// The file at `path` now, without following a link at the end (a link swapped in is a change too).
    public static func of(_ path: String) -> RecordStamp {
        guard let a = try? FileManager.default.attributesOfItem(atPath: path) else { return .none }
        return RecordStamp(modified: a[.modificationDate] as? Date, size: (a[.size] as? NSNumber)?.uint64Value,
                           file: (a[.systemFileNumber] as? NSNumber)?.uint64Value)
    }
}

/// One folder's watch. Keep one per folder and look at it on every tick (or when the folder's directory changes).
public struct SignInChangeWatch {
    /// The last account the record named.
    public private(set) var seen: SignedInAccount?
    private var stamp = RecordStamp.none

    public init() {}

    /// One look: true when the record names another account or seat than the last one it named (the one comparison:
    /// `.different`). Unlike the reader's `generation`, signing out isn't a change here: the watch remembers the last
    /// account named and says only that another one signed in. `read` is asked only when the stamp moved.
    public mutating func look(stamp new: RecordStamp, read: () -> SignedInAccount?) -> Bool {
        guard new != stamp else { return false }
        stamp = new
        guard let now = read() else { return false }
        defer { seen = now }
        return seen.map { now.match($0) == .different } ?? false
    }

    /// One look through the one folder reader (FolderRecordReader): the reader's parse, read once for every part of
    /// the app that follows the folder.
    public mutating func look(_ reader: FolderRecordReader, folder: AuthFolder) -> Bool {
        let l = reader.look(folder)
        return look(stamp: l.stamp) { l.account }
    }
}
