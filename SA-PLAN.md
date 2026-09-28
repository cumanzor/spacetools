# SA plan: per-window sticky spaces via a Dock scripting addition

Date: 2026-09-28. Decision and full research: `docs/window-on-all-spaces.md`
(verdict: per-window "appear on all spaces" is window tag bit 11,
`SLSSetWindowTags`/`SLSClearWindowTags`; every write path from a normal
process is silently gated, so the write must run from inside the Dock).
Route A chosen over the AMFI-off entitlement route. This file is the build
plan to execute once SIP is relaxed.

License note: yabai is MIT (LICENSE.txt), and the ported pieces (loader
mechanics from `src/scripting_addition`, `do_space_focus` in phase 2,
`do_window_sticky`'s call shape) carry a one-line origin comment in the
ported code, same convention as the InstantSpaceSwitcher credit in
`spacetool.m`. Personal repo, never distributed, so MIT imposes nothing
today; the comments keep the provenance honest if that ever changes.

## 0. SIP prerequisite (one time, per the yabai wiki recipe, Apple Silicon 13+)

Recovery (power button at boot, Options > Continue > Utilities > Terminal):

```sh
csrutil enable --without fs --without debug --without nvram
```

Back in macOS, then reboot:

```sh
sudo nvram boot-args="-arm64e_preview_abi"    # boot-args, plural
```

Verify after reboot:

```sh
csrutil status        # partial/unknown wording is expected on new macOS
nvram boot-args       # -arm64e_preview_abi
```

Rollback at any time: Recovery `csrutil enable`, then
`sudo nvram -d boot-args`, reboot. Nothing else this plan installs touches
system state; uninstalling is removing the .sa and the sudoers file.

If anything else gets relaxed in the same Recovery session, pass every
group in a single csrutil call: each `csrutil enable --without ...` call
writes the whole config, so a second partial call re-seals whatever the
first one opened. Concretely, to also use vphone-cli (Lakr233, MIT; virtual
iPhone via Virtualization.framework + PCC research guests), the whole
session is:

```sh
csrutil enable --without fs --without debug --without nvram
csrutil allow-research-guests enable    # separate csrutil verb, stacks fine
```

vphone needs no AMFI relaxation (its privileged helper passes each
verified VM binary through AMFI per-binary), so it does not erode this
plan's keep-AMFI-armed rationale. Its own docs' `csrutil enable --without
debug` line is the one to skip in favor of the combined call above.

## 1. Phase 1: sticky windows (the goal)

### 1.1 Payload: `spacetoosa.m` -> `SpaceToolSA.sa`

A minimal scripting addition, no Dock internals at all (the yabai September
tax is entirely their `dock_spaces`/`dppm`/function-offset scanning, which we
do not need for tier 0):

- `__attribute__((constructor))` on load: resolve
  `SLSMainConnectionID`, `SLSSetWindowTags`, `SLSClearWindowTags`,
  `SLSWindowQueryWindows` + iterator family (for the query opcode), then
  start a pthread hosting a unix domain socket at
  `/tmp/spacetool-sa_$USER.socket`, mode 0600 (yabai's shape).
- Wire protocol: 1 byte opcode, then fixed fields.
  - `0x01` HELLO -> reply payload version + which SLS symbols resolved
    (so the CLI can fail loudly on an OS update instead of silently).
  - `0x02` STICKY_SET: `uint32 wid` -> set bit 11, reply CGError.
  - `0x03` STICKY_CLEAR: `uint32 wid` -> clear bit 11, reply CGError.
  - `0x04` STICKY_QUERY: `uint32 wid` -> reply current tag word + bit 11
    state.
- The tag word is a mask, `tag_size` 64, bits: 11 (`onAllWorkspaces`).
  Room to grow later: bit 3 (shadow), sublevel/opacity opcodes are trivial
  additions on the same socket.

Build: arm64e payload (the Dock is an arm64e process; that is what
`-arm64e_preview_abi` is for):

```sh
clang -arch arm64e -framework Foundation -dynamiclib \
  -o SpaceToolSA.sa/Contents/MacOS/SpaceToolSA spacetoosa.m
```

Bundle: `SpaceToolSA.sa` with an Info.plist (OSAXcript-style scripting
addition bundle) installed to `/Library/ScriptingAdditions/`. Codesigned
with the stable identity from `codesign.env` (same DR-pinned requirements
as the other two apps; an adhoc payload would break the sudoers hash below
on every rebuild).

### 1.2 Injector: `spacetool load-sa`

Port yabai's loader mechanics (`src/scripting_addition` /
`sudo yabai --load-sa`): task_for_pid on the Dock, write the payload path,
remote thread that dlopens it. Needs root, so:

- `make install-sa` writes a sudoers entry pinned to the installed binary's
  sha256 (yabai's documented pattern):

  ```sudoers
  <user> ALL=(root) NOPASSWD: sha256:<sha256> <path>/SpaceTool --load-sa
  ```

- `--load-sa` idempotent: checks the socket answers HELLO first, injects
  only if not. Prints symbol-resolution failures as errors.
- Re-injection on Dock restart: SpaceBadge already polls the Dock every
  300ms for Mission Control detection; add Dock-pid-change detection there
  that shells the NOPASSWD load. (yabai users do this with a
  `dock_did_restart` signal; we have a daemon already.)

### 1.3 CLI verbs in `spacetool.m`

- `stick [query]`: default target is the frontmost window (same pick logic
  as `send`: first onscreen layer-0 window >= 120x120). Optional arg matches
  an app by name and sticks its frontmost window instead. Sends STICKY_SET
  over the socket, then STICKY_QUERY to verify the tag took, prints result.
  Exit 1 with a "run make install-sa" hint when the socket is dead.
- `unstick [query]`: STICKY_CLEAR, same shape.
- `stick list`: every layer-0 window with bit 11 set (HELLO first for
  symbol sanity; enumerate via CGWindowList + STICKY_QUERY).
- Shims: `~/.local/bin/stick`, `~/.local/bin/unstick` in the Makefile's
  install block, plus the Raycast script pair.

Not in phase 1 (deliberately): per-app sticky via the bridge ops. It works
today with no SIP changes and should stay a separate concern; the SA gives
us the per-window precision the bridge cannot.

### 1.4 Makefile

- `sa`: build + bundle + codesign the .sa (needs `codesign.env`; refuse to
  build it adhoc, since the sudoers hash and Dock library validation both
  want a stable identity).
- `install-sa`: sa + copy to `/Library/ScriptingAdditions/` + sudoers entry
  + HELLO check.
- `uninstall-sa`: remove bundle + sudoers entry (+ `killall Dock` note:
  the payload dies with its host; nothing persistent remains).

### 1.5 Acceptance checklist (run with eyes, per the research doc's
section 2: API reads lie for tagged windows)

1. `make install-sa`, then `spacetool stick` on the terminal window.
2. Switch spaces by hand: the window is on screen on every space.
3. `spacetool unstick`, switch again: normal single-space behavior.
4. `sw <anywhere>` while sticky: window still everywhere; `send` still
   moves it (move preserves bit 11, verified in research).
5. `killall Dock`; SpaceBadge re-injects within a few seconds; HELLO
   still answers; repeat 2.
6. Reboot: LaunchAgent brings SpaceBadge up, Dock restarts, re-inject
   fires; repeat 2.

## 2. Phase 2 (optional): instant `sw` through the SA

Port yabai's `do_space_focus`: find the `dock_spaces` pointer (one hex
pattern per OS version), update the display's `_currentSpace` ivar, then
ShowSpaces/HideSpaces/`SLSManagedDisplaySetCurrentSpace` from inside the
Dock. Wins: no gesture synthesis, no Accessibility/TCC dependency, no
swipe-velocity hacks; the Dock-ivar poke is the desync fix the 2026-07-30
changelog entry reverse-engineered from outside. Cost: one pattern to
maintain per macOS version. Keep the gesture path as fallback when the
pattern misses.

