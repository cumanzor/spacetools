# Creating a desktop space without Mission Control on macOS 27 (SIP on)

Date: 2026-09-24. Machine: macOS 27.0 (26A428), arm64e, Xcode 26.6.0.
Companion to the handoff note (`~/Desktop/spacetools-macos27-handoff.md`), which
fixed the MC breakage and first mapped the "no create without MC" wall. This
doc is the full verification of that wall: what was retested live, what was
read out of the disassembly, and a reference section for the
WindowServer/WindowManager internals mapped along the way.

## Verdict

With SIP enabled there is no way for a third-party process to create a
*managed* desktop space (one that appears in Mission Control and
`CGSCopyManagedDisplaySpaces`) without going through the Mission Control UI.
Every server-side path funnels through an entitlement,
`com.apple.private.windowmanager.spacemanagement`, that only Apple-platform-
signed binaries can hold. `spacetool create`'s MC round trip (now ~0.6s after
71405ee) is the floor. The Shortcuts claim in the handoff is confirmed, and it
generalizes: no Shortcuts action, AppleScript surface, CGS call, or XPC
endpoint on this system creates spaces for an unentitled client.

The one nuance to keep straight: `CGSSpaceCreate` does succeed from a normal
process, but returns a type 3 unmanaged overlay space that never joins the
managed list and is destroyed immediately. "Not possible" means no managed
space, per the handoff's probe.

## 1. The Shortcuts claim, verified

The handoff said: "Shortcuts/App Intents: WindowManager, Dock, Mission Control
and ControlCenter ship no desktop create/remove intent." Confirmed, and the
system-wide sweep goes further.

The App Intents metadata lives in `Metadata.appintents/extract.actionsdata`
inside each bundle. On this build exactly three relevant bundles ship it:

- `/System/Library/CoreServices/WindowManager.app/Contents/PlugIns/WindowManagerControlsExtension.appex`
  (Mission Control moved here in 27, along with the MC actions)
- `/System/Library/CoreServices/Dock.app/Contents/PlugIns/DockControls.appex`
- `/System/Library/CoreServices/ControlCenter.app/Contents/PlugIns/DisplayControls.appex`

WindowManagerControlsExtension exports 7 actions, nothing else:

| action | title | parameters |
|---|---|---|
| AppExposeAction | Application Windows | none |
| CornersTileAction | Tile Windows to Corners | none |
| MissionControlAction | Mission Control | none |
| ShowDesktopAction | Show Desktop | none |
| StageManagerToggleIntent | Enable Stage Manager | bool (SetValue protocol) |
| ThreeUpTileAction | Tile Windows Left & Corners | none |
| TwoUpTileAction | Tile Windows Left & Right | none |

DockControls and DisplayControls contain nothing space-related at all.

System-wide: all 1393 `extract.actionsdata` files on the volume were scanned.
Every space/desktop hit is either a Settings preference toggle (Mission
Control Settings "Displays have separate Spaces", Desktop/Widget Settings
"Show wallpaper on all Spaces", "Click wallpaper to show desktop", and so on)
or the Show Desktop trigger. No action anywhere creates or removes a space.
No legacy `.intentdefinition` file does either.

The AppleScript route is closed the same way: System Events still has a
`desktop` class, but it is read-only wallpaper properties; `make new desktop`
fails with -10000.

## 2. Entitlement landscape on 27

A sweep of `/System/Library`, `/usr/libexec` and `/System/Applications` for the
literal entitlement string in code signatures found exactly **one** on-disk
binary holding `com.apple.private.windowmanager.spacemanagement`:
`WindowManagerControlsExtension.appex`. Its entitlements:

- `com.apple.private.windowmanager` = true
- `com.apple.private.windowmanager.spacemanagement` = true
- sandboxed, with mach-lookup exceptions for `com.apple.windowmanager.external`
  and `com.apple.dock.server`, and read-only prefs for `com.apple.WindowManager`

