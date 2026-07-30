[2026-07-30 21:12:12 UTC] [spacetool/send verb, plus install-agent and uninstall targets]
[Attempt #1]
[Files Changed]
- spacetool.m:214-236 - cmdSend(). Resolves the destination with the existing
  matchSpace(), then moves the frontmost window with the existing
  moveWindowsToSpace(). No new machinery; bring was already this operation with
  the destination pinned to the current space.
- spacetool.m:259 - wired into main, usage string updated.
- Makefile:50,52 - send shim written and chmodded alongside the other three.
- Makefile:56-72 - install-agent target: runs install, writes the LaunchAgent
  plist from $(APPS), plutil -lints it, then bootout followed by bootstrap.
- Makefile:74-80 - uninstall target, using the same $(APPS)/$(BIN)/$(AGENT)
  variables install writes with so the two cannot drift.
[Design]
send takes the focused window rather than a named app. Two arguments
(`send <app> <space>`) would have been symmetric with bring, but arg is built by
joining argv with spaces and both app names ("Spark Mail") and space names can
contain them, so it would have needed a delimiter or a --to flag. One argument
parses cleanly and matches the common idiom (yabai's window --space).
It does not follow the window. Sending is usually about clearing your screen,
and `sw` is right there if you want to go too.
The frontmost window comes from CGWindowListCopyWindowInfo with
kCGWindowListOptionOnScreenOnly: results are ordered front to back, and
"onscreen" already restricts to the current space, so the first layer-0 window
over 120x120 is what the user is looking at. Same size and layer filter bring
uses.
[Possible Ripple Effects]
- send acts on whatever is frontmost, which is not always what you meant. Found
  this during testing: running `send 4` from the comms space moved Slack, not
  the test window, because Slack was in front. It prints what it moved, which is
  the only real mitigation. Documented in README and CHEATSHEET.
- `send` is a fairly generic name for something on PATH. Checked, nothing else
  in PATH claims it on this machine.
- No Raycast script command for send yet; the other four live outside this repo
  in ~/Documents/scripts/Raycast.
[Testing Notes]
- Error paths: no arg exits 2, unknown space exits 1, target already current
  prints "already on X" and exits 0.
- Functional: opened a throwaway Finder window on personal, confirmed it was
  first in the front-to-back list, `send comms` moved it, CGSCopySpacesForWindows
  confirmed it landed on space 3, and the current space did not change.
- Ordinal form works (`send 4` resolved through matchSpace's ordinal branch).
- install-agent: generated plist is semantically identical to the hand-made one
  (plutil -convert json diff empty), lints clean, second run exits 0, and digit
  switching still worked afterwards, so the Accessibility grant survives the
  re-sign as the pinned designated requirement intends.
- uninstall: exercised against a throwaway tree by overriding APPS, BIN and
  AGENT. Everything removed, real install untouched. Note the launchctl bootout
  line targets the label, so it stops the real daemon even when the paths are
  overridden.

[2026-07-30 19:00:08 UTC] [SpaceBadge/Digit switching from Mission Control, reinstated]
[Attempt #3 - see the 2026-07-20 entry for attempts #1 and #2]
[Files Changed]
- spacebadge.m:96-100 - keyTap, mcArmed, maxOrd globals.
- spacebadge.m:102-108 - postEscape().
- spacebadge.m:110-114 - digitForKeycode(), ANSI number row 1..9.
- spacebadge.m:116-129 - switchToOrd(). Posts escape, then waits on a background
  queue until mcOpen() is false before spawning SpaceTool switch <n>. Spawning
  reuses the tested switch path rather than duplicating the gesture code.
- spacebadge.m:131-144 - tapCallback(). Passes everything through unless MC is
  armed; ignores any digit carrying a modifier or past maxOrd; returns NULL to
  swallow the ones it acts on.
- spacebadge.m:146-155 - installTap(), created disabled.
- spacebadge.m:275-283 - tick() arms and disarms the tap on the MC edge.
- spacebadge.m:246 - maxOrd tracked in showStrip, so a digit past the last space
  falls through instead of doing nothing visible.
- spacebadge.m:395-399 - Accessibility check with prompt, then installTap().
[Why this works now when it did not on 2026-07-20]
The earlier attempt switched with the SkyLight bridge, which desyncs the Dock
(see the 18:46:50 entry). That desync was misattributed to "switching while MC is
open" and killed the feature. With sw now driving the Dock's own gesture, the
Dock stays coherent, so the feature is viable again. The tap half was always
fine, as that entry recorded.
[The one real constraint]
Mission Control swallows the Dock swipe gesture. Tested directly: with MC open,
`sw comms` posted its gesture, nothing happened, and the new verification loop
returned 1. So the switch cannot merely overlap MC teardown, MC has to be gone
first. Hence escape, then poll mcOpen() until false (up to 2s), then switch.
This is the sequence the 2026-07-20 entry designed but never tested.
[Possible Ripple Effects]
- SpaceBadge needs Accessibility again. The grant from the reverted attempt was
  still present and worked immediately, which is what the pinned-to-OU codesign
  requirement was added for. Without it CGEventTapCreate returns NULL, installTap
  gives up, and everything else in the daemon is unaffected.
- A session-wide keyDown tap now exists. It is created disabled and only enabled
  between the MC-open and MC-close edges in tick(), so it is inert the rest of
  the time. Verified: with MC closed, a posted "4" did not switch spaces.
- Re-enables itself on kCGEventTapDisabledByTimeout, which the window server will
  do if a callback ever runs long.
- Digits are swallowed only when acted on. Out of range digits pass through, so
  they still reach anything behind MC.
[Testing Notes]
All verified by screenshot and by observed space, not by API read alone.
- 1 pressed in MC on unified -> MC closed, landed on comms.
- 4 pressed in MC -> landed on unified. MC bar afterwards highlights Desktop 2
  following a 2 press, and the MC render is all real scaled thumbnails with no
  ghost rectangles and no stuck chrome.
- 9 pressed with only 6 spaces -> space unchanged and MC stayed open.
- 4 pressed with MC closed -> space unchanged.

[2026-07-30 18:46:50 UTC] [SpaceBadge/Badges and MC strip survive a display change]
[Attempt #1]
[Files Changed]
- spacebadge.m:11,17,20 - CopySpacesFn typedef, copySpacesF global, settle timer
  property.
- spacebadge.m:61-77 - serverFrames(). Returns our own windows' real geometry
  from CGWindowListCopyWindowInfo, converted from CG top-left coords to AppKit
  bottom-left (AppKit y = screens[0].height - cg.y - cg.height).
- spacebadge.m:143-149 - place:at:server:. Compares the wanted frame against the
  window server's rect, not NSWindow.frame, and applies it via an offset rect
  first.
- spacebadge.m:151-159 - ensureSpace:sid:. Re-issues the bridged move if a badge
  is no longer on its space.
- spacebadge.m:191-193 - sync() calls both for existing badges. The old code only
  called setFrame: when the name string changed, so a recomputed frame was
  discarded on every other sync.
- spacebadge.m:221-224 - the strip anchors to screens[0] instead of
  [NSScreen mainScreen], and goes through place: too.
- spacebadge.m:244-253 - screensChanged, debounced 1s with a second sync 2.5s
  later; wired to NSApplicationDidChangeScreenParametersNotification in main.
- spacebadge.m:174,225 - left-edge clamp on both frames so a long name or a wide
  strip cannot run off a narrower internal display.
[Root cause]
Two bugs stacked. The daemon never observed screen parameter changes at all, so
nothing recomputed on dock/undock. Worse, when a display change moves one of our
windows, the window server relocates it but NSWindow.frame keeps reporting the
old rect - so the NSEqualRects(w.frame, frame) guard in sync() saw no difference
and skipped the repair, forever. Every badge and the strip were sitting at CG
0,0 (top-left, over the menu bar and over the MC chrome) through hundreds of 15s
syncs.
[Why the obvious fix does not work]
Dropping the NSEqualRects guard is not enough. Measured in a standalone harness:
move a window with SLSMoveWindow behind AppKit's back, then call
[w setFrame:want display:YES] with the rect AppKit already believes it has, and
AppKit short circuits - the window stays displaced. Setting an offset rect first
(or recreating the window) is what actually moves it.
[Possible Ripple Effects]
- sync() now issues setFrame: twice per corrected window. Only on mismatch, so
  steady state is unchanged; measured 0.1% CPU and no drift or space churn across
  two sync cycles.
- ensureSpace re-asserts space membership every sync. Guarded by a
  CGSCopySpacesForWindows read, so no bridged XPC unless something moved.
- serverFrames enumerates the full window list once per sync (every 15s, on
  space change, on map change, on screen change). Filtered to our own pid.
[Testing Notes]
- Reproduced the exact symptom first: probe showed all five badge windows and the
  strip at CG bounds 0,0, and a screenshot confirmed the badge drawn over the top
  left of the menu bar.
- Proved the stale-frame mechanism in a harness: after SLSMoveWindow to 0,0,
  NSEqualRects(w.frame, want) was still YES.
- Live daemon repositioning verified by renaming a space in spacenames.json: the
  badge went 2040,44 236x67 -> 1559,44 717x67, right edge still pinned at 2276.
  Restored, and it went back.
- Screenshots confirm badge top-right and the MC strip centred and clear of the
  Desktop 1-6 chrome.
- Not verified locally: a real dock/undock. SLSMoveWindow is silently a no-op
  across processes so the running daemon cannot be displaced from outside, and a
  real resolution change would shuffle the whole window layout. The screen
  parameter observer is wired but has only been exercised by the periodic sync.

[2026-07-30 18:46:50 UTC] [spacetool/sw switches through the Dock, not the bridge]
[Attempt #2 - Attempt #1 in this session was the bridged handshake below, which failed]
[Files Changed]
- spacetool.m:65-79 - bridgedOp(NSString*, id) became bridgedOps(NSArray*) plus a
  one-arg bridgedOp(id). Several ops can now go out in a single bridge
  transaction. Only `bring` still uses it; the switch path no longer does.
- spacetool.m:81-98 - currentSpaceOnDisplay() and displayIDForIdent(). The old
  code took the globally current space as the origin for a switch, which is
  wrong once a second display has its own current space.
- spacetool.m:100-146 - switchToSpace() rewritten. Computes the ordinal delta on
  the target's display and posts that many Dock control gesture events, then
  polls up to 2s for the switch to actually land before returning 0.
[Root cause]
SLSBridgedManagedDisplaySetCurrentSpaceOperation moves the window server and
nothing else. The Dock keeps its own current-space index and there is no op in
the SkyLight bridge that tells it otherwise - all 100 SLSBridged* classes were
dumped and none touch the Dock. So CGS and the Dock diverge: `spacename`
correctly reported the new space while Mission Control still highlighted the old
one, drew ghost previews instead of live thumbnails, and ctrl-arrow stepped from
the wrong desktop (personal -> 6 instead of comms -> 2). This is also what the
2026-07-20 entry below was actually seeing. That entry blamed "switching while MC
is open"; the truth is the desync exists after every bridged switch, and having
MC open just makes it visible.
[What was tried first, and why it was not enough]
The full window-server handshake in one transaction: WillSwitchSpaces ->
ShowSpaces -> SetCurrentSpace -> HideSpaces -> SpaceResetMenuBar. That did fix
the compositing half - no stuck spaces bar, no cross-space composite, badges
correct across four switches - but the Dock was still stale, because every one
of those ops is window-server side. Screenshot of MC after the switch showed
Desktop 5 highlighted while CGS said Desktop 1.
[The fix]
yabai hit the same wall (src/space_manager.c). Its preferred path is the
scripting addition, which injects into Dock and needs SIP down. Its SIP-on
fallback, space_manager_focus_space_using_gesture, synthesises the Dock's own
swipe control event so the Dock performs the switch and stays coherent by
construction. Ported here: CGEventCreate(NULL), field 55 = 30 (gesture), field
110 = 23 (dock control subtype), 123 = 1, 124 = sign, 129 = sign * 9999.0, then
per step field 132 = 1 (began) and 132 = 4 (ended), posted to kCGSessionEventTap.
The 9999 velocity is what skips the slide animation.
[Possible Ripple Effects]
- Switching is now relative, not absolute: N spaces away costs N gesture pairs.
  Still fast (personal -> comms, 4 spaces, measured 0.255s total vs 0.6s of fixed
  sleep before) because the velocity skips the animation.
- Fullscreen spaces count as steps. spaceInfos() already ords every space
  regardless of type, so the delta matches what the Dock will do.
- CGEventPost may require Accessibility depending on the responsible process.
  It worked ungranted when spawned from iTerm2, which likely means TCC
  attributed it to iTerm2. From Raycast it may prompt. switchToSpace now returns
  1 with an explicit "grant Accessibility to ~/Applications/SpaceTool.app"
  message instead of silently doing nothing. Codesigning is already pinned to
  the team OU so the grant will survive rebuilds - that is what it was for.
- The switch is verified before returning, so `sw` can now fail. It could not
  before; it slept 0.6s and returned 0 unconditionally.
[Testing Notes]
Verified by screenshot, per the rule the 2026-07-20 entry learned the hard way.
personal -> unified: MC bar highlights Desktop 4 (unified is ord 4), previews
render as real scaled thumbnails, no ghost rectangles. personal -> comms across
4 spaces: MC highlights Desktop 1. Menu bar showed iTerm2 on the unified space,
which is correct and not a regression - CGSCopySpacesForWindows confirms iTerm2
holds two windows on space 335.

[2026-07-20 17:40:13 UTC] [SpaceBadge/Digit switching from Mission Control, built then reverted]
[Attempt #1 built, Attempt #2 reverted]
[Files Changed]
Net effect on spacebadge.m is nil: postEscape, switchToOrd, the CGEventTap
(tapCallback/installTap), the keyTap/mcArmed/maxOrd globals, the tick arming,
the maxOrd tracking in showStrip and the accessibility prompt in main were all
added and then removed again. Two pieces of the work were kept because they
stand on their own:
- spacebadge.m:74-81 - mcOpen() as a plain C function, with
  -[Badger missionControlOpen] now a one line forwarder.
- spacebadge.m:83-101 - bridgedOp() split out of bridgedMoveWindow, so op
  construction is the only thing that differs between bridged calls.
- Makefile:28-41, codesign.env.example, .gitignore - stable codesigning kept.
  It was added because the event tap needed Accessibility and TCC keys the
  grant to the signature. Nothing needs a TCC permission now, so it is just
  hygiene for the next thing that does.
[What was tried]
Bare 1-9 while MC is up, consumed by a session-level event tap armed only while
MC is open, switching via the same SLSBridgedManagedDisplaySetCurrentSpaceOperation
that `sw` uses. The tap half worked correctly and was never the problem.
[Why it was reverted]
A bridged space switch issued while Mission Control is open corrupts
WindowServer. Symptoms: the MC "Desktop 1-5" bar stays drawn across the top
after MC exits, two apps' menu bars render interleaved (captured iTerm2 and Arc
overlaid glyph for glyph), and windows from several spaces composite onto one
screen. Reproduced on every attempt with a single-process harness, so it is not
a race with the escape or with process spawning.
Repair attempts that did not work: posting escape after the switch, killall Dock
(twice), activating another app, plain `sw` space switches, a clean MC open and
close cycle. What does clear it is a real user-driven space switch, per Carlos.
[Testing Notes / process failure]
The first round of testing passed 6 for 6 and was worthless. It probed
CGWindowList and `spacename` and never looked at the screen, so it could not see
that every one of those runs was corrupting the session. The corruption was only
found when Carlos reported it and a screenshot was taken. Anything that changes
what the compositor draws has to be verified with a screenshot, not an API read.
A second wrong inference came from the same gap: the README claimed a bridged
switch dismisses MC and that `sw` only appears to because spawning a process
dismisses it. That was inferred from one test and is wrong. `pressdigit` is also
a spawn and never dismissed MC.
[Possible Ripple Effects]
- SpaceBadge no longer requests or needs Accessibility. The existing grant for
  dev.umanzor.spacebadge is now inert and can be removed in System Settings.
- README gotchas gained an entry warning off this whole approach. Read it before
  building switch-from-MC again. If it is revisited, the sequence to try is
  dismiss MC first, poll until it is really closed, settle, then switch, which
  was designed but never tested.

[2026-07-20 17:01:01 UTC] [SpaceBadge/Badge placement fixes]
[Attempt #1]
[Files Changed]
- spacebadge.m:40 - spaceList() now carries "display" (the CGS "Display
  Identifier") through with each space. It was being dropped, so sync() had no
  way to know which screen a space belonged to.
- spacebadge.m:47-60 - new screenForDisplay(). Maps a CGS display identifier to
  an NSScreen by comparing against CGDisplayCreateUUIDFromDisplayID for each
  screen. The literal "Main" and any unmatched identifier (a display that got
  unplugged) fall back to screens[0], which is the menu bar display. Links with
  plain -framework Cocoa, no ColorSync needed, verified on the 26.5 SDK.
- spacebadge.m:196 - visibleFrame is now read per space from its own display
  instead of once from [NSScreen mainScreen] outside the loop. mainScreen is
  key-window relative and this is an accessory app with no key window, so it
  was only ever incidentally correct.
- spacebadge.m:215-217 - the else branch (badge already exists) split the frame
  update out of the name-changed check. Before, setFrame: only ran when the
  name string changed, so a recomputed frame was thrown away on every other
  sync. Now the label updates on name change and the frame updates whenever it
  differs, guarded by NSEqualRects so the 15s sync is a no-op when nothing moved.
[Possible Ripple Effects]
- The 15s sync and the space-change notification can now move windows, where
  before they could only create or destroy them. Guarded by NSEqualRects, so
  steady state is unchanged.
- screenForDisplay falls back rather than skipping when a display is gone. A
  badge for a space on an unplugged monitor lands top-right of the menu bar
  display. Better than the alternative of an offscreen badge, but it means two
  badges can overlap if that space is also visible.
- The multi-display path is inert right now. spans-displays is 1 on this
  machine ("Displays have separate Spaces" off), so CGSCopyManagedDisplaySpaces
  returns one block with identifier "Main" even with three monitors attached.
  The fix only becomes load-bearing if that setting is turned on.
- make install then launchctl kickstart -k fails with OS_REASON_CODESIGNING.
  launchd caches the old cdhash and the adhoc signature changes on every build.
  bootout then bootstrap clears it. CHEATSHEET updated.
[Testing Notes]
- Built clean, no warnings.
- Frame math checked against a standalone harness before install: all five
  named spaces resolve to the "Main" block, right edges all land at x 2276 on
  the 2304 wide display, 28pt in from the visible right.
- Post install, CGWindowList shows exactly five SpaceBadge windows, layer 3,
  alpha 1, bounds 2087/1963/2077/2040/1981 at y 44, widths 189-313. All right
  aligned to 2276, matching the harness.
- Not exercised at runtime: the reposition path. Proving it needs a real
  visibleFrame change (display unplug, resolution change, or moving the Dock to
  the left or right edge). The code path is a straight NSEqualRects comparison
  on a frame that was already being computed.

[2026-07-19 18:57:39 UTC] [spacetools/Initial Release]
[Attempt #1]
[Files Changed]
- spacetool.m (184 lines): CLI. Modes current/list/set/switch/bring. Name map
  at ~/.config/spacenames.json keyed by space UUID. Switch and window moves via
  SLSBridged* operations through SLSWindowManagementFallbackBridge.
- spacebadge.m (~215 lines): daemon. Per-space floating corner badge (54pt,
  white 0.42 alpha, stroke+shadow), Mission Control strip (dark pill, names in
  thumbnail order). MC detected by polling for Dock-owned layer-18 onscreen
  windows every 300ms. Badge space assignment deferred 0.35s after window
  creation, then bridged move.
- Makefile: builds both, bundles SpaceTool.app / SpaceBadge.app into
  ~/Applications (adhoc signed), writes shims spacename/sw/bring into
  ~/.local/bin.
- ~/Library/LaunchAgents/dev.umanzor.spacebadge.plist: RunAtLoad + KeepAlive.
- ~/raycast-scripts/{sw,bring,name-space,list-spaces}.sh: Raycast script
  commands (dir must be added in Raycast settings once).
[Possible Ripple Effects]
- Private API: a macOS update can break the bridge classes silently. yabai
  issue 2789 reports the move op failing on some machines; if bring stops
  moving windows, check that issue.
- KeepAlive LaunchAgent: disable with launchctl bootout gui/501/dev.umanzor.spacebadge.
- Badges are windows owned by SpaceBadge; anything enumerating windows will
  see them (layer 3, click-through).
[Testing Notes]
- sw round trip dev/comms verified; bring verified against Spark Mail, Xcodes,
  Xcode, Code, Home (5/5, restored after).
- Badge + MC strip verified by screenshot on macOS 26.5.1, SIP enabled.
- Multi-display: v1 positions badges on the main screen only.
