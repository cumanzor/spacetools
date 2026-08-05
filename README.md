# spacetools

Name macOS Spaces, switch to them by name or by pressing a digit in Mission
Control, create and remove them from the command line, and pull an app's
windows to the current Space. No SIP changes needed. Verified on macOS 26.5.

## Commands

```sh
spacename            # print current space name
spacename list       # all spaces, current marked with *
spacename set comms  # name the space you are on (empty name clears)
sw comm              # switch to space by name prefix or number
bring messages       # move an app's windows to this space and focus it
send comms           # push the focused window to another space, stay put

spacename create dev      # add a desktop at the end, optionally named
spacename rm dev          # remove a space; its windows merge to a neighbor
spacename layout save     # snapshot desktop count and names
spacename layout restore  # recreate missing desktops, reapply names
```

`create` and `rm` drive Mission Control's own UI through Accessibility: the
add button (`mc.spaces.add`) is a plain AXButton and every space thumbnail
carries an `AXRemoveDesktop` action, so the Dock performs the change itself
and stays coherent. Both open Mission Control for about a second and dismiss
it after. `rm` resolves its argument like `sw` does, refuses fullscreen app
spaces and the last desktop, and drops the removed space's entry from the
names file.

`layout restore` recreates desktops until the saved count is reached and
reapplies names by position. It never removes anything: extra desktops are
reported and left alone. The snapshot lives in `~/.config/spacelayout.json`.
Save one after settling on a layout; it is the one-command fix for macOS
eating your spaces during a display reconfiguration.

`bring` and `send` are opposites. `bring` pulls every window of a named app to
where you are and focuses it. `send` pushes the one window you are looking at
somewhere else and leaves you where you are.

Names live in `~/.config/spacenames.json`, keyed by space UUID (stable across
reboots, unlike ManagedSpaceIDs).

`sw` and `send` resolve a space the same way: exact name, name prefix, name
substring, then ordinal. `sw` verifies the switch actually landed before
returning, so it exits non-zero if the Dock ignored it (see Setup). All commands
exit 0 on success, 1 on a miss, and 2 on bad usage.

`send` takes the frontmost window, which it finds by asking for onscreen windows
(they come back front to back, and "onscreen" already means the current space)
and taking the first one at layer 0 bigger than 120x120. So it acts on whatever
you are actually looking at, which is not always the app you were thinking of.

## SpaceBadge daemon

`~/Applications/SpaceBadge.app`, kept alive by the LaunchAgent
`dev.umanzor.spacebadge`. Shows a translucent name badge in the top-right of
each named space, plus a name strip under the Mission Control spaces bar.

It also takes `1`-`9` while Mission Control is open and switches to that space.
The key tap is created disabled and only armed between the MC-open and MC-close
edges, so it is inert the rest of the time. This needs Accessibility; without it
`CGEventTapCreate` returns NULL and only this feature is lost.

Cadence: Mission Control state is polled every 300ms, and while MC is open the
strip is rebuilt on every poll so that reordering spaces inside it takes effect
immediately (the rebuild returns early when the text has not changed). The name
file is checked for changes every 2s, and a full resync runs every 15s. A resync also runs on
`NSWorkspaceActiveSpaceDidChangeNotification`, and 1s and 3.5s after
`NSApplicationDidChangeScreenParametersNotification` (a dock or undock fires it
repeatedly and `visibleFrame` keeps moving for a beat after the last one).

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
- An NSTextField sized by its superview's autoresizing mask will silently clip
  when you swap in text of the same width. Reordering spaces rearranges the same
  glyphs, so the window never resizes, so autoresizing never fires, so the label
  keeps a width that belonged to some older string. Set the label's frame
  explicitly whenever the text changes, and leave it a couple of points of
  slack: the field's cell wants slightly more room than
  `-[NSAttributedString size]` reports.
- `NSWindow.frame` lies after a display change. The window server relocates your
  windows and AppKit keeps reporting the old rect, so `setFrame:` to the rect
  AppKit already believes it has is a no-op and the window never comes back.
  Decide position against `CGWindowListCopyWindowInfo`, and set an offset rect
  first to force the move through.
- `CGSSpaceSetName` exists but writes the space UUID field. Do not use it.
- `SLSSpaceCreate` / `SLSSpaceDestroy` have the same flaw as the bridged
  switch: the window server obeys and the Dock never hears about it. Create
  and remove through Mission Control's accessibility tree instead. The Dock
  exposes `mc` > `mc.display` (one per screen, matched to a display by AX
  origin against `CGDisplayBounds`) > `mc.spaces` > `mc.spaces.list` plus
  `mc.spaces.add`, and each thumbnail in the list carries an `AXRemoveDesktop`
  action, so no hover-for-the-close-button choreography is needed.
- Under ARC at -O2, the temporary NSArray a helper returns can be freed the
  moment fast enumeration over it ends. Hold an element you mean to keep as a
  strong `id` before `CFRetain`ing it, or you retain a dead AXUIElement and CF
  traps with EXC_BREAKPOINT. Invisible at -O0, which is exactly what makes it
  nasty.

## Setup

```sh
make install-agent   # everything: build, bundle, shims, LaunchAgent, reload
```

`make install` alone does the build, the `~/Applications` bundles and the
`~/.local/bin` shims, but leaves the daemon and its LaunchAgent untouched.
`install-agent` runs that first, then writes
`~/Library/LaunchAgents/dev.umanzor.spacebadge.plist` and reloads the daemon.
It is idempotent, so it is also the right way to restart after a rebuild.

**Codesigning matters here.** Copy `codesign.env.example` to `codesign.env`
(gitignored) to sign with a real identity. Adhoc signing works, but SpaceBadge
needs an Accessibility grant for the Mission Control digit switching, and an
adhoc signature changes on every build, so macOS drops the grant each time you
rebuild. The designated requirement is pinned to the team OU, which is what
keeps the grant across rebuilds and cert renewals.

**Accessibility.** SpaceBadge prompts on first launch. Grant it under System
Settings > Privacy & Security > Accessibility. Only the digit switching depends
on it. Badges, the strip, and `spacename` / `bring` all work without it.

`sw` posts CGEvents too, so it needs the grant as well, but TCC attributes those
to whatever launched it (Raycast, your terminal) rather than to SpaceTool, and
those apps usually already have it.
If it ever prints `the Dock ignored the gesture`, grant Accessibility to the
calling app, or to `~/Applications/SpaceTool.app` if you are running the binary
directly.

`create`, `rm` and `layout restore` read the Dock's accessibility tree, which
is gated the same way with the same attribution rules. They print a grant
message and exit 1 when it is missing.

**LaunchAgent.** `make install-agent` writes the plist (`RunAtLoad` +
`KeepAlive`) and reloads the daemon with bootout then bootstrap. Never use
`kickstart -k` after a rebuild: launchd caches the old cdhash and it dies with
`OS_REASON_CODESIGNING`.

**Raycast.** Scripts live in `~/Documents/scripts/Raycast`
(`sw.sh`, `bring.sh`, `send.sh`, `name-space.sh`, `list-spaces.sh`). They are not
version controlled with this repo. The directory has to be added once under
Raycast's Script Commands settings.

Binaries must live inside an .app bundle; the WindowManagement XPC service
rejects bare executables. `~/.local/bin/{spacename,sw,bring}` are shims into
SpaceTool.app.

## Uninstall

```sh
make uninstall   # daemon, LaunchAgent, both bundles, all three shims
```

Two things it deliberately leaves: `~/.config/spacenames.json`, so your names
survive a reinstall (delete it if you want them gone), and SpaceBadge's entry in
the Accessibility list, which only you can remove.