So the Control Center extension is the one legitimate external client of the
space-management XPC. It is Apple-signed and its entire scriptable surface is
the 7 intents above. There is no confused deputy to ride.

For reference, the other holders:

- `Dock.app` holds the base `com.apple.private.windowmanager` (it is an admin
  protocol client, see below, but not a space creator)
- `WindowManager.app` (the agent) holds `com.apple.private.skylight.windowmanager`
  and runningboard keys

## 3. The three Mach services, probed live

`launchctl print gui/501` shows `com.apple.WindowManager.agent`
(program: `/System/Library/CoreServices/WindowManager.app`) registering three
Mach services:

- `com.apple.windowmanager.server`
- `com.apple.windowmanager.external`
- `com.apple.windowmanager.dragserver`

The handoff only probed `.external`. A small XPC client (source in Appendix A)
connected to each and sent `{opcode: 0x1000, probe: "spacetools"}` after 600ms:

| service | result |
|---|---|
| `.external` | message accepted, then `CONNECTION_INTERRUPTED` ~1ms later. Same behavior as the handoff's stub. |
| `.server` | **replied** `{"bsxpc": "invalidate"}`, then interrupted. A protocol-level response, not a silent cancel. |
| `.dragserver` | connection held open for the full 5s window; garbage message ignored entirely. |
| bogus name (control) | `CONNECTION_INVALID` at connection creation. |

The reply key gave it away: `bsxpc` is BaseBoard's auto-coding XPC layer
(`bsxpc_SEL`, `bsxpc_CID`, `bsxpc_BATCH`, `BSXPCAutoCoder` symbols). So
`.server` is the **admin** XPC protocol (`AdminXPCListener` /
`AdminXPCConnection` in WindowManager.framework, the Dock-facing interface),
and `.external` is the `ExternalRequest` protocol the controls extension uses.
Two different protocols, and the question became whether the admin one gates
its space operations differently.

## 4. Reading the framework out of the dyld cache

`/System/Library/PrivateFrameworks/WindowManager.framework` is a stub on disk
(Info.plist and signature only; the binary lives in the shared cache, which is
also why the handoff needed a hand-written .tbd to link against it). The WM
agent's app binary, by contrast, is standalone on disk but only *consumes* the
admin API; the protocol implementation is in the framework.

Extraction recipe (nothing on the system does this for you anymore):

1. `/usr/lib/dsc_extractor.bundle` is a flat universal bundle, not directly
   executable. dlopen it from a tiny host program and call the exported
   `dyld_shared_cache_extract_dylibs_progress(cache, outdir, progress_block)`.
   Note the name: the old `dyld_shared_cache_extract_macho_files` symbol no
   longer exists (bundle is dyld-27062).
2. Point it at
   `/System/Volumes/Preboot/Cryptexes/OS/System/Library/dyld/dyld_shared_cache_arm64e`.
   Full extraction is ~6.4GB and a couple of minutes.
3. The extracted `WindowManager.framework/Versions/A/WindowManager` keeps its
   cache vmaddrs, symbol table and ObjC metadata, so `otool -tV` output
   cross-references cleanly.

Useful anchors in the extracted binary (all vmaddrs):

- `com.apple.private.windowmanager.spacemanagement` cstring: `0x2a5f0b440`
- `com.apple.private.windowmanager` cstring: `0x2a5f0b4b0`
- entitlement-check helper: `0x2a5ea56b0`
- base-entitlement predicate (builds the 31-char string, calls the same
  helper shape): `0x2a5eaffac`
- `_objc_msgSend$valueForEntitlement:` selector stub: `0x2a5f4a360`
- Swift symbols in the cache LINKEDIT confirm the client API is real:
  `synchronouslyRequestCreateManagedSpace(displayUUID: String?) async throws
  -> UInt64` and `synchronouslyRequestDestroySpace`

## 5. What the disassembly says: the gate is per request, inside the handlers

