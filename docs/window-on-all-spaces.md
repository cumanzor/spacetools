# Making a single window appear on all spaces on macOS 27 (SIP on)

Date: 2026-09-28. Machine: macOS 27.0 (26A428), arm64e, SIP fully enabled,
AMFI on, no boot-args. Companion to `docs/space-creation-without-mission-control.md`
(the managed-space create wall). This doc covers the parallel question for
windows: what "appears on all spaces" actually is inside the window server,
everything that was exercised live to reach a per-window verdict, and the
privilege routes that could unlock it, with the one this repo intends to take.

The short version: the feature is a single window-tag bit. The compositor
honors it from any writer. Every writer path a normal process can reach is
gated, and the gates are silent. What a normal process *can* do today is the
per-app equivalent through the WindowManagement bridge. Per-window requires
running the tag write from a Dock-grade connection, which means either the
yabai-style scripting addition (Route A, chosen) or a private-entitlement
universal-owner grab with AMFI off (Route B, rejected).

## Verdict

Per-window "appear on all spaces" on macOS 27 with SIP enabled: not reachable
from a third-party process. The mechanism (window tag bit 11,
`onAllWorkspaces`) works exactly as hoped when set, and the user verified it
live: a tagged iTerm2 window rendered on every space they switched to while
`CGWindowListCopyWindowInfo` and `CGSCopySpacesForWindows` both claimed
otherwise. But the only writers the server accepts are the window's owning
process and privileged connections (the Dock, and the WindowManagement XPC,
which exposes the write only at process granularity). yabai's
`--toggle sticky` is the same tag set from inside the Dock via its scripting
addition, which is why it needs SIP partially disabled.

Per-app "appear on all spaces": works today, no SIP changes, through
`SLSBridgedProcessAssignToAllSpacesOperation` via the same
`SLSWindowManagementFallbackBridge` that `bring` and `send` already use. It
sets the tag on every window of the process, including windows created later.
Its reset (`...ProcessAssignToSpaceOperation`) clears the tag on every window
of the process, globally, and gathers them to the assigned space.

## 1. The mechanism: window tags, bit 11

Windows carry a 64-bit tag set in the window server. Stickiness is bit 11,
`onAllWorkspaces`, historically `kCGSOnAllWorkspacesTagBit`. It is what
AppKit's `NSWindowCollectionBehaviorCanJoinAllSpaces` sets in-process, and it
is what yabai's scripting addition sets from inside the Dock
(`src/osax/payload.m`, `do_window_sticky`):

```c
extern CGError SLSSetWindowTags(int cid, uint32_t wid, uint64_t *tags, size_t tag_size);
extern CGError SLSClearWindowTags(int cid, uint32_t wid, uint64_t *tags, size_t tag_size);

uint64_t tags = (1 << 11);
if (value) SLSSetWindowTags(SLSMainConnectionID(), wid, &tags, 64);
else       SLSClearWindowTags(SLSMainConnectionID(), wid, &tags, 64);
```

`tag_size` is 64 (bits). The tags argument is a mask: set and clear affect
only masked bits. Both symbols are present and dlsym-able on 26A428.

The full bit map below is from Loop (MrKai77), `Loop/Private
APIs/SLSWindowTags.swift`, reverse-engineered from SkyLight's internal
short-name debug table at `__cstring 0x1871fa9a2+` on macOS 26.3.1 (25D771280a),
cross-referenced with the older NUIKit/CGSInternal headers, which describe a
partly stale layout. Bit positions verified against observed values on 27.0
in section 8.

Lo bits:

| bit | name | meaning |
|---|---|---|
| 0 | document | default macOS window style |
| 1 | floating | floats over other windows |
| 2 | doNotShowBadgeInDock | no minimized badge in Dock tile |
| 3 | disableShadow | no window shadow |
| 4 | highQualityResampling | server resamples at higher rate |
| 5 | setsCursorInBackground | cursor control while app inactive |
| 6 | worksWhenModal | operates during modal run loops |
| 7 | attached | anchored to another window |
| 8 | ignoreAlphaForDragging | opaque while dragged |
| 9 | ignoreForEvents | click-through |
| 10 | opaqueForEvents | intercepts events |
| 11 | onAllWorkspaces | appears on all spaces (QuickLook panels) |
| 12 | pointerEventsAvoidCPS | bypasses CPS pointer dispatch |
| 13 | kitVisible | AppKit's visibility tracking |
| 14 | hideOnDeactivate | leaves the window list on deactivate |
| 15 | avoidsActivation | appearing does not front the app |
| 16 | preventsActivation | selecting does not front the app |
| 17 | ignoresOption | opts out of Option-modifier behavior |
| 18 | ignoresCycle | not in the window cycle |
| 19 | defersOrdering | defers order operations |
| 20 | defersActivation | defers activation |
| 21 | ignoreAsFrontWindow | server ignores order-front requests |
| 22 | enableServerSideDrag | server handles dragging if app stalls |
| 23 | mouseDownEventsGrabbed | mouse-downs grabbed, not dispatched |
| 24 | dontHide | ignores hide requests |
| 25 | dontDimWindowDisplay | display not dimmed |
| 26 | instantMouserWindow | converts pointers on entry |
| 27 | ownerFollowsForeground | follows across space changes |
| 28 | activationWindowLevel | separate active/inactive levels |
| 29 | bringOwnerForward | brings app forward when selected |
| 30 | permittedBeforeLogin | may appear over login screen |
| 31 | modal | modal window |

Hi bits:

| bit | name | meaning |
|---|---|---|
| 32 | windowManagerAware | cooperates with Stage Manager / built-in WM |
| 33 | followsDocumentSpace | follows the focused document space |
| 34 | noMirrorReflection | excluded from mirror surfaces |
| 35 | meshed | internal compositor flag, unclear |
| 36 | coreDragIsDragging | CoreDrag dragged something to it |
| 37 | avoidsCapture | excluded from capture streams |
| 38 | ignoreForExpose | Expose ignores it |
| 39 | hidden | hidden |
| 40 | includeInCycle | explicitly in the window cycle |
| 41 | wantsGesturesInBackground | gestures while backgrounded |
| 42 | fullScreen | fullscreen |
| 43 | magicZoom | accessibility zoom source |
| 44 | superSticky | stronger onAllWorkspaces: resists space transitions |
| 45 | friendOfFullscreen | may appear over fullscreen apps (menu bar items) |
| 46 | menuBar | attached to the menu bar (NSMenu) |
| 47 | desktopAffinity | affinity for desktop level |
| 48 | neverSticky | forced space-bound, opposite of 11/44 |
| 49 | desktopPicture | desktop picture level |
| 50 | ignoresWorkspaceHeuristics | negates followsDocumentSpace |
| 51 | ordersForwardOnFlush | moves forward when redrawn |
| 52 | userInputAccessory | IME panel and similar |
| 53 | nonCompositingBackingStore | non-standard backing store |
| 54 | dragsMovementGroupParent | drags its movement-group parent |
| 55 | neverFlattenSurfacesDuringSwipes | layers kept separate during swipes |
| 56 | fullScreenCapable | eligible for native fullscreen |
| 57 | fullScreenTileCapable | eligible for Split View tiling |
| 58 | ignoreForScreenSharing | excluded from screen sharing |
| 59 | shareAlongWithParent | shared with parent during capture |
| 60 | miniaturized | currently miniaturized |
| 61 | windowSharingIndicator | sharing indicator |
| 62 | ignoreTransientOrderingForFiltering | transient ordering ignored |
| 63 | trivialLayerTree | single-layer hint for the compositor |

