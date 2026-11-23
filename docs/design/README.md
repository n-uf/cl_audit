# Design notes

Sketches and design pages for cl_audit, kept as single self-contained HTML files. Open one in a browser. They use
sample addresses only (ann@example.com and the like); no real accounts appear in them.

A sketch shows what was proposed at the time. The app and the CHANGELOG say what shipped.

## Current

- [ui-fixes-2026-11.html](ui-fixes-2026-11.html): approved 2026-11-15. The dashboard card, Settings ▸ Accounts and the
  card states (signed in, a different account in Terminal, signed out or expired, the Keychain not handing the sign-in
  over, a switch with one step left).

## App sketches

- [accounts-two-apps-sketch.html](accounts-two-apps-sketch.html): Settings ▸ Accounts when the Claude app and Terminal
  are on different accounts. Approved 2026-11-23; being built. The split is a warning in amber: one zone from the panel's
  top edge with the ACCOUNTS header inside it, Terminal's account (its numbers, a TERMINAL | APP badge, not selectable,
  Sign the app in) and the Claude app's (Sign Terminal in, the two keys at one width), then the standby accounts with
  today's mint selection; red stays for signed out or expired. ACCOUNTS and FOLDER are their own sections (CLAUDE CODE
  goes), one line per section header. Also the after states, today vs proposed, the Dock icon's panel (one window key with
  the card) and its six-item menu, the dashboard card and the menu bar row.

- [at-limit-sketch.html](at-limit-sketch.html): what a card shows while a limit is full.
- [inuse-look-sketch.html](inuse-look-sketch.html): how the account in use is marked.
- [switch-ux-sketch.html](switch-ux-sketch.html): the Switch page.
- [move-resume-gaps-sketch.html](move-resume-gaps-sketch.html), [session-move-sketch.html](session-move-sketch.html):
  moving sessions between profiles.
- [quick-chat-sketch.html](quick-chat-sketch.html), [quick-chat-followups-sketch.html](quick-chat-followups-sketch.html):
  quick chat.
- [large-widget-sketch.html](large-widget-sketch.html): the large widget.
- [strip-display-sketch.html](strip-display-sketch.html), [app-top-strip-sketch.html](app-top-strip-sketch.html): the
  usage strip.
- [app-icon-sketch.html](app-icon-sketch.html), [alpha-mark-sketch.html](alpha-mark-sketch.html): the app icon and
  mark.
- [login-security-badge-sketch.html](login-security-badge-sketch.html): the sign-in security badge.
- [profile-colours-sketch.html](profile-colours-sketch.html): where a profile's colour shows (dot, edge, edge and wash);
  not decided yet.
- [profile-colours-2-sketch.html](profile-colours-2-sketch.html): round 2, on today's Settings tile bar: a dot before the
  name plus a light or stronger tint of the key face, with or without a foot line; not decided yet.
- [settings-sidebar-1A.html](settings-sidebar-1A.html): the Settings sidebar, kept for later.

Older sketches (earlier rounds, kept for the record):

- [app-faces-sketch.html](app-faces-sketch.html): the app's faces (Dock icon, window, menu bar).
- [app-dock-off-sketch.html](app-dock-off-sketch.html): what a profile shows when its Dock icon is hidden.
- [app-watch-only-sketch.html](app-watch-only-sketch.html): what a profile includes, and a usage-only profile.
- [change-account-sketch.html](change-account-sketch.html), [change-account-sketch-2.html](change-account-sketch-2.html):
  changing a profile's account (Profile settings ▸ Claude Code), rounds 1 and 2.
- [cleanup-uninstall-updates.html](cleanup-uninstall-updates.html): clean-up, uninstall and Claude updates.
- [general-settings-sketch.html](general-settings-sketch.html): Settings ▸ General, with About in column 1.
- [profile-seat-design.html](profile-seat-design.html): profiles and Claude account seats.
- [profile-sketch.html](profile-sketch.html): a profile's Dock icon and Claude window.
- [settings-harmonize-sketch.html](settings-harmonize-sketch.html): profile settings in one pattern.
- [settings-widget-sketch.html](settings-widget-sketch.html), [sketch-round2.html](sketch-round2.html): settings,
  widget and menu bar sketches, and round 2.
- [unsaved-name-sketch.html](unsaved-name-sketch.html): a name or label changed but not saved.

## Architecture

- [architecture/architecture-review.html](architecture/architecture-review.html): processes, files and the target
  layering (app, flow engines, ProfileCore, safe files).
- [architecture/profilecore-audit.html](architecture/profilecore-audit.html): the profile and account rules, and the
  steps to the shared library.
- [architecture/architecture-concept.html](architecture/architecture-concept.html): the earlier concept.
- [architecture/switch-atlas.html](architecture/switch-atlas.html): every screen around a switch.
- [architecture/session-move.html](architecture/session-move.html),
  [architecture/session-export.html](architecture/session-export.html): moving and exporting sessions.
- [architecture/transplant-research.html](architecture/transplant-research.html): what claude-transplant does
  (session transfer), as a reference.

## Site

Sketches for cl-audit.n-uf.com, in [site/](site/).

## Rules

- One profile, one folder: a profile has exactly one Claude Code folder, and cl_audit never creates extra or hidden
  folders for its accounts. Standby accounts are never read.
- No huge buttons: actions are compact keys.