The admin protocol is rich. Handler log strings enumerate the operations:
`assignWindows`, `currentDockWindowIDs`, `setDockInfo`, `xpcActivateWindow`,
`xpcAddWindowsToSpace`, `xpcBegin/EndDesktopPeekMonitor`, draggable overlay
sessions, expose coordinator begin/end + toggle, window picking modes and
sessions, remote transition in/out coordination, modal reveal assertions,
`setSpaceChangeDeltasEnabled`, `spacesDidChange`, `spacesDidChangeOrder`,
`updateFullscreenSpaceNames`, `didProvideVisibilityHintForSpace`, tile window
requests, `diagnose`, and the two we care about:
`adminXPCConnectionRequestsCreateManagedSpace` and `requestsDestroySpace`.

The create handler (the function containing the log string at `0x2a5eb0b5c`)
does this at entry, before any other work:

1. materialize `com.apple.private.windowmanager.spacemanagement` as a Swift
   String (outlined helper, called at `0x2a5eb0aa4`)
2. call the entitlement check at `0x2a5eb0ac4` (`bl 0x2a5ea56b0`)
3. on failure, branch to the error path at `0x2a5eb0ba8`, which builds an
   `AdminXPCConnectionError` and replies

The destroy handler checks the same entitlement at `0x2a5eb0d88`. Even the
tile-window handler checks it at `0x2a5eb6330`. So the spacemanagement gate is
per-request and by operation name, not just a connection-accept check.

The check helper takes (connection, entitlement string) and ends up in
`valueForEntitlement:` on the connection object (via the selector stub and the
msgSend trampolines in the `libobjcMsgSend30` region at `0x2A8000000`). That
resolves the peer's entitlements from its **audit token** (SecTask), server
side. Nothing in it reads the message payload, so a crafted message cannot
spoof the entitlement; the `bsxpc: invalidate` reply we got was just the outer
coder rejecting the dictionary, and a perfectly formed bsxpc create message
would hit the same wall one layer in.

Conclusion for `.server`: dead. Both `.external` (connection-level cancel per
the handoff and our probe) and `.server` (per-request gate per the
disassembly) require the same entitlement we cannot hold.

## 6. The CGS client surface has no managed create

Sweeping the cache symbol table for space-related CGS exports:

- `CGSSpaceCreate` / `CGSSpaceDestroy` / `CGSSpaceCreateTile`
- `CGSMoveManagedSpaceToDisplayIndex` (moves an existing managed space between
  displays; requires a second display and a spare space; not a creator)
- `CGSAddWindowsToSpaces`, `CGSMoveWindowsToManagedSpace`
- `CGSManagedDisplaySetCurrentSpace`, `CGSManagedDisplayGetCurrentSpace`,
  `CGSCopyManagedDisplaySpaces`, etc.

There is no `CGSManagedSpaceCreate`-shaped export. Managed-space creation is
server-side only (WindowManager via the entitlement-gated XPC), which matches
the handoff's type-3 probe result.

## 7. Avenues examined and rejected

**`com.apple.spaces.plist` seeding.** The file still exists on 27
(`~/Library/Preferences/com.apple.spaces.plist`), is live-updated during the
session, and holds the full managed-space list per monitor (ManagedSpaceID,
uuid, type). WindowManager has a real persistence stack for it
(`SkyLightPersistableSpaceStateStore`, `PersistableSpaceStateHandler`,
`FileSystemPersistableFileStateStore`, and a `com.apple.windowmanager.persistence`
XPC). The open question was whether WindowServer rebuilds spaces from the file
at session start. Rejected for this tool: it would only ever work as
restore-at-login (a logout/in per change), and the file is likely clobbered by
a logout-time save anyway. Not tested further; the MC path at login covers the
layout-restore use case in ~a second per desktop.

**Virtual displays.** `CDVirtualDisplayCreate` / `CDVirtualDisplayCreateWithOptions`
are present in CoreDisplay and work with SIP on (the BetterDisplay approach).
A new display does get real managed spaces in `CGSCopyManagedDisplaySpaces`.
But they live on the phantom display, not the physical one; you would be
switching to spaces whose pixels go nowhere unless mirrored, which is its own
can of worms. Rejected as unusable for `spacetool`'s purpose.

