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
sw next              # one space right (prev = left), no wrap; BTT hyper+E / hyper+Q
bring messages       # move an app's windows to this space and focus it
send comms           # push the focused window to another space, stay put
stick                # focused window appears on every space (not the whole app)
unstick              # ... and back
stick list           # windows currently on all spaces

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

`sw`, `send` and `rm` resolve a space the same way: a bare number is an
ordinal first (so `sw 1` goes to Desktop 1 even when some space is named
"messaging1"), then exact name, name prefix, name substring, and finally
ordinal as a fallback for queries like `2fa` that only start with digits. `sw` verifies the switch actually landed before
returning, so it exits non-zero if the Dock ignored it (see Setup). All commands
exit 0 on success, 1 on a miss, and 2 on bad usage.

`stick` / `unstick` act on the focused window (or the focused window of a
named app) and need the SpaceToolSA payload running inside the Dock, because
only the Dock's connection can write the on-all-spaces window tag
(docs/window-on-all-spaces.md). Setup and the SIP prerequisite live in
docs/window-on-all-spaces.md:

```sh
make install-sa        # payload + sudoers-pinned injector + load it now
sudo nvram boot-args="-arm64e_preview_abi" && sudo reboot   # once, see docs/window-on-all-spaces.md
spacetool stick
```

Without the payload, `stick` exits 1 with the install hint; per-app assignment
(the native "All Desktops") remains available with no SIP changes through the
bridge op if ever needed as a stopgap.

The payload dies with the Dock, but re-injection is automatic now: the injector
lives at `~/Applications/SpaceTool.app/Contents/MacOS/loadsa`, pinned by a
sha256 sudoers entry (`make refresh-sa` regenerates it), and SpaceBadge watches
the Dock's pid and re-runs the pinned loadsa after every Dock restart. After a
rebuild that touches `loadsa.m`, re-run `make refresh-sa` or the pin goes stale
(SpaceBadge logs the sudo denial, `stick` falls back to the hint).

Display changes have their own wrinkle: plugging/unplugging a monitor rebuilds
the space set and collapses a stuck window back to its home space while its tag
still reads as stuck, so `stick` clears and re-sets the bit to force the server
to rebuild the membership. After a display change, re-run `stick` on windows
that stopped showing everywhere; a fully automatic re-apply is future work.

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

SpaceBadge also watches the Dock's pid on its 300ms tick and re-injects the
SA payload after every Dock restart (it waits for the Dock to finish launching,
settles ~1s, runs `sudo -n` on the pinned loadsa, then HELLO-checks the socket).
Failures are logged once per restart and visible via
`log show --predicate 'process == "SpaceBadge"'`.

Cadence: Mission Control state is polled every 300ms, and while MC is open the
strip is rebuilt on every poll so that reordering spaces inside it takes effect
immediately (the rebuild returns early when the text has not changed). The name
file is checked for changes every 2s, and a full resync runs every 15s. A resync also runs on
`NSWorkspaceActiveSpaceDidChangeNotification`, and 1s and 3.5s after
`NSApplicationDidChangeScreenParametersNotification` (a dock or undock fires it
repeatedly and `visibleFrame` keeps moving for a beat after the last one).

## SpaceView

`~/Applications/SpaceView.app`, kept alive by the LaunchAgent
`dev.umanzor.spaceview`. A resident stand-in for Mission Control's space
picker: `spacetool view` toggles a panel listing the spaces of the display
under the mouse, each with a preview, its number and its name. `1`-`9` or a
click on a space switch to it with no slide, Esc closes it. The right half is empty for now.

Mission Control is slow to show previews because the Dock renders them on
demand. SpaceView keeps them warm instead. `SLSHWCaptureSpace` captures any
space, off-screen ones included, in 50-170ms at 4608x2592 counting the
downscale to 960x540, so a capture never runs on the open path. The panel
shows what is cached and refreshes the current space in the background. Spaces
are captured at launch, when you leave them, the first time a new space is
shown, and the current one every 120s while idle. A cached preview is a
960x540 bitmap, nominally 2MB.

The capture leaves out every window that is on all spaces. `sharingType` makes
no difference; `canJoinAllSpaces` does (`spaceview --probe-sharing` measures
it). That is why the panel can refresh a preview while it is up without
landing in its own shot. By the same rule, windows pinned with `stick` should
be missing from previews (not checked yet).

The key tap is armed only while the panel is up. Unmodified digits up to the
last space and unmodified Esc are swallowed. Everything else passes through,
modifier+digit and digits past the last space included. A click switches on
mouse up inside the space it started on (dragging off cancels), takes the
same path as its digit, and does not activate SpaceView or take focus from
the front app; the first click works without focusing the panel. Without
Accessibility there is no tap, so the panel opens but ignores keys; a click
still switches, and `spacetool view` again closes it. Without Screen Recording
the cells show number and name only.