## 3. Phase 3 (optional): create/rm without Mission Control

The Dock's own `addSpace`/`removeSpace` via scanned function pointers
(yabai's `do_space_create`/`do_space_destroy`), which also routes around
the `com.apple.private.windowmanager.spacemanagement` wall documented in
`docs/space-creation-without-mission-control.md`. Full September tax (2-5
patterns per OS release; yabai churned them 26.0 -> 26.4). Design rule from
the start: SA path first, AX/MC path as automatic fallback when the pattern
scan misses, so create/rm degrade to today's ~0.6s instead of failing.

## 4. Risks and unknowns

- Loader mechanics (remote thread into the Dock) are the part of the plan
  not exercised yet on 27.0; yabai's tracker shows loader regressions on
  their side (7.1.17) that were their bug, not macOS hardening, and the
  wiki recipe is current (Apr 2026) through 26.x. First acceptance run
  tells us on 27.
- The payload's stability depends only on the four SLS symbols; all four
  verified present on 26A428, and the HELLO opcode reports resolution so
  an OS update degrades loudly, not silently.
- An OS update that breaks the loader (not the payload) just means stick
  commands fail with a clear error until the injector is re-ported; per-app
  sticky via bridge ops remains the zero-SIP fallback for the whole feature.
- Mission Control rendering of a window present on every space (thumbnail
  in each space row) was not examined; check during acceptance, expect it
  to mirror how the wallpaper/Dock windows behave.
- codesign.env identity signs the .sa; losing it (cert expiry) breaks the
  sudoers hash until re-issued, not the runtime payload already loaded.