**Fullscreen-window trick.** Making a window fullscreen does create a managed
space without MC, but it is a type 1 fullscreen space bound to that window,
not a desktop. Not equivalent.

## 8. SIP and the per-binary question

No per-binary SIP exemption exists. SIP is system-wide policy enforced in the
kernel (AMFI, the OS static trust cache, the sealed system volume):

- `csrutil enable --without <flag>` partial disables exist (fs, nvram, debug,
  dtrace) but are global and need a recovery boot to set.
- Apple Silicon "Reduced Security" in Startup Security Utility only relaxes
  kext / system-extension policy, not entitlements.
- Provisioning-profile entitlements for dev-signed apps are limited to an
  Apple-defined allowlist (app groups, keychain, iCloud);
  `com.apple.private.*` is not obtainable that way.

`com.apple.private.windowmanager.spacemanagement` requires the binary's CDHash
in Apple's platform trust cache. Patching or re-signing any Apple binary
invalidates its hash. So with SIP on, the entitlement is unreachable, full
stop, and the confused-deputy sweep (section 2) closed the indirect route.

## 9. WindowServer / WindowManager internals reference (26A428)

Everything below was observed on this build while chasing the create-space
question. Recorded here so it doesn't live only in the Desktop handoff and
the session scratchpad. Addresses and symbols are from 26A428.

### Process and service topology

- The Window Manager is a GUI-domain launchd agent,
  `com.apple.WindowManager.agent`, program
  `/System/Library/CoreServices/WindowManager.app/Contents/MacOS/WindowManager`.
  The agent binary is standalone on disk (not in the shared cache); the
  protocol implementation it consumes lives in WindowManager.framework,
  which is cache-only (see the dyld notes below).
- It registers three Mach services: `com.apple.windowmanager.server`,
  `.external`, `.dragserver`.
- Further XPC service names referenced in the agent binary:
  `com.apple.windowmanager` (base), `com.apple.windowmanager.persistence`,
  `com.apple.windowmanager.stagemanager`,
  `com.apple.windowmanager.SystemUIModeMonitor`.
- The split of responsibilities: SkyLight (WindowServer) remains the actual
  space manager (the CGS surface and the "Management Data" in the spaces
  plist are WindowServer-side). WindowManager, the agent, is the policy and
  UI layer: it owns the Mission Control UI, the Dock proxying, the
  persistence stores, and the admin/external protocols.

### Mission Control UI on 27

- MC moved out of the Dock into WindowManager.app. The Dock's layer 18 MC
  window is gone. While MC is up, WindowManager shows layer 19
  "ExposeShieldWindow" windows, one per display, plus a Dock window at
  layer 20. MC detection must accept Dock/18 (26 and earlier) or
  WindowManager/19 (27).
- The AX tree shape is unchanged (AXApplication > mc.display > mc.spaces >
  mc.spaces.list / mc.spaces.add) but it now hangs directly off the
  WindowManager AXApplication. The Dock still carries an AXGroup id=mc with
  no children.
- The + button (mc.spaces.add) only exists while MC is on screen. With MC
  closed, WindowManager exposes only AXShowDesktop/AXHideDesktop and no
  children.

### The two client protocols

- `.server` is the admin protocol: BaseBoard bsxpc auto-coding
  (`bsxpc_SEL` / `bsxpc_CID` / `bsxpc_BATCH` / `bsxpc_context` message keys,
  `BSXPCAutoCoder` classes in BaseBoard), implemented by AdminXPCListener /
  AdminXPCConnection in WindowManager.framework. The Dock is its natural
  client (it holds the base `com.apple.private.windowmanager`).
