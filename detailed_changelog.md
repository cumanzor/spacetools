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
