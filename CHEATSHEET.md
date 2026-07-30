# spacetools cheatsheet

## Daily driving (Raycast)

| Type in Raycast | What happens |
|---|---|
| `sw comm` | switch to the space named "comms" (prefix match) |
| `sw 3` | switch to Desktop 3 |
| `bring messages` | pull Messages' windows to this space and focus them |
| `name this space` + `comms` | name the space you are on |
| `name this space` (empty arg) | clear the current space's name |
| `list spaces` | all spaces, `*` marks where you are |

Or open Mission Control and press `1`-`9`.

## Terminal equivalents

```sh
spacename              # name of the space you are on
spacename list         # all spaces, * = current
spacename set comms    # name current space ("" clears)
sw comm                # switch by name prefix or number
bring spark            # move app windows here + focus (fuzzy app match)
```

## Badges

- Named spaces show a translucent badge top-right. Unnamed spaces show nothing.
- Mission Control shows the strip under the thumbnails: `1 ·  2 xcode  3 dev ...`
  (`·` = unnamed, order matches thumbnails left to right).
- Rename or clear a name and the badge updates within ~2s.

Open Mission Control and press `1`-`9` to jump to that space. MC closes and you
land there. Digits past the last space do nothing and stay in Mission Control.
Needs Accessibility for SpaceBadge (System Settings > Privacy & Security >
Accessibility); without it the rest of the daemon still works and only this is
off.

This was built and pulled once before. The reason recorded at the time
(switching while MC is open corrupts WindowServer) was wrong: the real problem
was a bridged switch desyncing the Dock, MC open or not. `sw` no longer switches
that way, so it works now.

## Daemon control

```sh
make install-agent                                    # rebuild + reload (idempotent)
launchctl bootout gui/501/dev.umanzor.spacebadge      # stop + disable until login
launchctl bootstrap gui/501 ~/Library/LaunchAgents/dev.umanzor.spacebadge.plist  # re-enable
```

`make install-agent` writes the plist and does the bootout + bootstrap for you.
Never `kickstart -k` after a rebuild: launchd caches the old cdhash and it dies
with `OS_REASON_CODESIGNING`.

## Build

`make install` signs with a stable identity if `codesign.env` exists (gitignored,
see `codesign.env.example`), otherwise adhoc. Use the stable identity: SpaceBadge
needs an Accessibility grant for the digit switching, and an adhoc signature
changes every build, so macOS drops the grant each rebuild. The designated
requirement is pinned to the team OU so cert renewal won't drop it either.

`make install` covers the binaries, bundles and shims. `make install-agent` does
that plus the LaunchAgent and a daemon reload, which is what you want on a new
machine or after any rebuild.

## Where things live

| Thing | Path |
|---|---|
| names | ~/.config/spacenames.json (keyed by space UUID, survives reboots) |
| CLIs | ~/.local/bin/{spacename,sw,bring} (shims into SpaceTool.app) |
| apps | ~/Applications/{SpaceTool,SpaceBadge}.app |
| Raycast scripts | ~/Documents/scripts/Raycast/{sw,bring,name-space,list-spaces}.sh |
| LaunchAgent | ~/Library/LaunchAgents/dev.umanzor.spacebadge.plist |
| source | ~/repos/AI/spacetools (make install rebuilds everything) |

## When it breaks

- `bring`/`sw` stop working after a macOS update: the private SkyLight bridge
  changed. Check yabai issue #2789 and asmvik/yabai for the new API shape.
- Badge on wrong space or stacked badges: `make install-agent` to restart the
  daemon. `kickstart -k` works only if you have not rebuilt since it started.
- `1`-`9` does nothing in Mission Control: SpaceBadge lost its Accessibility
  grant. Most likely you rebuilt with adhoc signing, which changes the signature
  every time. Set up `codesign.env` and re-grant once.
- Names gone: spaces were recreated (UUIDs changed). Re-run `spacename set` per space.
- New display or big layout change: badges reposition ~1s after the screen
  settles, and again 2.5s later. If one is stuck offscreen after a dock/undock,
  that observer is the thing that broke.
- `sw` prints "the Dock ignored the gesture": either Mission Control was open
  (it swallows the swipe gesture, so dismiss it first), or the caller lacks
  Accessibility. TCC attributes the event to whatever launched `sw`, so grant it
  to Raycast or your terminal, or to ~/Applications/SpaceTool.app if you are
  running the binary directly.
