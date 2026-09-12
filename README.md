# EllesmereUIChatNotify

Plays a sound when a chat message arrives. A companion module for the
[EllesmereUI](https://www.curseforge.com/wow/addons/ellesmereui) suite.

Every chat stream gets its own on/off toggle and sound. On top of that, a
watchlist of keywords and sender names fires a different sound on *any* stream,
including ones whose own sound is turned off — so guild chat can stay quiet
while "someone said my name" still pings.

## Layout

```
source/                 what ships; the deploy script mirrors this folder
  *.toc                 addon manifest
  *.lua                 engine + options window
build/deploy.cmd        robocopy /MIR into the game's AddOns folder
.vscode/                Lua language server config + the deploy task
```

`source/` is deployed to `Interface\AddOns\EllesmereUIChatNotify`, so the folder
name lives in the deploy arguments rather than in the source tree. The `.toc`
filename must keep matching the deployed folder name.

## Building

`Ctrl+Shift+B` in VS Code, or:

```
build\deploy.cmd "<repo>\source" "<wow>\_retail_\Interface\AddOns\EllesmereUIChatNotify"
```

`/MIR` means the target is mirrored, deletions included. The script refuses a
drive root or the `AddOns` folder itself, but the target argument is still
destructive — point it at this addon's own folder.

Reload the UI (`/reload`) after deploying.

## Why it has its own settings window

It would be nicer to appear as a page inside EllesmereUI's own options panel,
and that is not available to a third-party addon:

- `EllesmereUI:RegisterModule()` checks the calling addon's folder against a
  hardcoded allowlist and silently returns for anything not in it.
- The options sidebar is built from a fixed roster (`EllesmereUI.ADDON_GROUPS`),
  so an unlisted folder has no button to click even if registration succeeded.

Patching either would be undone by every EllesmereUI update. So the settings
live in our own window (`/chatnotify`, or `/cn`), built with EllesmereUI's
widget factory — `EllesmereUI.Widgets`, from the LoadOnDemand
`EllesmereUIOptions` addon — so it still reads as part of the suite.

The window chrome uses EllesmereUI's own visual primitives — `MakeFont` (so
text is Expressway, not a Blizzard font), `SolidTex`, `MakeBorder`, and
`ELLESMERE_GREEN` for the accent — rather than reproducing the look by hand.
`EllesmereUI_WindTools`, an ElvUI plugin ported onto EllesmereUI, is a useful
reference here: it hits the same registration wall and builds its own panel
from the same primitives.

Reaching that factory means calling `EllesmereUI:EnsureLoaded()`, never
`LoadAddOn` directly. Every options file wraps its whole body in a closure
queued onto `EllesmereUI._deferredInits`, and only `EnsureLoaded` drains that
queue — so loading the addon by hand succeeds while leaving
`EllesmereUI.Widgets` nil. It also brings up the unlock core the factory
depends on, and covers standalone builds where no `EllesmereUIOptions` exists.

Everything else the parent offers is open to us and is used directly:
`EllesmereUI.Lite` for the addon object, events and database; its alert-sound
catalogue plus LibSharedMedia for the sound list; and the shared profile store,
which means profile switching re-points our settings along with the rest of the
suite at no cost.

## Notes

- Requires EllesmereUI. Without it, the addon loads and goes dormant rather
  than erroring.
- EllesmereUIChat plays one sound for *both* whispers and Battle.net whispers,
  from a single `whisperSoundKey`. Enabling either of our whisper streams would
  make a whisper ping twice, so we take the stream over: their key is parked in
  our profile and set to `none`, and handed back as soon as neither of our
  whisper streams is live. If something else has set a sound there in the
  meantime, theirs wins and we drop our copy.
