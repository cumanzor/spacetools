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

## How it works

Window moves and space switches go through the private SkyLight bridge classes
(`SLSBridgedMoveWindowsToManagedSpaceOperation`,
`SLSBridgedManagedDisplaySetCurrentSpaceOperation`) via
`SLSWindowManagementFallbackBridge`. This is the same mechanism yabai adopted
in 2026 for SIP-enabled space operations. The legacy CGS calls
(`CGSAddWindowsToSpaces` etc.) are dead for foreign windows on macOS 26; they
only work on windows you own.

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
- `CGSSpaceSetName` exists but writes the space UUID field. Do not use it.

## Build

```sh
make install   # builds, bundles to ~/Applications, shims to ~/.local/bin
```

Binaries must live inside an .app bundle; the WindowManagement XPC service
rejects bare executables. `~/.local/bin/{spacename,sw,bring}` are shims into
SpaceTool.app.

Raycast scripts live in `~/Documents/scripts/Raycast` (already registered as a
Script Commands directory).