A digit switches through the payload's instant op under the same lock as `sw`.
If the payload is missing, older than v7, lacks the symbols, refuses the
switch, or the request cannot be written, it falls back to
`SpaceTool switch N`, but only for spaces on the first display, because `sw`
resolves a bare number against the first display that has it. A switch the
Dock accepted but CGS did not confirm within a second is not retried, since it
may still land.

With Mission Control open, the panel shows above it. A digit or click closes
MC first, then switches; one for the space you are on just closes MC.

Each open logs its latency (`/usr/bin/log show --predicate
'process == "SpaceView"'`; zsh has its own `log` builtin). `spaceview --bench
[passes]` prints capture timings, footprint and the IOSurface region count. A
leaked capture only shows up in that count, because captures are
IOSurface-backed and not charged to the footprint.

## How it works

Window moves go through the private SkyLight bridge class
`SLSBridgedMoveWindowsToManagedSpaceOperation` via
`SLSWindowManagementFallbackBridge`. The legacy CGS calls
(`CGSAddWindowsToSpaces` etc.) are dead for foreign windows on macOS 26; they
only work on windows you own.

Space switches do **not** go through the bridge. With payload v7, `sw` and
SpaceBadge's MC+digit switch instantly, with no slide: inside the Dock the
payload calls `SLSShowSpaces(dest)`, `SLSHideSpaces(source)` and
`SLSManagedDisplaySetCurrentSpace`, then writes the display's
`DockCore.DisplaySpaces._currentSpace` itself (yabai's `do_space_focus`). That
last write is what the bridged switch from outside could never do, and why it
desynced the Dock; from inside, Mission Control and ctrl-arrow stay in step.
The payload replies in under 5ms; `sw` returns in ~170-200ms, mostly process
startup and waiting for CGS to report the new space.

If the instant path is unavailable (payload older than v7, symbols missing,
or it refuses), `sw` falls back to the Dock's own animated
`-[Spaces switchToUserSpace:]` (payload v4+): the Dock performs the switch, one
slide of ~275-310ms whatever the distance, and queues a request that arrives
mid-animation instead of dropping it. `SPACETOOL_ANIMATE=1` forces that path.

Without the payload, `sw` falls back to synthesising the Dock's own swipe
control event (a `CGEvent` with field 110 set to subtype 23, posted to
`kCGSessionEventTap` once per space of travel), yabai's
`space_manager_focus_space_using_gesture`, and says so on stderr.
`SPACETOOL_SWIPE=1` forces that path. The swipe is relative and the Dock drops
swipes posted while it is still animating, so it is the weaker path: switches
are serialized under a lock with a 250ms settle, and MC+digit through the swipe
lands short when the jump starts during MC's dismissal.

Gotchas learned the hard way:

- The bridged ops are asynchronous. Passing one to
  `performSynchronousBridgedWindowManagementOperation:` traps in BoardServices
  XPC encoding.
- A freshly created window needs a runloop turn before a space assignment
  sticks.
- Ordering a window front while Mission Control is open dismisses Mission
  Control. The strip is pre-created at alpha 0 and toggled by alpha only.
  That was learned on SpaceBadge's strip. SpaceView's panel (level 101,
  `orderFrontRegardless`) does not dismiss MC on macOS 27; it shows above it.
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
- Mission Control swallows the Dock swipe gesture (the swipe fallback only). A
  switch issued while MC is up does nothing at all (it fails cleanly, it does not corrupt anything). To
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
(`sw.sh`, `bring.sh`, `send.sh`, `name-space.sh`, `list-spaces.sh`,
`create-space.sh`, `remove-space.sh`, `save-layout.sh`, `restore-layout.sh`).
They are not version controlled with this repo. The directory has to be added
once under Raycast's Script Commands settings. The create/remove/restore ones
need Raycast to hold the Accessibility grant, since TCC attributes their AX
calls to Raycast.

Binaries must live inside an .app bundle; the WindowManagement XPC service
rejects bare executables. `~/.local/bin/{spacename,sw,bring}` are shims into
SpaceTool.app.

**SpaceView.** `make view-dev` builds a signed `build/SpaceView.app` that
runs in place. `make install-view` bundles it into `~/Applications` only, and
`make install-view-agent` does that and loads its agent the same way
`install-agent` does for SpaceBadge (neither touches the other).
With a `codesign.env` identity the bundle identifier and designated
requirement match between the two, so grants made for one carry to the other
(adhoc signing gets no such carry-over). To get the Screen Recording and
Accessibility prompts, run
`open -n build/SpaceView.app --args --request-access` (or the installed path);
run directly from a terminal, TCC attributes the request to the terminal.

## Uninstall

```sh
make uninstall   # daemon, LaunchAgent, both bundles, all three shims
make uninstall-view   # SpaceView, its LaunchAgent and bundle
```

Two things it deliberately leaves: `~/.config/spacenames.json`, so your names
survive a reinstall (delete it if you want them gone), and SpaceBadge's entry in
the Accessibility list, which only you can remove.