Tag read path (all symbols present on 26A428, and they work from a normal
process):

```c
CFTypeRef query  = SLSWindowQueryWindows(cid, wids, count);      // wids: CFArrayRef of NSNumber
CFTypeRef iter   = SLSWindowQueryResultCopyWindows(query);
while (SLSWindowIteratorAdvance(iter)) {
    uint32_t wid  = SLSWindowIteratorGetWindowID(iter);
    uint64_t tags = SLSWindowIteratorGetTags(iter);
}
```

Space membership read: `CGSCopySpacesForWindows(cid, 7, @[wid])` returns the
space IDs the window is registered on (mode 7; same call `bring` uses). For a
bit-11 window this read returns different things depending on when you ask;
see section 2.

## 2. Render truth vs API truth

The single most important operational finding, and it re-confirms the
changelog's "verify with a screenshot, not an API read" rule with new teeth:

After the tag was set on the frontmost iTerm2 window (wid 6224) via the
process-level op (section 3), the user switched spaces by hand and the window
visibly rendered on every space. At that same moment:

- `CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly)` reported the
  window `offscreen` on the destination space, twice, with a 1s settle. The
  onscreen list tracks the Dock's bookkeeping, not the composite.
- `CGSCopySpacesForWindows` membership, which had read as all four spaces
  (7, 43, 47, 38) immediately after the tag was set, was stripped back to the
  home space only (43) after the real switches. Rendering did not care.

So the model on 27 is: rendering follows the tag bit; membership is
bookkeeping the Dock recomputes and strips on real switches; and the onscreen
window list follows the bookkeeping. Any future tooling that reasons about
sticky windows must read tags, not membership or onscreen state, and must
verify changes visually.

The wallpaper window makes a good reference point: the loginwindow-owned
wallpaper window carries bit 11 plus membership in every desktop space,
which is what a sticky window looks like when the system does it.

## 3. What a normal process can do: per-app, via the bridge

The WindowManagement bridge (`SLSWindowManagementFallbackBridge`, the same
machinery `bring`/`send` use) exposes exactly two stickiness ops, both
process-level. From live exercise on 26A428 (iTerm2, pid 17072, wids 6224 and
5622):

`SLSBridgedProcessAssignToAllSpacesOperation`

- Init: `initWithProcess:` taking an `int` pid (property type `Ti`).
- Effect on every existing window of the process: sets bit 11 and registers
  the window on every desktop space. iTerm2 6224 went from
  `0x0100000100482001` (bit11=0) to `0x0100000100482801` (bit11=1), spaces
  38 47 7 43.
- Effect on windows created later: they are born tagged. A window created by
  a process after the assignment came up `0x0000200100082801` (bit11=1) with
  no per-window call. The assignment is live server state, not a one-shot
  sweep.
- Equivalent to the Dock UI's per-app "Options > Assign To > All Desktops".

`SLSBridgedProcessAssignToSpaceOperation`

- Init: `initWithProcess:spaceID:`, pid `Ti` + space ID `TQ` (uint64).
- Effect: clears bit 11 on every window of the process, regardless of which
  space each window is currently on (tested with both windows parked on a
  foreign space: the sweep still cleared both), and gathers them to the
  assigned space. Windows moved from 47 to 43 during the test.

`SLSBridgedMoveWindowsToManagedSpaceOperation` (already used by the repo)

- Move preserves bit 11. A tagged window moved to another space keeps the
  tag (and keeps rendering everywhere). This is what makes per-app sticky
  compatible with `send`/`bring`.

Practical upshot: a `stick <app>` / `unstick <app>` pair is implementable
today with zero SIP changes, reusing `bridgedOps()` verbatim. Caveats tested
or reasoned about but not verified: whether the assignment survives a Dock
restart (the Dock re-applies its own per-app list on launch, and the bridge op
never tells the Dock, so a restart may unassign), and how Mission Control
thumbnails render a window present in every space.

## 4. What is gated: per-window, everything

Exhausted live, all on the same window (6224) and control windows:

**Direct tag write, foreign window.** `SLSSetWindowTags` returns
`kCGErrorSuccess` (0) and does nothing. Tags unchanged after a 100ms runloop
settle. Same class of silent no-op as `SLSMoveWindow`, which this repo's
changelog already documented. The call is not rejected; it is ignored. This
is the exact call yabai's scripting addition makes succeed by running it from
inside the Dock.

**Direct tag write with a fresh connection.** Same no-op after
`SLSNewConnection`. Connection identity does not matter; process privilege
does.

**Window-level bridge ops.** The full `SLSBridged*` class list (section 8)
was enumerated at runtime (~100 classes) and every plausible candidate was
exercised:

- `SLSBridgedAddWindowsToSpacesOperation` (`initWithWindows:spaces:`):
  no-op. Single destination space, all desktop spaces, foreign window, and
  the probe's own window all refused. Not an argument-format issue: the move
  op with the same NSNumber window array works from the same binary.
- `SLSBridgedRemoveWindowsFromSpacesOperation`: same, and never needed.
- `SLSBridgedSpaceAddWindowsAndRemoveFromSpacesOperation`
  (`initWithSpaceID:windows:options:`): not exercised to effect; the add op
  it would build on is dead.

**The dodge attempts.** Since per-app set/unset works and move preserves the
tag, every sequencing trick was tested for a state where exactly one window
of a process keeps bit 11:

- assign process to all, move target elsewhere, reset process assignment:
  the reset sweeps globally and cleared the target too (the target was parked
  on space 47, the reset assigned 43; both windows ended untagged on 43).
- there is no per-window unstick to pair with the per-app stick: move does
  not clear the tag, add does not set it, direct writes are ignored, and the
  XPC has no window-level op.

Conclusion: the WindowManagement XPC will move windows between spaces
one at a time (1:1 reassignment) and will assign processes, but refuses
per-window multi-space membership and exposes no per-window tag write.