- `.external` is the ExternalRequest protocol: Swift-native XPC dictionaries
  with ExternalRequest/ExternalResponse value types, continuation tracking
  (ExternalContinuation, "No continuation for external response with ID
  ..."), and external overlay items. The Control Center extension
  (WindowManagerControlsExtension.appex) is its client and carries
  spacemanagement.
- `.dragserver` holds connections open and silently ignores non-drag
  messages (live probe); it serves the drag/DnD overlay path (draggable
  overlay sessions appear in both the admin op list and the agent's class
  list).

### Admin protocol operations (from handler log strings)

Space management: `adminXPCConnectionRequestsCreateManagedSpace`,
`requestsDestroySpace`, `didProvideVisibilityHintForSpace`,
`spacesDidChange`, `spacesDidChangeOrder`, `setSpaceChangeDeltasEnabled`,
`updateFullscreenSpaceNames`, `xpcAddWindowsToSpace`, `assignWindows`
(assignWindows:toSpaces:removingFrom:).

Expose/MC: `xpcBegin/EndExposeCoordinator`, `toggleExposeMode`,
`xpcBegin/EndDesktopPeekMonitor`, desktopPeekMonitorStateDidChange.

Windows: `xpcActivateWindow`, `currentDockWindowIDs`, `setDockInfo`,
`expectedFrameForTarget`, window picking modes/sessions (begin/end, session
configuration and client-info updates, ordered-windows-per-space queries),
modal reveal assertions (take/release, assertionsDidCancelWithIDs),
tile window requests (two-up/three-up/corners), remote transition
coordination (begin/release, cancel and finalize in/out), windowing mode
monitor (begin/end, state change), draggable overlay sessions
(begin/end, target-did-close), minimumDockRevealAmountDidChange,
`preemptiveAddWindowIDs`, `diagnose`.

Error surface: `AdminXPCConnectionError` with kinds including
stageManagerNotEnabled, assertionNotHeld, assertionAlreadyHeld.

Agent-side class names (WindowManagerAgent module) seen while mapping this:
WSSpaceManager, WSDisplayManager, WorkspaceModel, WorkspaceDisplays,
DockController, DockGlobals, ExposeCoordinator, AppIconManager,
LabelWindow / MaterialLabelWindow / ExposeLabelUtility, MCDragContext,
CoreDragListener, TilingOverlayLayer, SpringBehavior, AnimationGroup,
ProgressAnimation, ClientFenceGroup, WMSLSTransaction, CGWindowValidator,
SystemEventSource, SystemMenuMonitor, WindowProjection / LayerProjection.

### Space persistence

- `~/Library/Preferences/com.apple.spaces.plist` is still the store,
  live-updated during the session. Structure: SpacesDisplayConfiguration >
  "Management Data" (Age, Management Mode) > Monitors[] > per-monitor
  "Current Space" (ManagedSpaceID, id64, type, uuid) and a Spaces[] array
  with the same fields; the plist also carries the window-to-space bindings.
- WM's persistence stack (class names from the agent binary):
  PersistenceManager, SystemPersistenceStore, PersistableFileStateHandler,
  PersistableSpaceStateHandler, SkyLightPersistableSpaceStateStore,
  FileSystemPersistableFileStateStore, ComponentPersistableStateProvider /
  CacheUpdating, plus the `com.apple.windowmanager.persistence` XPC service.
  The SkyLight-prefixed store name says WindowServer owns the canonical
  state; the plist is the hand-off between sessions.

### CGS / SkyLight surface of interest

Client-callable functions (cache symbol table): CGSSpaceCreate /
CGSSpaceDestroy / CGSSpaceCreateTile, CGSCopyManagedDisplaySpaces,
CGSGetSpaces / CGSCopySpaces / CGSGetActiveSpace / CGSDefaultSpace,
CGSManagedDisplayGetCurrentSpace / CGSManagedDisplaySetCurrentSpace,
CGSMoveManagedSpaceToDisplayIndex, CGSMoveWindowsToManagedSpace,
CGSAddWindowsToSpaces / CGSRemoveWindowsFromSpaces,
CGSSpaceAddWindowsAndRemoveFromSpaces, CGSSpaceAddOwner /
CGSSpaceRemoveOwner, CGSSpaceCopyName / CopyOwners / CopyShape /
CopyManagedShape, CGSGetSpaceManagementMode,
CGSGetSpacePermittedResizeDirections, CGSGetWindowWorkspace
(IgnoringVisibility), CGSCopySpacesForWindows, CGSCopyManagedDisplayForSpace,
and the CGSession workspace family (GetWorkspaceData, SetWorkspaceDictionary,
LaunchWorkspace, KillWorkspace, SetWorkspacesBindingDictionary, ...).

No managed-space create exists anywhere in the client surface.

Workspace dictionary keys seen alongside: CGSWorkspaceOwnerKey /
OwnerIsStubKey, CGSWorkspaceSpaceIDKey, CGSWorkspaceTypeKey,
CGSWorkspaceSwitchOnAppActivationKey, CGSWorkspacePrincipalFullScreenWindowID,
CGSWorkspaceTile* (Type / Rect / Window / LimitedClipping / SpaceArray),
CGSWorkspaceSizeConstraints* (Min / Max / Preferred),
CGSWorkspaceReservedArea* (Top / Bottom / Left / Right),
CGSWorkspaceWallSpaceKey. Also CGSPackagesSpaceAutoCreatedKey, a hint that
some package/drag flow can auto-create a space internally (unexplored).

### Synthetic input on 27 (from the sw fix)

27's Dock ignores a synthetic dock swipe that only sets the CGEvent gesture
fields. The working event carries the raw IOHID fluid-touch payload appended
to the serialized event as field 4205 (gesture type 23, flavor 3, plus a
velocity event on the ended phase), with began/changed/ended phases 10ms
apart (recipe from jurplel/InstantSpaceSwitcher, macos-27 branch + PR #88,
MIT; same root cause as yabai #2822 and mac-mouse-fix PR #1920).
Serialization format v2 only.

### Entitlement map (codesign-verified)

| binary | com.apple.private.* holdings |
|---|---|
| WindowManager.app (agent) | skylight.windowmanager; also com.apple.runningboard.windowmanager |
| Dock.app | windowmanager (base only) |
| WindowManagerControlsExtension.appex | windowmanager + windowmanager.spacemanagement (only holder of the latter) |

The agent binary also references the entitlement names
`com.apple.private.windowmanager.desktopwindowowner` and
`com.apple.private.windowmanager.stubs` (checks it performs on other
processes, not holdings).

### dyld shared cache layout (research notes)

- The OS ships in a cryptex; the cache lives at
  `/System/Volumes/Preboot/Cryptexes/OS/System/Library/dyld/` as ~80 subfiles
  plus a `.map` that lists every image's segment ranges.
- All images share one LINKEDIT range (0x2D60FC000 -> 0x339B0C000 on this
  build) in a separate `.dyldlinkedit` subfile; symbol-table string sweeps
  should target that file (it's where the synchronouslyRequestCreate/
  DestroySpace Swift symbols live).
- Framework bundles under /System/Library/PrivateFrameworks are stubs on disk
  (Info.plist + signature, no Mach-O); the real code is cache-only. That is
  why linking against WindowManager.framework needs a hand-written .tbd and
  why nm on the on-disk stub shows nothing.
- The cache reserves a no-image region at 0x2A8000000
  (libobjcMsgSend30.dylib plus trampolines) where cross-image msgSend and
  runtime calls land; bl targets in that range do not resolve to any image
  in the .map, which is what the valueForEntitlement: call chain goes
  through.

## Appendix A: XPC service probe (wmxpc.c)

Compile: `clang -O2 -Wall -o wmxpc wmxpc.c`. Run: `./wmxpc <mach-service>`.
Prints connection lifecycle with CLOCK_UPTIME_RAW timestamps; sends a probe
message at 600ms; exits at 5s. Unbuffered stdout, because with a pipe the
default buffering reorders nothing but hides timing.

```c
#include <xpc/xpc.h>
#include <dispatch/dispatch.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

static double now_s(void) {
    return (double)clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / 1e9;
}

int main(int argc, char **argv) {
    setvbuf(stdout, NULL, _IONBF, 0);
    if (argc < 2) { fprintf(stderr, "usage: %s <mach-service>\n", argv[0]); return 2; }
    const char *name = argv[1];

    xpc_connection_t c = xpc_connection_create_mach_service(name, NULL, 0);
    if (!c) { printf("%.3f create FAILED for %s\n", now_s(), name); return 1; }
    printf("%.3f connection object created for %s\n", now_s(), name);

    xpc_connection_set_event_handler(c, ^(xpc_object_t obj) {
        xpc_type_t t = xpc_get_type(obj);
        if (t == XPC_TYPE_ERROR) {
            const char *desc = xpc_dictionary_get_string(obj, XPC_ERROR_KEY_DESCRIPTION);
            const char *kind = "ERROR";
            if (obj == XPC_ERROR_CONNECTION_INTERRUPTED) kind = "CONNECTION_INTERRUPTED";
            else if (obj == XPC_ERROR_CONNECTION_INVALID) kind = "CONNECTION_INVALID";
            else if (obj == XPC_ERROR_TERMINATION_IMMINENT) kind = "TERMINATION_IMMINENT";
            else if (obj == XPC_ERROR_PEER_CODE_SIGNING_REQUIREMENT) kind = "PEER_CODE_SIGNING_REQUIREMENT";
            printf("%.3f event %s: %s\n", now_s(), kind, desc ? desc : "(no desc)");
        } else {
            char *desc = xpc_copy_description(obj);
            printf("%.3f event REPLY: %s\n", now_s(), desc ? desc : "?");
            if (desc) free(desc);
        }
    });
    xpc_connection_set_finalizer_f(c, NULL);
    xpc_connection_resume(c);

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 600 * NSEC_PER_MSEC),
                   dispatch_get_main_queue(), ^{
        xpc_object_t msg = xpc_dictionary_create(NULL, NULL, 0);
        xpc_dictionary_set_uint64(msg, "opcode", 0x1000);
        xpc_dictionary_set_string(msg, "probe", "spacetools");
        printf("%.3f sending probe message\n", now_s());
        xpc_connection_send_message(c, msg);
        printf("%.3f probe sent\n", now_s());
    });

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5000 * NSEC_PER_MSEC),
                   dispatch_get_main_queue(), ^{
        printf("%.3f 5s elapsed, exiting (no cancel from server = connection held)\n", now_s());
        exit(0);
    });

    dispatch_main();
}
```

## Appendix B: regenerating the evidence

```sh
# extract the cache (see section 4 for the dlopen host)
./dschost /System/Volumes/Preboot/Cryptexes/OS/System/Library/dyld/dyld_shared_cache_arm64e dscx

WM=dscx/System/Library/PrivateFrameworks/WindowManager.framework/Versions/A/WindowManager
otool -arch arm64e -tV $WM > wmtext.asm

# the gates: search for the entitlement strings and the check helper
grep -n 'literal pool for: "com.apple.private.windowmanager' wmtext.asm
grep -n "bl	0x2a5ea56b0" wmtext.asm          # entitlement check, 3 call sites
grep -n 'literal pool for: "AdminXPCListener adminXPCConnectionRequestsCreateManagedSpace"' wmtext.asm

# live service probe
clang -O2 -Wall -o wmxpc wmxpc.c
./wmxpc com.apple.windowmanager.server
```

The full `wmtext.asm` (9.5MB) and `wmxpc.c` from this session were kept at
`/var/folders/mm/qcbdyzfd63j5ksm8_4c7cqnr0000gn/T/opencode/wmprobe/`; that
directory is OS-cleanable, so treat this doc as the durable copy.
