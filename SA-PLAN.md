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

- LANDED 2026-09-30, live-verified on 27.0. Design details and acceptance
  results: `~/Desktop/spacetools-phase-1.5-handoff.md` (phase 1.5). Shape:
  the injector is a standalone `loadsa` binary installed at
  `~/Applications/SpaceTool.app/Contents/MacOS/loadsa` (a bundle seal covers
  extra `MacOS/` binaries, but a re-sign never rewrites them, so plain
  `make install` does not invalidate the pin), pinned by a sha256 sudoers
  entry (`make refresh-sa` regenerates `/private/etc/sudoers.d/spacetools-sa`
  after every loadsa rebuild; visudo-validated, root only wraps the write),
  and SpaceBadge re-runs it via `sudo -n` on every Dock pid change. `loadsa`
  itself HELLO-checks the socket first (SUDO_USER, since sudo resets USER),
  so re-runs are no-ops.
- `--load-sa` idempotence landed as the socket pre-check above.
- Re-injection on Dock restart: landed in SpaceBadge (pid watch on the
  existing 300ms tick; yabai users wire this as a `dock_did_restart` signal
  by hand, we have a daemon already).

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
- `install-sa`: sa + refresh-sa + copy to `/Library/ScriptingAdditions/` +
  `sudo -n` load (full one-shot).
- `refresh-sa`: re-bundle SpaceTool with the fresh loadsa + regenerate the
  sudoers pin (run after every loadsa rebuild; plain `make install` does not
  invalidate the pin, since bundle re-signs never rewrite nested `MacOS/`
  binaries).
- `uninstall-sa`: remove bundle + sudoers pin + bundle loadsa (+ `killall
  Dock` note: the payload dies with its host; nothing persistent remains).

### 1.5 Acceptance checklist (run with eyes, per the research doc's
section 2: API reads lie for tagged windows)

Status 2026-09-30, live on 27.0 (26A428) with the relaxations above:

1. DONE: `sudo ./loadsa` -> "payload injected into Dock". Unprivileged run
   fails exactly at task_for_pid, which doubles as an arm64e-flag smoke test.
2. DONE: `spacetool stick` on the terminal -> "stuck window ... appears on
   all spaces" (tag flip verified in the reply). User-verified by hand:
   the window renders on every space.
3. DONE: `spacetool unstick` -> bit cleared, `stick list` empty.
4. DONE: `stick list` roundtrip both states.
5. ANSWERED, negative: `killall Dock` does NOT auto-load the osax at Dock
   startup on 27 (socket dead 6s later). The payload dies with its host, so
   re-injection after every Dock restart is required. This makes the
   sudoers + SpaceBadge re-inject automation (1.2) mandatory, not optional.
6. NOT YET: reboot persistence (needs the sudoers re-inject from 1.2 first).
   Note the operational consequence of 5: reboot = Dock starts clean, so
   until 1.2 lands, stick commands after a reboot need `sudo ./loadsa`.

Phase 1.5 (auto re-injection) status 2026-09-30, live on 27.0 (26A428):1. DONE: `sudo -n ~/Applications/SpaceTool.app/Contents/MacOS/loadsa` is
   passwordless from any terminal (pin at /private/etc/sudoers.d/spacetools-sa,
   0440 root:wheel, no args allowed).
2. DONE: `killall Dock` (multiple runs; re-injects logged into pids 4548,
   24007, 25007 and 26179) -> SpaceBadge re-injects within ~2s of the Dock
   finishing launch, the socket answers HELLO, `stick` roundtrips. Failure
   path also live-verified: a corrupted bundle loadsa (sha mismatch) ->
   sudo -n denies in ~12ms, SpaceBadge logs "sa re-inject failed (sudo
   exit 1): sudo: a password is required" once per restart, `stick` shows
   the hint + exit 1, no hang.
3. DONE (2026-09-30): reboot with SpaceBadge's LaunchAgent: payload auto
   re-injected at login (log line "sa re-injected into Dock" at boot
   time), stick answered with zero manual steps, user stuck a window by
   hand post-reboot. Phase 1.5 is fully accepted.
4. DONE: rebuild + refresh: refresh-sa re-pins (the running pin survived
   byte-identical rebuilds and three `make install` re-signs; loadsa
   rebuilds are byte-deterministic for an unchanged toolchain, so the pin
   only goes stale on a real source/toolchain change).
5. DONE: the stale-hash simulation above (restore was `make install`, which
   re-copies the repo loadsa into the bundle; recovery re-injected
   automatically on the next Dock restart).

Also found live: `sudo make install-sa` signs as root and dies with
errSecInternalComponent (root cannot reach the login keychain); the target
now refuses a root run, sudo only wraps the rm/cp.

Multi-display wrinkle, answered live 2026-09-30 (was the unverified open
item, now closed with a partial fix): plugging/unplugging a display rebuilds
the space set and collapses a stuck window back to its home space while its
tag bit stays set (the tag read then lies, per docs/window-on-all-spaces
section 2). Worse, re-running stick could not repair it: SLSSetWindowTags
with the bit already set rebuilds no membership. Fix in spacetool.m: stick
always clears then sets, forcing the 0->1 transition; verified live (an
iTerm window stranded after plugging a Sidecar display was repaired by
clear+set, membership went from [7] to [6,7,8]). Deferred: a payload opcode
that re-applies every stuck window's tag on SpaceBadge's
screensChanged, so display changes need no re-stick at all.

## 2. Phase 2: `sw` through the SA

Status 2026-10-01: DONE through step 4, live on 26A428. The route ended up
pattern-free: the class dump (`sa-dump`) found yabai's dock_spaces as class
`Spaces`, a scan of the Dock's __DATA for allocator-vetted pointers
(`sa-find`) finds the one live instance, and instead of the ivar poke the
payload calls the Dock's own `-[Spaces switchToUserSpace:]` (0-based
user-space index; negative traps, so the id is resolved inside the Dock).
`sw` and MC+digit use it, the swipe is the fallback. Details in
detailed_changelog 2026-10-01. The plan text below is the original design.

Port yabai's `do_space_focus`: find the `dock_spaces` pointer (one hex
pattern per OS version), update the display's `_currentSpace` ivar, then
ShowSpaces/HideSpaces/`SLSManagedDisplaySetCurrentSpace` from inside the
Dock. Wins: no gesture synthesis, no Accessibility/TCC dependency, no
swipe-velocity hacks; the Dock-ivar poke is the desync fix the 2026-07-30
changelog entry reverse-engineered from outside. Cost: one pattern to
maintain per macOS version. Keep the gesture path as fallback when the
pattern misses.

2026-09-30 note (corrected 2026-10-01: the swipe presented correctly in
every test the next day, including DisplayLink off/on; what it does have is
dropped swipes during MC dismissal and stale-base overshoot): the gesture
path is now broken outright after display
churn (synthesized fluid-touch switches stop running the desktop
presentation; survives reboot, all display combos; not our regression,
full elimination matrix in detailed_changelog 2026-09-30 16:52:59). That
promotes phase 2 from "optional instant" to "the durable switch path";
finding dock_spaces via the ObjC runtime from inside the Dock (class/
ivar/selector names instead of hex patterns) is the approach to try
first. The bounded alternative if phase 2 stalls: capture a real swipe
and diff the raw IOHID field-4205 payload against the synthesized one.

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