**`SLSRequestSpaceManagement`.** The symbol does not exist on 26A428 (not
exported from SkyLight). Dead before the call.

## 5. The universal-owner route without SIP: dead on arrival

yabai issue #2593 (AlexStrNik) documents an alternative to Dock injection:
take the universal-owner slot yourself.

```swift
func gainUniversalOwner() {
    var connection: UInt32 = 0
    SLSNewConnection(0, &connection)
    let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock")[0]
    kill(dock.processIdentifier, SIGKILL)
    SLSSetUniversalOwner(connection)
    SLSSetOtherUniversalConnection(connection, self.connectionId)
    SLSReleaseConnection(connection)
}
```

koekeishiya confirmed in that issue that he has used the technique and that
it covers "the operations that require code injection today; primarily the
ones that manipulate windows and their properties" (which is exactly the tag
write), while spaces create/destroy/focus still need Dock internals.

All four symbols exist on 26A428. Probed unentitled, without killing the
Dock:

- `SLSNewConnection(0, &conn)` -> 0, secondary connection created fine.
- `SLSSetUniversalOwner(conn)` -> **1002** (`kCGErrorInvalidOperation`):
  rejected while unentitled / while the Dock holds the slot.
- `SLSSetOtherUniversalConnection(conn, cid)` -> 0, but grants nothing on
  its own (the primary connection never became universal).
- `SLSSetWindowTags` afterward: still the silent no-op.

Then the entitlement half: a probe binary adhoc-signed with
`com.apple.private.skylight.universal-owner` (codesign
`--entitlements`) was **SIGKilled at spawn, exit 137, zero output**. AMFI
kills restricted entitlements on non-platform signatures before main runs.
With a self-signed Developer identity the entitlement would likewise not be
honored (restricted entitlements require Apple-platform signing); the kill
for adhoc is just the fastest way to see the wall.

So Route B requires AMFI disabled. The AMFI boot-arg landscape, checked
against the OpenCore/OCLP research (5T33Z0's boot-args table, OCLP
PATCHEXPLAIN and security code):

- `amfi=0x80` and `amfi_get_out_of_my_way=1` are the same thing: a bitmask
  where 0x80 is `AMFI_ALLOW_EVERYTHING`, full AMFI disable.
- There is no narrower "honor restricted entitlements only" bit. Disabling
  AMFI takes library validation down system-wide and is documented to break
  third-party mic/camera TCC prompts.
- Setting any boot-arg also requires NVRAM protection off
  (`csrutil enable --without nvram`), on Apple Silicon.

## 6. Route comparison and decision

| | Route A: scripting addition into the Dock | Route B: universal-owner entitlement |
|---|---|---|
| csrutil groups opened | fs, debug, nvram | nvram only |
| AMFI | stays fully on | fully off (`amfi=0x80`) |
| extra boot-arg | `-arm64e_preview_abi` | `amfi=0x80` |
| runtime Dock disruption | none (payload hosts a socket) | SIGKILL the Dock once per privilege grab |
| code to maintain | injector + tiny payload | tiny helper |
| system-wide side effects | none beyond the CSR groups | library validation dead, TCC prompt breakage |
| precedent | yabai-proven, wiki current (Apr 2026) | one issue + maintainer confirmation |

Both routes share one pivot: whoever has root can already write boot-args
once NVRAM protection is off, so the marginal exposure difference is mostly
about what runs quietly day to day. Route A keeps AMFI armed; Route B
disarms it machine-wide forever. Decision: **Route A**.

The yabai wiki recipe for Apple Silicon, macOS 13+ (page current as of
April 2026), verbatim:

```sh
# in Recovery:
csrutil enable --without fs --without debug --without nvram

# back in macOS, then reboot:
sudo nvram boot-args="-arm64e_preview_abi"
```

Gotchas from the yabai issue tracker, worth having in one place:

- It is `boot-args`, plural. `nvram boot-arg=...` sets a variable nothing
  reads (issue #2741, multiple victims).
- `Error setting variable - 'boot-args': (iokit/common) not permitted` means
  the NVRAM protection CSR bit is still on; the csrutil step did not take.
- The load itself is task injection: `sudo yabai --load-sa` spawns a remote
  thread in the Dock (the "could not spawn remote thread: (os/kern)
  protection failure" error in issue #2747 is the debug-restriction wall).
  This is why `--without debug` is in the recipe. The sudoers pattern yabai
  documents pins the binary by sha256.
- After a Dock restart the payload is gone until re-injected (yabai users
  hook `dock_did_restart`).

What our payload does NOT need from yabai: all the Dock-internal offsets.
yabai's payload scans the Dock binary for `dock_spaces`, `dppm`, and the
`addSpace`/`removeSpace`/`moveSpace`/`setFrontWindow` function pointers with
per-OS-version hex patterns (the "September tax": 26.0 needed new patterns
by 26.4, per issue #2764). Sticky is a pure SkyLight call; our payload links
zero Dock internals and should survive OS updates as long as the SLS symbols
exist (verified present on 27.0).

## 7. What the SA opens beyond sticky, in tiers

- **Tier 0, version-proof (pure SkyLight calls from the Dock connection):**
  sticky (bits 11 set/clear), shadow (bit 3), opacity (`SLSSetWindowAlpha`),
  always-on-top (`SLSSetWindowSubLevel` + `CGWindowLevelForKey`), window
  move (`SLSMoveWindowWithGroup` + `SLSReassociateWindowsSpacesByGeometry`),
  scale (`SLSSetWindowTransform`). All are the silent no-ops from outside
  that become live from the Dock.
- **Tier 1, one signature scan:** instant space switching with no gesture
  synthesis and no Accessibility/TCC dependency. yabai's `do_space_focus`:
  find the `dock_spaces` pointer, update the display's `_currentSpace` ivar,
  then `SLSShowSpaces`/`SLSHideSpaces`/`SLSManagedDisplaySetCurrentSpace`.
  The ivar poke is exactly the desync fix this repo's changelog documented
  when trying the same switch from outside (the Dock never hears about it;
  from inside, we tell it ourselves).
- **Tier 2, full September tax:** space create/destroy/move with no Mission
  Control round trip, by calling the Dock's own `addSpace`/`removeSpace`/
  `moveSpace` via scanned function pointers. This also routes around the
  `com.apple.private.windowmanager.spacemanagement` entitlement wall
  documented in the space-creation doc, because the Dock is already a party
  to space management. Fragile per OS release; keep the AX/MC path as the
  fallback.

Renaming is already MC-free (the repo's JSON name map); Tier 2 concerns
create/remove/reorder only. yabai's "move" is display-to-display; reordering
within a display is not exposed even there.

## 8. Internals reference (26A428)

### The full SLSBridged* class list, categorized

Runtime `objc_getClassList` dump after dlopening SkyLight, with the
WindowManagement names. This is the durable copy of the dump the README
references ("all 100 SLSBridged* classes were dumped"); nothing in the repo
had ever listed them. All op classes subclass
`SLSAsynchronousBridgedWindowManagementOperation` and are run through
`SLSWindowManagementFallbackBridge`:
`performWindowManagementBridgeTransactionUsingBlock:` wrapping
`performAsynchronousBridgedWindowManagementOperation:` per op. Each class
also implements `invokeFallback` and NSCoder plumbing (they cross an XPC
boundary as property lists).

Window/space membership and movement:

```
SLSBridgedMoveWindowsToManagedSpaceOperation
SLSBridgedAddWindowsToSpacesOperation
SLSBridgedRemoveWindowsFromSpacesOperation
SLSBridgedSpaceAddWindowsAndRemoveFromSpacesOperation
SLSBridgedResetWindowsOperation
SLSBridgedCopyAssociatedWindowsOperation
SLSBridgedCopySpacesForWindowsOperation
SLSBridgedCopySpacesOperation
```

Process/space ownership assignment (the stickiness surface):

```
SLSBridgedProcessAssignToAllSpacesOperation
SLSBridgedProcessAssignToSpaceOperation
SLSBridgedSpaceSetOwnersOperation
SLSBridgedSpaceAddOwnerOperation
SLSBridgedSpaceRemoveOwnerOperation
```

Space CRUD and per-space properties:

```
SLSBridgedSpaceCreateOperation
SLSBridgedSpaceDestroyOperation
SLSBridgedSpaceSetNameOperation
SLSBridgedSpaceCopyNameOperation
SLSBridgedSpaceWithNameOperation
SLSBridgedSpaceSetValuesOperation
SLSBridgedSpaceCopyValuesOperation
SLSBridgedSpaceRemoveValuesForKeysOperation
SLSBridgedSpaceSetOrderingWeightOperation
SLSBridgedSpaceSetFrontPSNOperation
SLSBridgedSpaceSetAbsoluteLevelOperation
SLSBridgedSpaceGetAbsoluteLevelOperation
SLSBridgedSpaceSetAlphaOperation
SLSBridgedSpaceGetAlphaOperation
SLSBridgedSpaceSetTransformOperation
SLSBridgedSpaceGetTransformOperation
SLSBridgedSpaceSetShapeOperation
SLSBridgedSpaceCopyShapeOperation
SLSBridgedSpaceCopyManagedShapeOperation
SLSBridgedSpaceSetInterTileSpacingOperation
SLSBridgedSpaceSetEdgeReservationOperation
SLSBridgedSpacePreferCurrentDisplayOperation
SLSBridgedMoveManagedSpaceToDisplayIndexOperation
SLSBridgedSpaceCopyOwnersOperation
SLSBridgedSpaceGetTypeOperation
SLSBridgedSpaceGetRectOperation
SLSBridgedSpaceGetSizeForProposedTileOperation
SLSBridgedSpaceCanCreateTileOperation
SLSBridgedSpaceCreateTileOperation
SLSBridgedSpaceTileMoveToSpaceAtIndexOperation
SLSBridgedSpaceFinishedResizeForRectOperation
SLSBridgedSpaceClientDrivenMoveSpacersToPointOperation
SLSBridgedSpaceClientDrivenMoveSpacersToPointFencedOperation
SLSBridgedTileSpaceMoveSpacersForSizeOperation
SLSBridgedTileSpaceMoveSpacersForSizeFencedOperation
SLSBridgedTileSpaceTakeOwnershipOperation
SLSBridgedTileSpaceReplaceWithSnapshotWindowOperation
SLSBridgedTileSpaceSetDividerWindowOperation
SLSBridgedSpaceGetSpacersAtPointOperation
SLSBridgedWindowGetTileRectOperation
SLSBridgedGetTileSpaceDividerDirectionsOperation
```

Switch handshake (the window-server half this repo already knows):

```
SLSBridgedWillSwitchSpacesOperation
SLSBridgedShowSpacesOperation
SLSBridgedHideSpacesOperation
SLSBridgedSpaceResetMenuBarOperation
SLSBridgedManagedDisplaySetCurrentSpaceOperation
SLSBridgedSetSpaceManagementModeOperation
SLSBridgedGetSpaceManagementModeOperation
```

Reads and queries:

```
SLSBridgedCopyManagedDisplaySpacesOperation
SLSBridgedCopyManagedDisplaysOperation
SLSBridgedCopyManagedDisplayForSpaceOperation
SLSBridgedCopyManagedDisplayForWindowOperation
SLSBridgedCopyBestManagedDisplayForRectOperation
SLSBridgedCopyBestManagedDisplayForPointOperation
SLSBridgedManagedDisplayGetCurrentSpaceOperation
SLSBridgedManagedDisplayCurrentSpaceAllowsWindowOperation
SLSBridgedManagedDisplayIsAnimatingOperation
SLSBridgedManagedDisplaySetIsAnimatingOperation
SLSBridgedManagedDisplaySetRoleWindowOperation
SLSBridgedManagedDisplaysCopyRoleWindowsOperation
SLSBridgedCopyWindowsWithOptionsAndTagsOperation
SLSBridgedCopyWindowsWithOptionsAndTagsAndSpaceOptionsOperation
SLSBridgedGetSpaceNeedsSafeApertureOperation
SLSBridgedGetSpacePermittedResizeDirectionsOperation
SLSBridgedSpaceCopyTileSpacesOperation
```

Result wrappers (XPC return value types):

```
SLSBridgedWindowManagementOperationResult
SLSBridgedWindowManagementOperationBoolResult
SLSBridgedWindowManagementOperationInt32Result
SLSBridgedWindowManagementOperationFloatResult
SLSBridgedWindowManagementOperationStringResult
SLSBridgedWindowManagementOperationStringsResult
SLSBridgedWindowManagementOperationNumbersResult
SLSBridgedWindowManagementOperationRectResult
SLSBridgedWindowManagementOperationSizeResult
SLSBridgedWindowManagementOperationRegionResult
SLSBridgedWindowManagementOperationSpacersResult
SLSBridgedWindowManagementOperationSpacerIndexesResult
SLSBridgedWindowManagementOperationSpaceIDResult
SLSBridgedWindowManagementOperationSpaceResizeDirectionsResult
SLSBridgedWindowManagementOperationSpaceManagementModeResult
SLSBridgedWindowManagementOperationWorkspaceTypeResult
SLSBridgedWindowManagementOperationWindowIDResult
SLSBridgedWindowManagementOperationProcessIdentifierResult
SLSBridgedWindowManagementOperationAffineTransformWithOptionsResult
SLSBridgedWindowManagementOperationPropertyListArrayResult
SLSBridgedWindowManagementOperationPropertyListDictionaryResult
```

Infrastructure:

```
SLSWindowManagementFallbackBridge
SLSAsynchronousBridgedWindowManagementOperation
SLSSynchronousBridgedWindowManagementOperation
_BMSpringBoardWindowManagementLibraryNode
```

Note for future research: `SLSBridgedCopyWindowsWithOptionsAndTagsOperation`
reads window tags through the XPC (yabai's space.c uses the same
options/tags shape through direct SLS). A tag *read* through the bridge from
a bundled app should work the same way the membership reads do; only writes
are gated.

### Op class signatures (runtime introspection)

```
SLSBridgedAddWindowsToSpacesOperation        initWithWindows:spaces:      _windows NSArray, _spaces NSArray
SLSBridgedRemoveWindowsFromSpacesOperation    initWithWindows:spaces:      _windows NSArray, _spaces NSArray
SLSBridgedSpaceAddWindowsAndRemoveFromSpacesOperation  initWithSpaceID:windows:options:
SLSBridgedMoveWindowsToManagedSpaceOperation initWithWindows:spaceID:     _windows NSArray, _spaceID TQ
SLSBridgedProcessAssignToAllSpacesOperation   initWithProcess:             _process Ti (pid)
SLSBridgedProcessAssignToSpaceOperation        initWithProcess:spaceID:     _process Ti, _spaceID TQ
SLSBridgedSpaceSetOwnersOperation              initWithSpaceID:owners:      _spaceID TQ, _owners NSArray
SLSBridgedSpaceAddOwnerOperation              initWithSpaceID:owner:       _spaceID TQ, _owner
```

Windows arrays are NSNumber of int32 window IDs (kCGWindowNumber values);
spaces arrays are NSNumber of uint64 ManagedSpaceIDs. The bridge rejects
bare executables (README already documents this): the probe had to be
bundled in an .app before its bridged ops did anything at all.

### Observed tag values (26A428)

| window | tags | bits (per the 26.3.1 table) |
|---|---|---|
| iTerm2 6224, baseline | 0x0100000100482001 | 0, 13, 19, 22, 32, 56 |
| iTerm2 6224, after ProcessAssignToAllSpaces | 0x0100000100482801 | + 11 (onAllWorkspaces) |
| iTerm2 5622, same transition | same shape | same |
| loginwindow wallpaper window 9832 | 0x0000200100492801 | 0, 11, 13, 16, 19, 22, 32, 45; member of all desktop spaces |
| probe borderless NSWindow | 0x0000200100082001 | 0, 13, 19, 32, 45 |
| window born under ProcessAssignToAllSpaces | 0x0000200100082801 | + 11, i.e. born sticky |

Decoded names: 0 document, 11 onAllWorkspaces, 13 kitVisible, 16
preventsActivation, 19 defersOrdering, 22 enableServerSideDrag, 32
windowManagerAware, 45 friendOfFullscreen, 56 fullScreenCapable.

### Probe gotchas worth keeping

- The bridge ops run from any bundled, adhoc-signed .app; no stable identity
  was needed for the ops tested (the stable identity in `codesign.env`
  matters for TCC persistence, not the XPC).
- Buffered stdout hid a segfault's location: `setvbuf(stdout, NULL, _IONBF, 0)`
  before anything else, or the crash eats the evidence.
- The probe crashed at autorelease-pool pop (exit 139) in the runs that
  constructed bridge op objects and an NSWindow in the same lifetime:
  an ARC over-release of XPC-adjacent temporaries. Harmless to the system
  (it happens at exit, after results print), but re-running the appendix
  probe should expect it.
- A `loginwindow` window can be the frontmost "onscreen layer-0" pick right
  after boot or a TCC dialog; check the owner name before experimenting on
  "the frontmost window".

## Appendix A: probe source

The probe that produced every live result above. Build:

```sh
mkdir -p Probe.app/Contents/MacOS
clang -fobjc-arc -O0 -Wno-deprecated-declarations -framework Cocoa \
  -o Probe.app/Contents/MacOS/probe probe.m
# ...Info.plist with LSUIElement true, then:
codesign --force -s - Probe.app
./Probe.app/Contents/MacOS/probe <verb> [wid] ...
```

Verbs: `pick`/`tags`, `set`/`clear <wid> [bit]`, `onscreen <wid>`,
`bridged`, `class <name>...`, `pidof <wid>`, `move <wid> <sid>`,
`add1 <wid> <sid>`, `joinall <wid>`, `part <wid> <keepsid>`,
`ownjoin`, `ownnew`, `procall <wid> <pid>`, `procspace <wid> <pid> <sid>`,
`reqmgmt <wid> [arg]`, `univ <wid>`. The window defaults to the frontmost
onscreen layer-0 window of at least 120x120.

`univ` deliberately never kills the Dock; it only answers whether the
universal-owner calls do anything unentitled (they do not, section 5).

```objc
// probe - can a normal process set the sticky (on-all-spaces) window tag on a
// foreign window under SIP? verbs: pick | set [bit] | clear [bit] | tags | onscreen | bridged
// wid is the frontmost onscreen layer-0 window unless passed as argv[2]
#import <Cocoa/Cocoa.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <dlfcn.h>

typedef int (*ConnFn)(void);
typedef CFArrayRef (*MDSFn)(int);
typedef CFArrayRef (*CopySpacesFn)(int, int, CFArrayRef);
typedef CGError (*TagsFn)(int, uint32_t, uint64_t *, size_t);
typedef CFTypeRef (*QueryWindowsFn)(int, CFArrayRef, int);
typedef CFTypeRef (*QueryResultCopyFn)(CFTypeRef);
typedef BOOL (*IterAdvanceFn)(CFTypeRef);
typedef uint32_t (*IterWidFn)(CFTypeRef);
typedef uint64_t (*IterTagsFn)(CFTypeRef);
typedef CGError (*ReqMgmtFn)(int, int);
typedef CGError (*NewConnFn)(int, uint32_t *);
typedef CGError (*SetUnivFn)(uint32_t);
typedef CGError (*SetOtherUnivFn)(uint32_t, uint32_t);
typedef CGError (*RelConnFn)(uint32_t);

static int cid;
static MDSFn mdsF;
static CopySpacesFn spacesF;
static TagsFn setTagsF, clearTagsF;
static QueryWindowsFn queryF;
static QueryResultCopyFn iterCopyF;
static IterAdvanceFn iterAdvF;
static IterWidFn iterWidF;
static IterTagsFn iterTagsF;
static ReqMgmtFn reqMgmtF;
static NewConnFn newConnF;
static SetUnivFn setUnivF;
static SetOtherUnivFn setOtherUnivF;
static RelConnFn relConnF;

static uint64_t tagsFor(uint32_t wid) {
    uint64_t tags = 0;
    NSArray *one = @[@(wid)];
    CFTypeRef query = queryF(cid, (__bridge CFArrayRef)one, 1);
    if (!query) return 0;
    CFTypeRef iter = iterCopyF(query);
    if (iter) {
        while (iterAdvF(iter))
            if (iterWidF(iter) == wid) { tags = iterTagsF(iter); break; }
        CFRelease(iter);
    }
    CFRelease(query);
    return tags;
}

static void printWindow(uint32_t wid) {
    uint64_t t = tagsFor(wid);
    printf("wid %u tags 0x%016llx (bit11=%llu) spaces:", wid, t, (t >> 11) & 1);
    NSArray *on = spacesF ? CFBridgingRelease(spacesF(cid, 7, (__bridge CFArrayRef)@[@(wid)])) : nil;
    for (id s in on) printf(" %llu", [s unsignedLongLongValue]);
    printf("\n");
}

static void bridgedOps(NSArray *ops) {
    Class brCls = NSClassFromString(@"SLSWindowManagementFallbackBridge");
    if (!brCls || !ops.count) return;
    id bridge = [[brCls alloc] init];
    void (^blk)(void) = ^{
        for (id op in ops)
            ((void(*)(id,SEL,id))objc_msgSend)(bridge,
                sel_registerName("performAsynchronousBridgedWindowManagementOperation:"), op);
    };
    ((void(*)(id,SEL,id))objc_msgSend)(bridge,
        sel_registerName("performWindowManagementBridgeTransactionUsingBlock:"), blk);
}

// every desktop space id, both displays ignored-span case included
static NSArray *desktopSpaceIDs(void) {
    NSMutableArray *out = [NSMutableArray array];
    for (NSDictionary *d in (NSArray *)CFBridgingRelease(mdsF(cid)))
        for (NSDictionary *s in d[@"Spaces"])
            if (![s[@"type"] intValue])
                [out addObject:[s[@"ManagedSpaceID"] copy]];
    return out;
}

static uint32_t frontWid(void) {
    NSArray *list = CFBridgingRelease(CGWindowListCopyWindowInfo(
        kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements, kCGNullWindowID));
    for (NSDictionary *w in list) {
        if ([w[(id)kCGWindowLayer] intValue] != 0) continue;
        CGRect b; CGRectMakeWithDictionaryRepresentation((CFDictionaryRef)w[(id)kCGWindowBounds], &b);
        if (b.size.width < 120 || b.size.height < 120) continue;
        printf("target %u (%s)\n", [w[(id)kCGWindowNumber] intValue],
               [w[(id)kCGWindowOwnerName] description].UTF8String);
        return [w[(id)kCGWindowNumber] intValue];
    }
    return 0;
}

static BOOL onscreen(uint32_t wid) {
    NSArray *list = CFBridgingRelease(CGWindowListCopyWindowInfo(
        kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements, kCGNullWindowID));
    for (NSDictionary *w in list)
        if ([w[(id)kCGWindowNumber] intValue] == (int)wid) return YES;
    return NO;
}

int main(int argc, char **argv) {
  @autoreleasepool {
    setvbuf(stdout, NULL, _IONBF, 0);
    [NSApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    [NSApp finishLaunching];
    void *h = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY);
    if (!h) { printf("no skylight\n"); return 1; }
    cid = ((ConnFn)dlsym(h, "_CGSDefaultConnection"))();
    mdsF = (MDSFn)dlsym(h, "CGSCopyManagedDisplaySpaces");
    spacesF = (CopySpacesFn)dlsym(h, "CGSCopySpacesForWindows");
    setTagsF = (TagsFn)dlsym(h, "SLSSetWindowTags");
    clearTagsF = (TagsFn)dlsym(h, "SLSClearWindowTags");
    queryF = (QueryWindowsFn)dlsym(h, "SLSWindowQueryWindows");
    iterCopyF = (QueryResultCopyFn)dlsym(h, "SLSWindowQueryResultCopyWindows");
    iterAdvF = (IterAdvanceFn)dlsym(h, "SLSWindowIteratorAdvance");
    iterWidF = (IterWidFn)dlsym(h, "SLSWindowIteratorGetWindowID");
    iterTagsF = (IterTagsFn)dlsym(h, "SLSWindowIteratorGetTags");
    reqMgmtF = (ReqMgmtFn)dlsym(h, "SLSRequestSpaceManagement");
    newConnF = (NewConnFn)dlsym(h, "SLSNewConnection");
    setUnivF = (SetUnivFn)dlsym(h, "SLSSetUniversalOwner");
    setOtherUnivF = (SetOtherUnivFn)dlsym(h, "SLSSetOtherUniversalConnection");
    relConnF = (RelConnFn)dlsym(h, "SLSReleaseConnection");
    printf("cid %d  set=%d clear=%d query=%d iter=%d\n", cid,
           setTagsF != NULL, clearTagsF != NULL, queryF != NULL, iterTagsF != NULL);
    if (!setTagsF || !clearTagsF || !queryF) return 1;

    NSString *verb = argc > 1 ? [NSString stringWithUTF8String:argv[1]] : @"pick";
    if ([verb isEqualToString:@"bridged"]) {
        int n = objc_getClassList(NULL, 0);
        Class *cls = (__unsafe_unretained Class *)malloc(sizeof(Class) * n);
        n = objc_getClassList(cls, n);
        for (int i = 0; i < n; i++) {
            const char *nm = class_getName(cls[i]);
            if (strstr(nm, "SLSBridged") == nm || strstr(nm, "WindowManagement"))
                printf("%s\n", nm);
        }
        free(cls);
        return 0;
    }
    if ([verb isEqualToString:@"class"]) {
        for (int i = 2; i < argc; i++) {
            const char *nm = argv[i];
            Class c = objc_getClass(nm);
            if (!c) { printf("%s: no such class\n", nm); continue; }
            printf("== %s ==\n", nm);
            unsigned int cnt = 0;
            Ivar *iv = class_copyIvarList(c, &cnt);
            for (unsigned j = 0; j < cnt; j++) printf("  ivar %s\n", ivar_getName(iv[j]));
            if (iv) free(iv);
            objc_property_t *pr = class_copyPropertyList(c, &cnt);
            for (unsigned j = 0; j < cnt; j++)
                printf("  prop %s %s\n", property_getName(pr[j]), property_getAttributes(pr[j]));
            if (pr) free(pr);
            Method *me = class_copyMethodList(c, &cnt);
            for (unsigned j = 0; j < cnt; j++)
                printf("  method %s\n", sel_getName(method_getName(me[j])));
            if (me) free(me);
            for (Class s = class_getSuperclass(c); s; s = class_getSuperclass(s))
                printf("  super %s\n", class_getName(s));
        }
        return 0;
    }
    uint32_t wid = argc > 2 ? (uint32_t)strtoul(argv[2], NULL, 0) : 0;
    if (!wid) wid = frontWid();
    if (!wid) { printf("no window\n"); return 1; }

    if ([verb isEqualToString:@"pick"] || [verb isEqualToString:@"tags"]) {
        printWindow(wid);
        return 0;
    }
    if ([verb isEqualToString:@"onscreen"]) {
        printf("%s\n", onscreen(wid) ? "onscreen" : "offscreen");
        return 0;
    }
    if ([verb isEqualToString:@"univ"]) {
        // never kills the Dock here: probing whether the calls work as-is
        printf("symbols: new=%d setUniv=%d setOther=%d rel=%d\n",
               newConnF != NULL, setUnivF != NULL, setOtherUnivF != NULL, relConnF != NULL);
        if (!newConnF || !setUnivF || !setOtherUnivF || !relConnF) return 1;
        uint32_t conn = 0;
        CGError e = newConnF(0, &conn);
        printf("SLSNewConnection -> %d (conn %u)\n", e, conn);
        if (!conn) return 1;
        printf("SLSSetUniversalOwner -> %d\n", setUnivF(conn));
        printf("SLSSetOtherUniversalConnection(conn, cid) -> %d\n", setOtherUnivF(conn, cid));
        uint64_t mask = 1ULL << 11;
        printf("SLSSetWindowTags bit11 -> %d\n", setTagsF(cid, wid, &mask, 64));
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.2]];
        printWindow(wid);
        printf("SLSReleaseConnection -> %d\n", relConnF(conn));
        return 0;
    }
    if ([verb isEqualToString:@"ownnew"]) {
        id op = ((id(*)(id,SEL,int))objc_msgSend)(
            ((id(*)(id,SEL))objc_msgSend)(NSClassFromString(@"SLSBridgedProcessAssignToAllSpacesOperation"),
                sel_registerName("alloc")),
            sel_registerName("initWithProcess:"), getpid());
        bridgedOps(@[op]);
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.3]];
        NSWindow *w = [[NSWindow alloc] initWithContentRect:NSMakeRect(500, 500, 220, 160)
            styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
        w.backgroundColor = [NSColor systemRedColor];
        [w orderFront:nil];
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.3]];
        uint32_t own = 0;
        NSArray *list = CFBridgingRelease(CGWindowListCopyWindowInfo(
            kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements, kCGNullWindowID));
        for (NSDictionary *x in list)
            if ([x[(id)kCGWindowOwnerPID] intValue] == getpid() &&
                [x[(id)kCGWindowLayer] intValue] == 0) { own = [x[(id)kCGWindowNumber] intValue]; break; }
        printf("new window of procall'd process:\n");
        if (own) printWindow(own); else printf("not found\n");
        uint64_t sid = 43;
        for (NSDictionary *d in (NSArray *)CFBridgingRelease(mdsF(cid))) {
            uint64_t cur = [d[@"Current Space"][@"ManagedSpaceID"] unsignedLongLongValue];
            sid = cur; break;
        }
        id un = ((id(*)(id,SEL,int,uint64_t))objc_msgSend)(
            ((id(*)(id,SEL))objc_msgSend)(NSClassFromString(@"SLSBridgedProcessAssignToSpaceOperation"),
                sel_registerName("alloc")),
            sel_registerName("initWithProcess:spaceID:"), getpid(), sid);
        bridgedOps(@[un]);
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.3]];
        if (own) printWindow(own);
        [w close];
        return 0;
    }
    if ([verb isEqualToString:@"reqmgmt"]) {
        int arg = argc > 3 ? atoi(argv[3]) : 1;
        if (reqMgmtF) {
            printf("SLSRequestSpaceManagement(%d) -> %d\n", arg, reqMgmtF(cid, arg));
        } else { printf("no SLSRequestSpaceManagement symbol\n"); return 1; }
        uint64_t mask = 1ULL << 11;
        printf("SLSSetWindowTags bit11 -> %d\n", setTagsF(cid, wid, &mask, 64));
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.2]];
        printWindow(wid);
        return 0;
    }
    if ([verb isEqualToString:@"pidof"]) {
        NSArray *list = CFBridgingRelease(CGWindowListCopyWindowInfo(0, kCGNullWindowID));
        for (NSDictionary *w in list)
            if ([w[(id)kCGWindowNumber] intValue] == (int)wid) {
                printf("%d\n", [w[(id)kCGWindowOwnerPID] intValue]);
                return 0;
            }
        printf("not found\n");
        return 1;
    }
    if ([verb isEqualToString:@"procall"] || [verb isEqualToString:@"procspace"]) {
        int pid = argc > 3 ? atoi(argv[3]) : 0;
        if (!pid) { printf("needs pid\n"); return 2; }
        id op;
        if ([verb isEqualToString:@"procall"]) {
            op = ((id(*)(id,SEL,int))objc_msgSend)(
                ((id(*)(id,SEL))objc_msgSend)(NSClassFromString(@"SLSBridgedProcessAssignToAllSpacesOperation"),
                    sel_registerName("alloc")),
                sel_registerName("initWithProcess:"), pid);
        } else {
            uint64_t sid = argc > 4 ? strtoull(argv[4], NULL, 0) : 0;
            if (!sid) { printf("needs space id\n"); return 2; }
            op = ((id(*)(id,SEL,int,uint64_t))objc_msgSend)(
                ((id(*)(id,SEL))objc_msgSend)(NSClassFromString(@"SLSBridgedProcessAssignToSpaceOperation"),
                    sel_registerName("alloc")),
                sel_registerName("initWithProcess:spaceID:"), pid, sid);
        }
        bridgedOps(@[op]);
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.4]];
        printWindow(wid);
        printf("%s\n", onscreen(wid) ? "onscreen" : "offscreen");
        return 0;
    }
    if ([verb isEqualToString:@"add1"]) {
        uint64_t sid = argc > 3 ? strtoull(argv[3], NULL, 0) : 0;
        if (!sid) { printf("needs space id\n"); return 2; }
        id op = ((id(*)(id,SEL,id,id))objc_msgSend)(
            ((id(*)(id,SEL))objc_msgSend)(NSClassFromString(@"SLSBridgedAddWindowsToSpacesOperation"),
                sel_registerName("alloc")),
            sel_registerName("initWithWindows:spaces:"),
            @[[NSNumber numberWithInt:(int)wid]], @[@(sid)]);
        bridgedOps(@[op]);
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.4]];
        printWindow(wid);
        printf("%s\n", onscreen(wid) ? "onscreen" : "offscreen");
        return 0;
    }
    if ([verb isEqualToString:@"ownjoin"]) {
        NSRect f = NSMakeRect(400, 400, 220, 160);
        NSWindow *w = [[NSWindow alloc] initWithContentRect:f
            styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
        w.backgroundColor = [NSColor systemBlueColor];
        [w orderFront:nil];
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.3]];
        uint32_t own = 0;
        NSArray *list = CFBridgingRelease(CGWindowListCopyWindowInfo(
            kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements, kCGNullWindowID));
        for (NSDictionary *x in list)
            if ([x[(id)kCGWindowOwnerPID] intValue] == getpid() &&
                [x[(id)kCGWindowLayer] intValue] == 0) { own = [x[(id)kCGWindowNumber] intValue]; break; }
        if (!own) { printf("own window not found\n"); return 1; }
        printf("stage: own wid %u\n", own);
        printWindow(own);
        NSArray *sids = desktopSpaceIDs();
        printf("stage: %lu spaces\n", (unsigned long)sids.count);
        id op = ((id(*)(id,SEL,id,id))objc_msgSend)(
            ((id(*)(id,SEL))objc_msgSend)(NSClassFromString(@"SLSBridgedAddWindowsToSpacesOperation"),
                sel_registerName("alloc")),
            sel_registerName("initWithWindows:spaces:"),
            @[[NSNumber numberWithInt:(int)own]], sids);
        printf("stage: op built\n");
        bridgedOps(@[op]);
        printf("stage: bridged\n");
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.4]];
        printf("stage: settled\n");
        printWindow(own);
        [w close];
        return 0;
    }
    if ([verb isEqualToString:@"move"]) {
        uint64_t sid = argc > 3 ? strtoull(argv[3], NULL, 0) : 0;
        if (!sid) { printf("move needs a space id\n"); return 2; }
        Class opCls = NSClassFromString(@"SLSBridgedMoveWindowsToManagedSpaceOperation");
        id op = ((id(*)(id,SEL,id,uint64_t))objc_msgSend)(
            ((id(*)(id,SEL))objc_msgSend)(opCls, sel_registerName("alloc")),
            sel_registerName("initWithWindows:spaceID:"), @[[NSNumber numberWithInt:(int)wid]], sid);
        bridgedOps(@[op]);
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.4]];
        printWindow(wid);
        printf("%s\n", onscreen(wid) ? "onscreen" : "offscreen");
        return 0;
    }
    if ([verb isEqualToString:@"joinall"] || [verb isEqualToString:@"part"]) {
        NSArray *sids = desktopSpaceIDs();
        printf("desktop spaces:");
        for (id s in sids) printf(" %llu", [s unsignedLongLongValue]);
        printf("\n");
        NSMutableArray *targets = [NSMutableArray array];
        if ([verb isEqualToString:@"joinall"]) {
            [targets addObjectsFromArray:sids];
        } else {
            uint64_t keep = argc > 3 ? strtoull(argv[3], NULL, 0) : 0;
            if (!keep) { printf("part needs a keep-space id\n"); return 2; }
            for (id s in sids)
                if ([s unsignedLongLongValue] != keep) [targets addObject:s];
        }
        Class opCls = NSClassFromString([verb isEqualToString:@"joinall"]
            ? @"SLSBridgedAddWindowsToSpacesOperation"
            : @"SLSBridgedRemoveWindowsFromSpacesOperation");
        id op = ((id(*)(id,SEL,id,id))objc_msgSend)(
            ((id(*)(id,SEL))objc_msgSend)(opCls, sel_registerName("alloc")),
            sel_registerName("initWithWindows:spaces:"),
            @[[NSNumber numberWithInt:(int)wid]], targets);
        bridgedOps(@[op]);
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.4]];
        printWindow(wid);
        printf("%s\n", onscreen(wid) ? "onscreen" : "offscreen");
        return 0;
    }
    int bit = argc > 3 ? atoi(argv[3]) : 11;
    uint64_t mask = 1ULL << bit;
    CGError err;
    if ([verb isEqualToString:@"set"]) {
        err = setTagsF(cid, wid, &mask, 64);
        printf("set bit %d -> CGError %d\n", bit, err);
    } else if ([verb isEqualToString:@"clear"]) {
        err = clearTagsF(cid, wid, &mask, 64);
        printf("cleared bit %d -> CGError %d\n", bit, err);
    } else {
        printf("unknown verb %s\n", verb.UTF8String);
        return 2;
    }
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
    printWindow(wid);
    return 0;
  }
}
```

## Appendix B: regenerating the evidence

```sh
P=/tmp/sticky-probe   # or wherever the probe lives
cd $P
clang -fobjc-arc -O0 -Wno-deprecated-declarations -framework Cocoa -o probe probe.m
mkdir -p Probe.app/Contents/MacOS && cp probe Probe.app/Contents/MacOS/probe
codesign --force -s - Probe.app
./Probe.app/Contents/MacOS/probe pick          # frontmost window: tags + membership
./Probe.app/Contents/MacOS/probe set <wid>     # SLSSetWindowTags bit 11 -> CGError 0, tags unchanged
./Probe.app/Contents/MacOS/probe bridged       # the class list
./Probe.app/Contents/MacOS/probe procall <wid> <pid>   # tags flip to bit11=1, membership all spaces
./Probe.app/Contents/MacOS/probe procspace <wid> <pid> <sid>  # global untag + gather
```

Verification with eyes, not API reads: after `procall`, switch spaces by
hand; the window must still be on screen while `probe onscreen <wid>` says
`offscreen`.

The probe and Probe.app from this session were kept at
`/var/folders/mm/qcbdyzfd63j5ksm8_4c7cqnr0000gn/T/opencode/sticky-probe/`;
that directory is OS-cleanable, so this doc (Appendix A) is the durable
copy.

Primary sources for the cross-checked claims: yabai
`src/osax/payload.m` (sticky = `SLSSetWindowTags` bit 11, tag_size 64;
shadow = bit 3; layer/opacity/move/scale calls; SA socket and opcode
layout; the per-version Dock offset scanning) and the yabai wiki
"Disabling System Integrity Protection" (the Route A recipe, current Apr
2026); Loop `Loop/Private APIs/SLSWindowTags.swift` (the tag bit table,
from SkyLight's own debug strings on 26.3.1); yabai issues #2593
(universal-owner entitlement method + maintainer confirmation),
#2634/#2644/#2764 (26.x pattern churn), #2707 (sudoers sha256 pattern),
#2741 (boot-args plural), #2747 (remote-thread injection failure modes);
5T33Z0's OC-Little boot-args table and OCLP PATCHEXPLAIN (`amfi=0x80` =
`AMFI_ALLOW_EVERYTHING`, identical to `amfi_get_out_of_my_way=1`).
