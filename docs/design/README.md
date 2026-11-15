# Design notes

Sketches and design pages for cl_audit, kept as single self-contained HTML files. Open one in a browser. They use
sample addresses only (ann@example.com and the like); no real accounts appear in them.

A sketch shows what was proposed at the time. The app and the CHANGELOG say what shipped.

## Current

- [ui-fixes-2026-11.html](ui-fixes-2026-11.html): approved 2026-11-15. The dashboard card, Settings ▸ Accounts and the
  card states (signed in, a different account in Terminal, signed out or expired, the Keychain not handing the sign-in
  over, a switch with one step left).

## App sketches

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
- [settings-sidebar-1A.html](settings-sidebar-1A.html): the Settings sidebar, kept for later.

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
