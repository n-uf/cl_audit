// Unfinished: what stopped half way on a profile, as every flow's start check sees it. Each flow leaves its own receipt
// (a switch: switches/, a restore or import: restores/, the move to the default profile: default-moves/), and none of them
// may start another on top of one that is open: the later Undo or Finish would meet files it didn't write.
//
// Who holds whom back:
//   - a restore or import (and its Undo, and the folder pick that follows it) waits for another restore or import of the
//     profile that stopped half way: its words stay as they were;
//   - a switch waits for a restore or import of the profile that stopped half way, and for the move to the default profile
//     when the profile is the new default or the one it came from, and says which one and where to finish or undo it;
//   - a switch that stopped half way holds no restore or import back (an old one can't be finished or undone, and a new
//     one has its own Undo and Leave it as it is on the Sessions card): the Switch page says it on its own, with the words
//     for signing in as the account it went for, so this check leaves it out;
//   - the move's own restore is not held back by the move's record (the record is open while its restore runs); the restore
//     receipt it wrote is what holds the others back;
//   - a re-point's receipt has no Finish and no Undo from a page until it is finished, so it holds nothing back; a window
//     held closed for one is the window marker's business (SwitchMarker).
// Export only reads, so it asks nothing.

import Foundation

enum Unfinished {
    /// The flow that asks.
    enum Flow {
        case switching                  // an account switch (the Switch page, SwitchEngine.run under its lock)
        case restoring                  // a restore, an import, their Undo, the folder pick, the default-profile move's restore
    }

    /// Why a flow of this profile may not start, or nil. `except`: the receipt of the restore the caller is itself finishing
    /// or undoing.
    static func blocker(profile: String, except id: String? = nil, for flow: Flow) -> String? {
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
