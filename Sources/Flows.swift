// Flows: cl_audit's side of SafeFiles (SafeFiles.swift), what the data-moving flows share: the one lock they take, with
// cl_audit's words for it, and what stopped half way on a profile, as every flow's start check sees it. Each flow keeps its
// receipts in its own ReceiptStore (a switch: switches/, a restore or import: restores/, a re-point: repoints/, side files:
// sides/, a move import: moves/, the move to the default profile: default-moves/), and none of them may start another on top
// of one that is open: the later Undo or Finish would meet files it didn't write.
//
// Who holds whom back:
//   - a restore or import (and its Undo, and the folder pick that follows it) waits for another restore or import of the
//     profile that stopped half way: its words stay as they were; one left as it is (SessionsRestore.leaveAsIs, the
//     Restore page) holds nothing back any more, for a switch either;
//   - a switch waits for a restore or import of the profile that stopped half way, and for the move to the default profile
//     when the profile is the new default or the one it came from, and says which one and where to finish or undo it; a
//     move left as it is (DefaultProfile.leaveAsIs, its card "The move stopped") holds nothing back any more;
//   - a switch that stopped half way holds no restore or import back (an old one can't be finished or undone, and a new
//     one has its own Undo and Leave it as it is on the Sessions card): the Switch page says it on its own, with the words
//     for signing in as the account it went for, so this check leaves it out;
//   - the move's own restore is not held back by the move's record (the record is open while its restore runs); the restore
//     receipt it wrote is what holds the others back;
//   - a re-point's receipt has no Finish and no Undo from a page until it is finished, so it holds nothing back; a window
//     held closed for one is the window marker's business (SwitchMarker).
// Export only reads, so it asks nothing.

import Foundation

enum Flows {
    // MARK: one writer at a time

    /// cl_audit's own lock (switches/.lock), and claude-transplant's: claude-transplant 4.2.1 runs
    /// `/usr/bin/lockf -k -s -w -t 0 <its folder>/lock …` (a flock; -k keeps the file between runs), or perl's flock on the same
    /// file, and makes the folder and the file when they're missing. cl_audit makes them too, so a claude-transplant that starts
    /// meanwhile finds the lock held, even on its first run.
    static let lock = FlowLock(path: SwitchEngine.root.appendingPathComponent(".lock").path,
                               other: (expand("~/Library/Application Support/claude-transplant") as NSString).appendingPathComponent("lock"))

    /// Takes the lock for one restore, import, move or switch, held until `release()`; when it can't be taken, cl_audit's words
    /// (SwitchError.busy).
    static func takeLock() throws -> FlowLock.Held {
        do {
            return try lock.take()
        } catch let busy as FlowLock.Busy {
            switch busy {
            // (the lock doesn't say who holds it: every flow that writes or copies sessions takes it, so it names them all)
            case .held: throw SwitchError.busy("Another backup, export, restore, import, move or switch is under way.")
            case .unopenable: throw SwitchError.busy("Couldn't take cl_audit's lock.")
            case .otherUnopenable: throw SwitchError.busy("Couldn't check claude-transplant's lock.")
            case .otherHeld: throw SwitchError.busy("claude-transplant is moving sessions; wait for it to finish.")
            }
        }
    }

    /// Whether one restore, import or move is under way elsewhere (cl_audit's own lock) or claude-transplant is moving
    /// sessions (its lock): the words, or nil. Takes the locks and lets go at once. Taking claude-transplant's flock for
    /// that instant can make a `lockf -t 0` caller that starts in that very moment fail once; it is only a look.
    static func busy() -> String? {
        do { try takeLock().release(); return nil } catch { return "\(error)" }
    }

    // MARK: what stopped half way

    /// The flow that asks.
    enum Asking {
        case switching                  // an account switch (the Switch page, SwitchEngine.run under its lock)
        case restoring                  // a restore, an import, their Undo, the folder pick, the default-profile move's restore
    }

    /// Why a flow of this profile may not start, or nil. `except`: the receipt of the restore the caller is itself finishing
    /// or undoing.
    static func blocker(profile: String, except id: String? = nil, for flow: Asking) -> String? {
        if flow == .switching, let m = DefaultProfile.unfinished(involving: profile) {
            return "The move to the default profile stopped half way on \(SessionsBackup.dateWords(m.started)). "
                + "Finish it or undo it first, in Settings ▸ General: its card “The move stopped” has the button."
        }
        guard let r = SessionsRestore.unfinished(profile: profile).first(where: { $0.id != id }) else { return nil }
        let date = SessionsBackup.dateWords(r.started)
        switch flow {
        case .restoring:
            return "A restore of this profile stopped half way on \(date). Finish it or undo it first."
        case .switching:
            let imp = r.importedFrom != nil
            return "\(imp ? "An import" : "A restore") of this profile stopped half way on \(date). "
                + "Finish it or undo it first: once you leave the Switch page, the profile's tile in Settings opens its page."
        }
    }
}
