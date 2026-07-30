# spacetools

Name macOS Spaces, switch to them by name, and pull an app's windows to the
current Space. No SIP changes needed. Verified on macOS 26.5.

## Commands

```sh
spacename            # print current space name
spacename list       # all spaces, current marked with *
spacename set comms  # name the space you are on (empty name clears)
sw comm              # switch to space by name prefix or number
bring messages       # move an app's windows to this space and focus it
```

Names live in `~/.config/spacenames.json`, keyed by space UUID (stable across
reboots, unlike ManagedSpaceIDs).

## SpaceBadge daemon

`~/Applications/SpaceBadge.app`, kept alive by the LaunchAgent
`dev.umanzor.spacebadge`. Shows a translucent name badge in the top-right of
each named space, plus a name strip under the Mission Control spaces bar.

It also takes `1`-`9` while Mission Control is open and switches to that space.
The key tap is created disabled and only armed between the MC-open and MC-close
edges, so it is inert the rest of the time. This needs Accessibility; without it
`CGEventTapCreate` returns NULL and only this feature is lost.

## How it works

Window moves go through the private SkyLight bridge class
`SLSBridgedMoveWindowsToManagedSpaceOperation` via
`SLSWindowManagementFallbackBridge`. The legacy CGS calls
(`CGSAddWindowsToSpaces` etc.) are dead for foreign windows on macOS 26; they
only work on windows you own.

Space switches do **not** go through the bridge. `sw` synthesises the Dock's own
swipe control event (a `CGEvent` with field 110 set to subtype 23, posted to
`kCGSessionEventTap` once per space of travel) so that the Dock performs the
switch. This is yabai's `space_manager_focus_space_using_gesture`, the fallback
it uses when the scripting addition is unavailable. The velocity field is set
absurdly high (9999) which skips the slide animation, so a multi-space jump is
still fast.

Gotchas learned the hard way:

- The bridged ops are asynchronous. Passing one to
  `performSynchronousBridgedWindowManagementOperation:` traps in BoardServices
  XPC encoding.
- A freshly created window needs a runloop turn before a space assignment
  sticks.
- Ordering a window front while Mission Control is open dismisses Mission
  Control. The strip is pre-created at alpha 0 and toggled by alpha only.
- Mission Control detection: Dock gains onscreen windows at layer 18 while MC
  is up. Polled at 300ms.
- Do not switch spaces with `SLSBridgedManagedDisplaySetCurrentSpaceOperation`.
  It moves the window server and nothing else. The Dock keeps its own
  current-space index and no op in the bridge tells it otherwise (all 100
  `SLSBridged*` classes were dumped looking for one). The two then disagree:
  `spacename` reports the new space while Mission Control still highlights the
  old one, draws ghost previews instead of live thumbnails, and ctrl-arrow steps
  from the wrong desktop. Adding the rest of the window-server handshake
  (`WillSwitchSpaces` / `ShowSpaces` / `HideSpaces` / `SpaceResetMenuBar`) fixes
  the compositing but not the Dock. Let the Dock do the switch instead. An
  earlier changelog blamed this on "switching while MC is open"; that was wrong,
  the desync happens on every bridged switch and MC just makes it visible.
- Mission Control swallows the Dock swipe gesture. A switch issued while MC is
  up does nothing at all (it fails cleanly, it does not corrupt anything). To
  switch from inside MC you have to dismiss it and poll until it is really
  closed first, then switch.
- `NSWindow.frame` lies after a display change. The window server relocates your
  windows and AppKit keeps reporting the old rect, so `setFrame:` to the rect
  AppKit already believes it has is a no-op and the window never comes back.
  Decide position against `CGWindowListCopyWindowInfo`, and set an offset rect
  first to force the move through.
- `CGSSpaceSetName` exists but writes the space UUID field. Do not use it.

## Build

```sh
make install   # builds, bundles to ~/Applications, shims to ~/.local/bin
```

Copy `codesign.env.example` to `codesign.env` (gitignored) to sign with a real
identity, otherwise it falls back to adhoc. Nothing here needs a TCC permission
today, so adhoc is fine; the stable path exists so that a future feature that
does need one won't have its grant reset by every rebuild.

Binaries must live inside an .app bundle; the WindowManagement XPC service
rejects bare executables. `~/.local/bin/{spacename,sw,bring}` are shims into
SpaceTool.app.

Raycast scripts live in `~/Documents/scripts/Raycast` (already registered as a
Script Commands directory).
