[2026-09-30 04:43:47 UTC] [spacetool/Raycast stick/unstick pair]
[Files Changed]
- ~/Documents/scripts/Raycast/stick.sh, unstick.sh - new. send.sh shape
  (schemaVersion 1, silent mode, Spaces package, Carlos author), optional
  app-name argument ("optional": true, since the CLI query is optional),
  exec the ~/.local/bin shims. Closes the deferred-polish item from the
  phase 1.5 handoff (the spacetool load-sa verb remains deferred).
- CHEATSHEET.md - daily-driving table rows (stick / stick <app> / unstick /
  stick list), terminal-equivalent block lines, a stick paragraph in the
  send/bring section (per-window "All Desktops", SA payload requirement,
  auto re-inject after Dock restarts), stick,unstick added to the Raycast
  paths row, and a when-it-breaks entry (not-loaded -> stale sudoers pin ->
  make refresh-sa, else check SpaceBadge's log).
[Testing Notes]
- Scripts are plain exec shims over the live-verified phase 1.5 shims; no new
  binary path. Raycast picks up new script commands on its next directory
  scan (or add the directory if it is not the configured script directory,
  which it is: the other Spaces commands live there).

[2026-09-30 03:58:49 UTC] [spacetool/Phase 1.5: sudoers-pinned auto re-injection after every Dock restart]
[Attempt #1 for this feature, live-verified on 27.0 (26A428); reboot item pending user eyes]
[Files Changed]
- loadsa.m - idempotent: payloadActive() HELLO-checks
  /tmp/spacetool-sa_<user>.socket before injecting (SUDO_USER with USER
  fallback, since sudo resets USER to root; 250ms SO_RCVTIMEO so a hung
  payload cannot hang the injector). Re-runs of the pinned binary are now
  no-ops ("payload already active in Dock (pid N)", exit 0) instead of
  spawning a fresh remote thread per call.
- Makefile - refresh-sa target: re-bundles SpaceTool with the fresh loadsa
  (via BUNDLE's new 3rd argument), then regenerates
  /private/etc/sudoers.d/spacetools-sa: <whoami> ALL=(root) NOPASSWD:
  sha256:<hash of bundle loadsa> <bundle path> "" (no args allowed), written
  through /tmp + visudo -c validation + sudo install -o root -g wheel -m 0440
  (sudo only wraps that write; target refuses a root run because codesign
  needs the login keychain). install-sa = sa + refresh-sa + osax copy +
  sudo -n load (one-shot full setup). install: all loadsa + BUNDLE copies
  loadsa into SpaceTool.app before its codesign. uninstall-sa also drops the
  sudoers pin and the bundle loadsa.
- spacebadge.m - Dock-pid watch on the existing 300ms tick: static dockPidSeen;
  on 0->pid (agent start/boot) or pid change, reinjectSA(pid) dispatches to a
  utility queue: skips if no bundle loadsa, waits for isFinishedLaunching
  (up to 10s at 100ms), settles ~1s, bails if a newer Dock pid superseded it,
  HELLO-checks (already alive = silent return), then NSTask /usr/bin/sudo -n
  <bundle loadsa> with stdout+stderr piped. Result logged via os_log with
  %{public}s on failure / NSLog on success (launchd sends agent stderr to
  /dev/null, so fprintf was invisible; NSLog strings other than the piped
  output render fine, the piped sudo stderr needed %{public}s to escape
  <private> redaction).
- spacetool.m - saNotLoaded hint now points at the phase 1.5 world (SpaceBadge
  re-injects; manual fix is make refresh-sa or sudo -n the pinned loadsa).
- README.md, SA-PLAN.md - 1.2 marked landed with the shape + acceptance
  results; 1.4 target list updated; phase 1.5 acceptance appended to 1.5.
[Codesign facts established by experiment (they shaped the design)]
- A bundle seal DOES cover extra MacOS/ binaries: copying a file into MacOS/
  after signing breaks verify --deep --strict ("a sealed resource is missing
  or invalid"), so the loadsa cp must precede the app's codesign (BUNDLE).
- The outer re-sign never rewrites nested MacOS/ binaries (sha256 stayed
  identical across two --force identity re-signs; nested file keeps its clang
  adhoc signature). Therefore plain make install never invalidates the
  sudoers pin; only a loadsa rebuild (source/toolchain change) does.
- loadsa rebuilds are byte-deterministic for an unchanged toolchain (rm +
  make loadsa reproduced the same sha256), so the pin only goes stale on a
  real change, and refresh-sa is the regen step for exactly that.
[What was verified live]
- refresh-sa end to end (via a SUDO_ASKPASS osascript dialog for the one sudo
  write): visudo "parsed OK", file landed 0440 root:wheel.
- Acceptance 1: sudo -n ~/Applications/SpaceTool.app/Contents/MacOS/loadsa
  from any terminal, passwordless (idempotent no-op when already loaded).
- Acceptance 2: killall Dock x4 across the session; every new Dock pid
  (4548 agent-start, 24007, 25007, 26179) was auto re-injected within ~2s
  of finishing launch; socket answers HELLO; stick/unstick/stick list
  roundtrips on the re-injected payload.
- Acceptance 5 (stale hash, simulated by appending one byte to the bundle
  loadsa, which is what a stale pin denies): sudo -n denies in ~12ms (no
  prompt, no hang), SpaceBadge logs once per restart "[spacebadge] sa
  re-inject failed (sudo exit 1): sudo: a password is required (stale
  sudoers hash? run make refresh-sa)", stick degrades to the hint + exit 1.
  Recovery: make install re-copies the repo loadsa (self-heal; seal restored
  by the same re-sign), next Dock restart auto re-injected.
- Acceptance 4 (light): the pin survived three make install re-signs and
  byte-identical rebuilds; refresh-sa itself ran on a freshly rebuilt loadsa
  (the idempotence change) and every subsequent sudo -n used that new hash.
[The sudoers pin semantics worth remembering]
- sudo hashes the whole file (adhoc clang signature included) and matches it
  against the sha256 in the line; the nested binary's own signature plays no
  role for sudo, only the seal fact above does for bundle integrity.
- The pin is narrow: sudo -n on anything but that exact file still prompts
  (verified: sudo -n cat was denied), so a changed loadsa fails loud, not
  open.
[Possible Ripple Effects]
- sudoers.d/spacetools-sa grants root execution of exactly one file to
  carlos; a hash mismatch disables it (fail-closed).
- SpaceBadge spawns sudo -n once per Dock pid change (and once per agent
  start when the payload is dead); a failed attempt is logged, not retried,
  until the next pid change or agent restart.
- A loadsa.m edit now requires make refresh-sa afterwards (or auto re-inject
  silently stops working; stick falls back to the hint, never a silent no-op).
[Testing Notes]
- Remaining unverified: reboot persistence (SA-PLAN 1.5 item 3, user eyes;
  the 0->pid path at login covers it in code, agent is RunAtLoad) and
  multi-display behavior of a stuck window (carried over from phase 1).
- The payload's NSLog visibility note from the handoff still stands: use
  Console.app filtered on the process; the [spacebadge] lines are visible in
  `log show --predicate 'process == "SpaceBadge" AND eventMessage CONTAINS
  "[spacebadge]"'`.
- Deferred polish (tracked): a `spacetool load-sa` verb wrapping the pinned
  loadsa. (The Raycast stick/unstick pair from the same list landed in the
  2026-09-30 04:43:47 entry above.)

[2026-09-30 03:12:23 UTC] [spacetool/Phase 1 live-verified: injection, stick, unstick, list; no osax auto-load on Dock restart]
[Attempt #1 for this verification; build was the 2026-09-30 02:49:45 entry below]
[Files Changed]
- Makefile - stick/unstick shims added to the install block (uninstall drops
  them too, and points at uninstall-sa).
- README.md - Dock-restart consequence documented (payload dies with its
  host; sudo ./loadsa to restore; phase 1.5 pending).
- SA-PLAN.md - acceptance checklist marked with live results, including the
  negative auto-load answer and the errSecInternalComponent lesson.
- simple_changelog.md, detailed_changelog.md - this entry.
[What was verified live on 27.0 (26A428), relaxations + boot-arg in place]
- sudo ./loadsa: "payload injected into Dock (pid 718)". The unprivileged
  run fails exactly at task_for_pid ("run as root"), which doubles as a
  smoke test that the arm64e binary executes (boot-arg active).
- spacetool stick: "stuck window 221 (iTerm): appears on all spaces". The
  tag flip is verified in the reply (bit 11 set), not just the CGError code.
- Visual ground truth, per the 2026-07-20 lesson: the user switched spaces
  by hand and the window rendered on every space. Confirmed verbally.
- spacetool unstick: bit cleared, window back on its own space; stick list
  empty afterward, and stick list showed the window while it was stuck
  (QUERY roundtrip both states).
[The negative result that matters]
- killall Dock + 6s: the socket is gone. The Dock does NOT auto-load
  /Library/ScriptingAdditions osax bundles at startup on 27 under this
  configuration (fs+debug+nvram off, arm64e flag on). The payload dies with
  its host process, so every Dock restart (including every reboot) needs
  re-injection. Consequence: the sudoers sha256 entry + SpaceBadge Dock-pid
  watch auto re-inject from SA-PLAN 1.2 goes from optional to mandatory
  (phase 1.5), otherwise stick is a manual sudo away after each reboot.
[Also found live]
- sudo make install-sa: codesign as root cannot reach the login keychain
  ("unable to build chain to self-signed root", errSecInternalComponent)
  and leaves root-owned spacetools.osax/ behind. Fixed in ba6b8c1: the
  target refuses a root run, and the invocation is make install-sa with
  sudo only wrapping the rm/cp.
[Possible Ripple Effects]
- The Dock now hosts our socket thread permanently (until its next restart);
  one ignored signal disposition (SIGPIPE) inside the Dock.
- Until phase 1.5 lands, a reboot silently reverts stick commands to the
  not-loaded hint (exit 1, no data loss; re-inject to restore).
[Testing Notes]
- Remaining unverified: reboot persistence (blocked on phase 1.5's re-inject
  automation), and multi-display behavior of a stuck window (untouched).

[2026-09-30 02:49:45 UTC] [spacetool/Feature: stick/unstick per-window via a Dock scripting addition, phase 1 built]
[Attempt #1 - live verification still pending the reboot; see Testing Notes]
[Files Changed]
- spacetoosa.m - new. arm64e payload dylib, dlopen'd into the Dock by loadsa.
  Constructor resolves SLSMainConnectionID, SLSSetWindowTags, SLSClearWindowTags
  and the SLSWindowQuery iterator family via dlsym(RTLD_DEFAULT) (the Dock links
  SkyLight; no private framework link needed at build time), ignores SIGPIPE
  (a vanished client must not be able to kill the Dock), and starts a detached
  pthread serving /tmp/spacetool-sa_$USER.socket (0600). Opcodes: HELLO (u8
  version + u32 symbol mask, so an OS update that drops a symbol degrades
  loudly instead of silently), STICKY_SET / STICKY_CLEAR (u32 wid, reply i32
  CGError + u64 tags-after), STICKY_QUERY (same reply shape). Zero Dock-internal
  offsets: unlike yabai's payload there is nothing to re-derive per OS release.
  Socket shape ported from yabai's osax payload (MIT, src/osax/payload.m).
- loadsa.m - new. arm64e injector, a port of yabai's src/osax/loader.m (MIT;
  their arm64e injection path is based on work by Jeremy Legendre): root-run,
  task_for_pid on the Dock, allocate stack + code segments, patch the shellcode
  (pthread_create_from_mach_thread at +88, dlopen at +160, payload path at
  +168, same offsets as yabai since the shellcode is copied verbatim), run it
  via thread_create + thread_convert_thread_state and the 14.4+/15+ path of
  terminate + thread_create_running, poll for the 0x79616265 magic. Payload
  path: /Library/ScriptingAdditions/spacetools.osax/Contents/MacOS/spacetoosa.
- spacetool.m - stick/unstick verbs plus stick list, sa socket client
  (saConnect/saHello/saStickyOp), pickStickTarget (frontmost onscreen layer-0
  window >= 120x120, optional app query scoped like bring's matching). stick
  verifies the tag bit actually flipped in the reply and reports the two
  failure modes distinctly (CGError vs the silent-ignore case the research
  doc documented from outside). saNotLoaded prints the install hint. Usage
  string updated. New imports: sys/socket.h, sys/un.h.
- Makefile - sa / spacetoosa / loadsa / install-sa / uninstall-sa targets;
  payload builds -arch arm64e -shared -fPIC -fobjc-arc, loader -arch arm64e.
  install-sa assembles spacetools.osax/ locally, codesigns with the
  codesign.env identity (adhoc fallback with a warning), then sudo rm+cp to
  /Library/ScriptingAdditions. clean drops the new artifacts.
- .gitignore - spacetoosa, loadsa, spacetools.osax.
- README.md - stick/unstick/stick list in the command list + a setup section
  pointing at SA-PLAN.md.
[Why this design]
- The research verdict: only the Dock's connection can write tag bit 11, so
  the write must run inside the Dock; Route A keeps AMFI armed.
- arm64e is mandatory for both binaries: the Dock is an arm64e process and
  only loads arm64e images; running non-Apple arm64e needs the
  -arm64e_preview_abi boot-arg. The flag was still NOT set this session
  (nvram boot-args empty), so neither loadsa nor the payload can run yet.
[Status]
- Compile-verified: arm64e payload + loader + arm64 CLI all build clean;
  stick/stick list correctly report the not-loaded hint against the missing
  socket (exit 1).
- Not yet verified: install-sa (needs sudo), the injection itself, the tag
  flip from inside the Dock, visual across-space rendering, Dock-restart
  behavior (killall Dock: whether the osax auto-loads at Dock startup on 27,
  which would make re-injection free, is untested).
[Possible Ripple Effects]
- The payload alters the Dock process: one ignored signal disposition
  (SIGPIPE) and one detached thread blocking in accept(). It logs to
  Console.app as [spacetool-sa].
- An OS update that renames the four SLS symbols turns stick commands into
  HELLO-reported failures, never silent no-ops.
- loadsa is signed adhoc-or-identity like everything else; the sha256-pinned
  sudoers entry from SA-PLAN.md is deliberately not wired yet (phase 1.5,
  after the mechanism is proven live).
[Testing Notes]
- Next session steps: make install-sa (run as the user; sudo only wraps the
  rm/cp into /Library/ScriptingAdditions. sudo make install-sa signs as root,
  which cannot reach the login keychain and dies with errSecInternalComponent,
  found live); sudo nvram boot-args="-arm64e_preview_abi"; reboot;
  sudo ./loadsa; spacetool stick on
  the terminal; switch spaces by hand and watch the window follow; unstick;
  killall Dock and see whether the payload auto-loads at Dock startup (socket
  answers without loadsa) or needs re-injection.
- Per the 2026-07-20 lesson and the research doc's section 2: acceptance is
  eyes-on (window visible on every space), not API reads, since both
  window-list APIs lie about tagged windows.

[2026-09-28 20:52:42 UTC] [docs/Verified: per-window "appear on all spaces" is tag bit 11, gated to Dock-grade writers; SA route chosen and planned]
[Attempt #1]
[Files Changed]
- docs/window-on-all-spaces.md - new. Companion to the space-creation doc,
  covering the window side: the window-tag mechanism and the full 64-bit tag
  table (Loop's reverse-engineering of SkyLight 26.3.1's short-name debug
  table, positions cross-checked against observed values on 26A428), what
  the compositor actually renders vs what the APIs claim, the per-app bridge
  ops with exact behaviors, every gated per-window path exercised live, the
  dead-unentitled universal-owner route, the Route A/B comparison with the
  exact csrutil/boot-arg recipes and yabai issue-tracker gotchas, the tier
  model of what the SA unlocks, the complete categorized SLSBridged* class
  dump (the first durable copy; README referenced the dump but nothing
  listed it), op signatures from runtime introspection, observed tag values
  decoded, and the probe source + regeneration steps as appendices.
- SA-PLAN.md - new, repo root. The staged build plan for the chosen route:
  SIP prerequisite with verification and rollback, phase 1 payload
  (spacetoosa.m: socket + HELLO/STICKY_SET/STICKY_CLEAR/STICKY_QUERY, pure
  SLS, zero Dock offsets), injector (load-sa + sudoers sha256 entry +
  Dock-restart re-injection via SpaceBadge's Dock poll), stick/unstick
  verbs and shims, Makefile targets, an eyes-on acceptance checklist, and
  optional phase 2 (instant sw via dock_spaces + _currentSpace) and phase 3
  (create/rm via Dock addSpace/removeSpace offsets with AX fallback).
- simple_changelog.md, detailed_changelog.md - this entry. No code changed;
  all probes ran from a scratch .app in the OS temp dir.
[Findings]
- Mechanism: "appear on all spaces" is window tag bit 11 (onAllWorkspaces),
  set in-process by NSWindow canJoinAllSpaces, set cross-process by yabai's
  Dock-injected payload via SLSSetWindowTags(cid, wid, mask, 64). Both tag
  write symbols exist on 27.0 and are silently ignored on foreign windows
  (return kCGErrorSuccess, tags unchanged; same no-op class as SLSMoveWindow).
- Render truth: a tagged window renders on every space (verified live by
  the user switching by hand) while CGWindowListCopyWindowInfo(OnScreenOnly)
  reports it offscreen on the destination space and CGSCopySpacesForWindows
  membership gets stripped back to the home space on real switches. The
  "verify with a screenshot, not an API read" rule now has a second
  documented case, in the opposite direction.
- Per-app works today, no SIP: SLSBridgedProcessAssignToAllSpacesOperation
  (initWithProcess:, int pid) sets bit 11 on all existing windows, registers
  them on every desktop space, and tags windows created later (born
  0x...2801). Reset via ProcessAssignToSpaceOperation clears bit 11 on all
  the process's windows regardless of which space they sit on and gathers
  them to the assigned space. MoveWindowsToManagedSpace preserves bit 11.
  So stick <app>/unstick <app> is implementable today on the existing
  bridgedOps() path.
- Per-window is gated everywhere: no window-level tag op among all
  SLSBridged* classes; SLSBridgedAddWindowsToSpacesOperation no-ops even on
  own windows (single- and multi-space, bundled app, correct NSNumber
  shapes, same array format the working move op takes); every sequence
  dodge fails because the process reset sweeps globally.
- Universal-owner route (issue #2593): all four symbols exist on 27.0.
  Unentitled, SLSNewConnection works but SLSSetUniversalOwner returns 1002
  and tags stay no-op. An adhoc binary signed with
  com.apple.private.skylight.universal-owner is SIGKilled at spawn (exit
  137, zero output): AMFI kills restricted entitlements off platform
  signatures. Route B therefore needs amfi=0x80, which the OpenCore research
  maps as AMFI_ALLOW_EVERYTHING, identical to amfi_get_out_of_my_way=1,
  full AMFI off; no narrower restricted-entitlements bit exists, and AMFI
  off also breaks third-party mic/camera TCC prompts.
- Decision: Route A (scripting addition into the Dock). Recipe: csrutil
  enable --without fs --without debug --without nvram, then
  sudo nvram boot-args="-arm64e_preview_abi". Three CSR groups vs Route
  B's one, but AMFI stays armed and there is no runtime Dock disruption;
  yabai-proven through 26.x. Crucially our payload needs none of yabai's
  Dock-internal offset scanning (their September tax, churned 26.0 -> 26.4
  per issue #2764); sticky is four pure SLS symbols, all verified on 26A428.
[Possible Ripple Effects]
- None on the shipped tools: no repo code changed, all experiments restored
  (both test windows back to bit11=0 on their home space, process
  unassigned).
- SA-PLAN.md phase 1 depends on the loader mechanics (remote thread into
  the Dock) working on 27.0, which is the one untested part of the plan;
  yabai's wiki recipe is current through 26.x and their loader regressions
  (7.1.17) were their own bug.
- Per-app sticky via the bridge remains a zero-SIP fallback for the whole
  feature if the SA route stalls.
[Testing Notes]
- Every live result came from a scratch probe app (bundled, adhoc) in
  /var/folders/.../opencode/sticky-probe; the doc's Appendix A is the
  durable source copy.
- The key verification was visual, not API-based, per the 2026-07-20
  lesson: the user confirmed the tagged window followed manual space
  switches while both window-list APIs said otherwise.
- Probe artifacts worth remembering: buffered stdout hides segfault
  locations (setvbuf unbuffered first); the probe ARC-over-releases at
  autorelease-pool pop after building bridge ops + NSWindow in one run
  (exit 139 at exit, after results print); a loginwindow window can be the
  frontmost layer-0 pick right after boot or a TCC dialog.

[2026-09-25 20:04:06 UTC] [SpaceBadge/UI: MC name strip moved below the expanded space previews]
[Attempt #1]
[Files Changed]
- spacebadge.m:289 - strip origin offset from the screen top goes from 158 to
  196pt. Hovering the Spaces bar in Mission Control expands it into the
  thumbnail row, which reached down over the top of the strip.
[Possible Ripple Effects]
- Strip sits a bit closer to the window thumbnails in the MC body. Offset is
  still fixed, not derived from the bar height, so a different display scale
  or Spaces bar size could need another nudge.
[Testing Notes]
- Open MC, hover the Spaces bar so previews expand; the strip should be fully
  visible below them.

[2026-09-24 22:02:41 UTC] [docs/Verified: no managed space creation without Mission Control on macOS 27 with SIP on]
[Attempt #1]
[Files Changed]
- docs/space-creation-without-mission-control.md - new. Full write-up of the
  investigation that verified the handoff's "not possible with SIP on" claim:
  Shortcuts/App Intents sweep, entitlement landscape, live XPC probes of the
  three WindowManager Mach services, dyld-cache extraction of WindowManager
  .framework, disassembly of the admin XPC create/destroy gates, rejected
  avenues (spaces.plist seeding, virtual displays, fullscreen spaces), the
  SIP per-binary question, and a WindowServer/WindowManager internals
  reference (service topology, MC UI layers on 27, admin protocol operation
  list, spaces plist structure and persistence classes, CGS surface,
  entitlement map, dyld cache layout). Probe source and regeneration steps
  are inlined as appendices so nothing depends on the session scratchpad.
- simple_changelog.md, detailed_changelog.md - this entry.
[Findings]
- Shortcuts: the only desktop/space actions on the entire system volume are
  Settings preference toggles and the Show Desktop trigger (all 1393
  extract.actionsdata files scanned; WindowManagerControlsExtension.appex
  ships exactly 7 trigger/toggle intents). System Events' desktop class is
  read-only wallpaper properties; make new desktop errors -10000.
- Entitlements: exactly one on-disk binary holds
  com.apple.private.windowmanager.spacemanagement (WindowManagerControls
  Extension.appex, sandboxed, no scriptable surface beyond the 7 intents).
  Dock holds only the base com.apple.private.windowmanager. No confused
  deputy exists.
- XPC: com.apple.WindowManager.agent registers .server / .external /
  .dragserver. Live probe: .external cancels after first message (matches the
  handoff stub), .server replies {"bsxpc": "invalidate"} then cancels (it is
  the BaseBoard-coded admin protocol, AdminXPCListener/Connection), .drag
  server ignores garbage.
- Disassembly (framework extracted via dsc_extractor.bundle, symbol renamed
  to dyld_shared_cache_extract_dylibs_progress): the admin handlers
  adminXPCConnectionRequestsCreateManagedSpace (check call 0x2a5eb0ac4) and
  requestsDestroySpace (0x2a5eb0d88) call the entitlement check
  (0x2a5ea56b0) with spacemanagement at handler entry; failure builds
  AdminXPCConnectionError. The check resolves valueForEntitlement: on the
  connection from the peer's audit token, so the message payload cannot
  spoof it. Both alternate services are therefore closed by the same
  entitlement as .external.
- CGS: no managed-create client export exists (CGSSpaceCreate is the only
  create, and the server hands back type 3 unmanaged). CGSMoveManagedSpace
  ToDisplayIndex moves spaces between displays but creates nothing.
- SIP: no per-binary exemption mechanism exists (partial csrutil flags are
  global; provisioning profiles don't carry com.apple.private.*).
[Possible Ripple Effects]
- None on code; no binaries changed. The doc records vmaddrs/symbols from
  build 26A428 only.
[Testing Notes]
- XPC probe run live against all three services plus a bogus-name control;
  results table in the doc. Disassembly cross-referenced by entitlement
  string address (0x2a5f0b440), check-helper call sites, and handler log
  strings. codesign.env re-audited during this work: untracked, ignored at
  .gitignore:4, zero objects/commits/stashes in any ref, values not
  hardcoded anywhere in the tree.
[2026-09-24 21:12:44 UTC] [spacetool/Faster Mission Control round trip for create, rm, layout restore]
[Attempt #1]
[Files Changed]
- spacetool.m waitUntil() - new: polls a block every 20ms until it's true or
  the timeout passes. atLeastMacOS27() wraps the OS version check.
- spacetool.m closeMissionControl() - waits for MC to go away via waitUntil (2s).
- spacetool.m mcSpacesGroupFor() - display group lookup polls at 20ms (3s
  cap, same fallback to the first group). The settle(0.35) only runs before
  27. On 27 it waits until mc.spaces.add exists instead.
- spacetool.m cmdCreate / cmdRemove / cmdLayoutRestore - the new-space and
  space-gone waits use waitUntil (3s). rm also waits up to 1s for the
  thumbnail count to match the space count before its sanity check, since
  it now reaches the list earlier.
[Root cause]
Phase timing on 27 at 10ms polling: + is available 70ms after opening MC,
and the space shows up in CGSCopyManagedDisplaySpaces 24ms after the press.
The fixed 350ms settle plus 100ms polling steps made up most of the old
~1.15s. The ~330ms MC close animation after Escape is the floor.
Creating a space without MC isn't possible with SIP on (WindowManager's
create API needs com.apple.private.windowmanager.spacemanagement). Details in
the handoff note on the Desktop.
[Possible Ripple Effects]
- 26 and earlier keep the 350ms settle, so behavior there is unchanged apart
  from finer polling.
- Timeouts are the same as before (3s for group/space waits, 2s for MC close).
[Testing Notes]
Five create/rm rounds with a throwaway space: create 0.59-0.80s, rm
0.54-0.69s, all succeeded, including process launch. The space list was back
to the original three afterwards. layout restore wasn't run (it would add
desktops), but it shares mcSpacesGroupFor and the same wait helper.

[2026-09-24 20:43:46 UTC] [spacetool/sw ignored on macOS 27]
[Attempt #1]
[Files Changed]
- spacetool.m:7 - imports mach/mach_time.h.
- spacetool.m:108-178 - new postSwipePhase27() and postDockSwipe27(). Each
  phase builds the dock control CGEvent, serializes it with CGEventCreateData,
  appends a 4-byte tag (payload length, field 4205) and an IOHID system queue
  element (fluid touch gesture type 23, flavor 3, plus a velocity event on the
  ended phase), then rebuilds it with CGEventCreateFromData and posts it.
  Began/changed/ended go out 10ms apart. Refuses anything that isn't
  serialization format v2.
- spacetool.m switchToSpace - on majorVersion >= 27, posts one augmented swipe
  per step at 2000 * steps velocity. The old two-phase 9999-velocity gesture
  still runs on 26 and earlier.
[Root cause]
On 27 the Dock only honors a synthetic swipe that carries the raw IOHID
payload. The public gesture fields alone get dropped, so sw posted, waited 2s,
and printed the Accessibility hint, which was wrong this time. yabai's
SIP-enabled switching broke the same way (asmvik/yabai#2822). The working
recipe comes from jurplel/InstantSpaceSwitcher's macos-27 branch plus its PR
#88 (phase pacing), MIT. Mac Mouse Fix PR #1920 reaches the same conclusion by
attaching the event with SLEventSetIOHIDEvent instead.
[Possible Ripple Effects]
- SpaceBadge's 1-9 keys in Mission Control call `SpaceTool switch N`, so they
  were broken by the same thing and are fixed by this.
- Format v2 check: if a later macOS changes the CGEvent serialization, sw fails
  fast with "could not build the swipe event" instead of posting garbage.
- The sign flip on progress/velocity only applies to the 27 path, matching ISS.
[Testing Notes]
A standalone prototype first: +1, -1 and a +2 jump all landed correctly.
After porting, `spacetool switch` 3, 1, 3, personal all exit 0 and land on the
right space, 2-step jumps included. The 1-9 keys inside Mission Control were
confirmed by hand by the user. Synthetic key posts from a test harness were
unreliable for this and aren't a valid check.

[2026-09-24 20:35:58 UTC] [spacetool+SpaceBadge/macOS 27 moved Mission Control out of the Dock]
[Attempt #1]
[Files Changed]
- spacebadge.m:97-110 - mcOpen() returns true for a Dock window at layer 18
  (macOS 26 and earlier) or a WindowManager window at layer 19 (macOS 27).
- spacetool.m:203-216 - mcShowing() gets the same two-way check.
- spacetool.m:225-240 - new mcDisplayGroups() collects mc.display groups from
  the WindowManager app's direct children and from the Dock's "mc" group, so
  the old path still works on older macOS versions.
- spacetool.m:245-277 - mcSpacesGroupFor() creates AX elements for both
  com.apple.dock and com.apple.WindowManager and matches displays across the
  merged list. The display-origin matching and the fallback to the first
  display are unchanged.
[Root cause]
On macOS 27 (26A428) the Mission Control overlay is drawn by
/System/Library/CoreServices/WindowManager.app. While MC is open the window
server shows WindowManager windows at layer 19 (ExposeShieldWindow, one per
display), layer 14 (the 96pt spaces bar) and a Dock window at layer 20. No
Dock window at layer 18 appears anymore, so mcOpen()/mcShowing() always
returned false: SpaceBadge never raised its strip or armed the 1-9 tap, and
spacetool opened MC and then waited for a Dock window that never showed up.
The Dock app still exposes an AXGroup id=mc, but it has no children. The
mc.display > mc.spaces > mc.spaces.list / mc.spaces.add tree is the same as
before, just parented under the WindowManager AXApplication. The thumbnails
still carry AXRemoveDesktop.
[Possible Ripple Effects]
- Layer 19 WindowManager windows may also appear for App Expose. The old Dock
  layer 18 check had the same exposure, so there is no change there.
- On macOS 27 the mc.display AX origin reads 0,0. With "Displays have separate
  Spaces" off there is only one mc.display group, so it matches the main
  display. With separate Spaces on, non-main displays probably fall back to
  the first group after 3s. Untested with that setting on 27.
- The strip still sits 158pt from the top. On 27 it overlaps the top of the
  window thumbnails a little, but it reads fine.
[Testing Notes]
Probed the window list and AX tree before, during and after opening MC.
Escape still closes MC on 27.
After `make install-agent`, opening MC shows the strip ("1 · 2 personal 3 ·");
confirmed by screenshot.
`spacetool create zz-probe` then `spacetool rm zz-probe` both exit 0, run twice.
The desktop list is back to its original three spaces.

[2026-08-10 19:03:53 UTC] [build/install-agent races launchd's teardown]
[Attempt #1]
[Files Changed]
- Makefile:4-5 - LABEL variable, AGENT derived from it. The label appeared in
  four places and the new recipe needs it three more times.
- Makefile:56-59 - comment records the race alongside the existing cdhash note.
- Makefile:71-86 - install-agent polls launchctl print until the label is gone
  from the domain, up to 5s, then bootstraps with up to five retries. The last
  retry runs under exec so launchctl's own error text and exit status reach
  make instead of being swallowed by the 2>/dev/null the retries need.
- Makefile:89 - uninstall uses $(LABEL).
[Root cause]
launchctl bootout returns as soon as the request is accepted, not when the job
is actually gone. With KeepAlive set the daemon takes a beat to die, and the
bootstrap on the next line lands while the label is still registered, so
launchd answers EIO: "Bootstrap failed: 5: Input/output error". Hit it live
while installing the NSApp run fix; the manual retry a second later worked,
which is the tell.
[Possible Ripple Effects]
- Cold install, where nothing is loaded, is unchanged in effect: bootout fails
  into the || true, the first launchctl print fails, the wait loop never runs.
  Tested separately since that path is what a new machine takes.
- A genuinely wedged service now fails the target with a clear message after
  5s instead of failing on the bootstrap line with EIO.
- uninstall keeps its bare bootout. Nothing follows it there, so it has no
  race to lose.
[Testing Notes]
Three back to back `make install-agent` runs over a live agent, all exit 0,
new pid each time (38239, 38357, 38475). The same sequence produced EIO on the
first run before the change.
Cold path: manual bootout, confirmed nothing loaded, `make install-agent`
exits 0 and the agent comes up (39054).
plutil -lint still passes and the generated plist carries the right Label
after the $(LABEL) substitution.
Daemon verified working after the reload churn: strip lands at CG 996,138
568x46 on Mission Control open, alpha tracking MC.

[2026-08-10 18:50:35 UTC] [SpaceBadge/Stale NSScreen: the daemon never saw a display change]
[Attempt #3 - the two earlier strip-placement fixes were treating symptoms]
[Files Changed]
- spacebadge.m:379 - main ends with [NSApp run] instead of
  [[NSRunLoop currentRunLoop] run].
[Root cause]
AppKit only refreshes its NSScreen array, and only posts
NSApplicationDidChangeScreenParametersNotification, while it drains its own
event queue. A bare NSRunLoop services timers and mach ports but never
dequeues those events, so every screen value the process ever reads is the
one sampled at launch.

The daemon is a RunAtLoad LaunchAgent, so it launches while the displays are
still coming up. Caught in the act with lldb against the running pid: the
daemon believed in two displays, the main one 2304x1296, while the machine
actually had three and the main one was 2560x1440. It had been holding the
transient login-time configuration all day.

Everything positional is derived from those numbers, so the strip's target
frame was computed against a screen that no longer existed, and the CG->Cocoa
flip in serverFrames() used the wrong primary height on top of that. The
window ended up parked at CG 0,0, clipped under the Mission Control chrome in
the top-left corner. screensChanged never ran either, so the debounced resync
added in the 2026-07-30 entry could never fire on this machine.

This is why the two previous strip fixes did not hold. Both repaired the
window against a stale target: 3ce898d rebuilt the strip on every poll,
e1e94b2 dropped the unchanged-text early return so place: always ran. Neither
is wrong, and both stay, but a correct repair aimed at a coordinate space that
had not existed since login could only ever move the window to the wrong spot.
[Ruling out the obvious suspect first]
place: itself was the prime suspect, since it is the repair path. A harness
built the same borderless overlay, displaced it behind AppKit's back with
SLSMoveWindow to CG 0,0, and ran place: verbatim: server bounds went from
0,1394 straight back to 1048,1256. place: works. The target was the problem.
[Proving the mechanism]
A/B probe, two identical accessory apps differing only in the final loop,
running at the same time while the menu bar visibleFrame was changed under
them. NSRunLoop: no notification, screens pinned at 2560x1410 across all
fourteen polls. NSApp: notification on both edges, screens updated to
2560x1320 and back within the same second. Nothing else about the two
processes differs.
[Possible Ripple Effects]
- NSApp run calls finishLaunching a second time. Nothing observes
  NSApplicationDidFinishLaunching here, so it is inert.
- The process now processes AppKit events it previously ignored. Activation
  policy is still Accessory, so no menu bar and no Dock tile.
- Timers, the NSWorkspace active-space observer and the CGEventTap source all
  run on the main runloop, which NSApp run pumps. All unaffected, verified
  live: the 1-9 tap and the strip refresh both still work.
- screensChanged now actually fires, so its 1.0s debounce plus 2.5s follow-up
  sync runs for real for the first time. That path was written in July and has
  never executed on this machine.
[Testing Notes]
Before, running daemon, Mission Control held open: strip window pinned at CG
0,0 465x46, alpha tracking MC correctly, position never moving across a 9
second poll. Target should have been CG 996,138.
After rebuild and agent reload: strip lands at CG 996,138 568x46 on MC open,
matching the independently computed frame exactly.
End-to-end, live daemon: toggled the menu bar autohide and watched the badge
windows, which anchor to NSMaxY(visibleFrame). Menu bar shown CG y=44, hidden
y=14, restored y=44, the exact 30pt delta, each within the debounce window.
Before the fix that notification never arrived at all.
Dock autohide, Dock edge and menu bar autohide all returned to their original
values afterwards.

[2026-08-05 19:02:07 UTC] [spacetool/Bare-number queries beat digit-containing names]
[Attempt #1]
[Files Changed]
- spacetool.m:56-61 - matchSpace tries the ordinal first when the query is all
  digits, falling through to name matching when no such ordinal exists. The
  trailing intValue fallback stays for queries like "2fa" that merely start
  with digits.
- README.md - resolution order description updated.
[Root cause]
matchSpace's order was exact name, prefix, substring, then ordinal. A space
named "messaging1" contains "1", so `sw 1` hit the substring branch and never
reached the ordinal branch. Latent since the initial release; surfaced the
moment a space name contained a digit. The MC digit tap is also affected
because SpaceBadge spawns `SpaceTool switch <n>` with ordinals through the
same resolver.
[Possible Ripple Effects]
- A space whose name is purely numeric ("42") is now reachable by name only
  when no Desktop 42 exists; the ordinal wins otherwise. Acceptable: a bare
  number canonically means the Desktop N position everywhere else in macOS.
- sw, send, rm and the MC digit tap all share matchSpace, so all four change
  behavior together.
[Testing Notes]
Live state during the test: comms(1), Desktop 2(current), Desktop 3,
messaging1(4).
- sw 1 -> "switched to comms", spacename confirms (was landing on messaging1).
- sw mess -> messaging1, prefix matching intact.
- sw 2 -> back to the origin space, round trip complete.

[2026-08-05 18:30:54 UTC] [spacetool/create, rm, and layout save/restore verbs]
[Attempt #1]
[Files Changed]
- spacetool.m:156-263 - Mission Control automation layer. AX helpers (axAttr/
  axChildren/axOrigin/axFind/axReady), mcShowing/closeMissionControl, and
  mcSpacesGroupFor(ident): opens MC if needed, polls for the Dock's mc AX
  group, and picks the mc.display child whose AX origin matches the display's
  CGDisplayBounds (the groups carry no identifier of their own).
- spacetool.m:352-384 - cmdCreate. Presses mc.spaces.add, detects the new
  space by uuid diff rather than list position, names it in spacenames.json
  when a name was given.
- spacetool.m:386-434 - cmdRemove. matchSpace resolution, refuses fullscreen
  spaces and the last desktop, sanity-checks thumbnail count against the CGS
  space count before indexing, performs AXRemoveDesktop on the thumbnail at
  ord-1, verifies the uuid is gone, and drops the map entry.
- spacetool.m:436-521 - cmdLayoutSave/cmdLayoutRestore against
  ~/.config/spacelayout.json (display ident -> ordered name array, desktops
  only). Restore creates until the count matches, then names by position.
  Never removes; extras reported and left alone.
- spacetool.m main - create/rm/layout wired in, usage updated.
- README.md, CHEATSHEET.md - new verbs, AX tree map, gotchas.
[Why Mission Control UI and not SkyLight]
SLSSpaceCreate/Destroy exist but only move the window server, the same Dock
desync the bridged switch had (2026-07-30 18:46:50 entry). The Dock's own
interface is Mission Control, and its AX tree turned out to be fully wired:
mc.spaces.add is an ordinary pressable AXButton, and every thumbnail in
mc.spaces.list advertises an AXRemoveDesktop action, discovered by dumping
action names. No hover choreography needed; the earlier hunt for a close
button child was chasing something that never appears in the AX tree.
[One real bug during bring-up]
First -O2 build died with EXC_BREAKPOINT (SIGTRAP) inside mcSpacesGroupFor.
The display-group candidates were held as raw AXUIElementRef into the
temporary NSArray from axChildren(); ARC freed the array (and elements) the
moment fast enumeration ended, so the later CFRetain hit a dead object. At
-O0 the lifetimes stretch and it works, which is what made the -O0 lldb run
pass. Fix: hold candidates as strong ids, CFBridgingRetain at selection time.
Recorded in README gotchas.
[Possible Ripple Effects]
- create/rm/layout restore open Mission Control for ~1-1.5s and dismiss it
  with a synthesized escape. SpaceBadge's digit tap is armed during that
  window but only reacts to bare digits, so the two do not interact.
- rm on the current space is allowed (the Dock switches you to a neighbor);
  only tested removing non-current spaces.
- rm deletes the space's entry from spacenames.json, so recreate-then-rename
  starts clean instead of resurrecting a stale name.
- Multi-display: mcSpacesGroupFor matches display groups geometrically. With
  "Displays have separate Spaces" off (this machine), only the Main block
  exists and the origin-match hits the menu bar display. The separate-spaces
  path is wired but unexercised, same status as spaceList's display handling.
- AXIsProcessTrusted gates all three verbs with an explicit grant message.
  Under lldb the TCC attribution changes and the check fails; run the bare
  binary when debugging.
[Testing Notes]
All space mutations verified against CGS state and by screenshot, per the
2026-07-20 rule.
- create alpha-test, create beta-test: both appeared at the expected ords with
  names in list and map (spaces 100/104, later 116/117 after the rm/restore
  cycle).
- layout save wrote {"Main": ["comms","alpha-test","beta-test"]}.
- rm alpha-test + rm beta-test: back to one space, map clean (grep -c test =
  0).
- layout restore: recreated 2 desktops, applied 3 names; screenshot of MC
  shows Desktop 1/2/3 with real thumbnails, correct highlight, and the
  SpaceBadge strip reading "1 comms  2 alpha-test  3 beta-test", which also
  proves the daemon picked the restored names up on its own (~2s mtime poll).
- Error paths: rm comms with one desktop -> "refusing to remove the last
  desktop", rm nosuchspace -> no match (both exit 1); layout restore with the
  layout already satisfied -> "0 desktops created, 1 name applied", exit 0.
- Cleanup verified: final state one space (comms), layout file re-saved to
  match, Mission Control confirmed closed.
- Not tested: rm of the current space, fullscreen spaces in the bar during
  rm (the thumbnail-count guard covers the indexing risk), separate-spaces
  mode.

[2026-08-05 17:49:09 UTC] [SpaceBadge/MC strip stays displaced after a monitor config change]
[Attempt #1]
[Files Changed]
- spacebadge.m:273-274 - the unchanged-text early return in showStrip is gone.
  The text, frame and place: call now run on every invocation.
- spacebadge.m:298-303 - stripText guards only the label text assignment now;
  place: and the by-hand label re-frame are unconditional.
[Root cause]
Regression from the 2026-07-30 21:36 reorder fix. Its early return (strip
exists and text unchanged -> set alpha, return) sat upstream of the place: call
the 18:46:50 display-change fix depends on, and unchanged text is the steady
state - so once the window server displaced the strip during a monitor config
change, nothing ever repaired it. The badges were fine because their repair
lives in sync(), which has no such short circuit. Probe on the live daemon
showed the strip at CG 0,0 (layer 3, under the Dock's layer-18 MC chrome),
matching the reported screenshot of it dimmed behind the desktop thumbnails.
[Possible Ripple Effects]
- showStrip now calls serverFrames() (a full CGWindowList pass filtered to our
  pid) every 300ms while MC is open, on top of the CGS and JSON reads it already
  did per tick. place: still no-ops when the server frame matches the target,
  so steady state posts no frame changes.
- The label frame is reasserted every call. It has no autoresizing mask, so
  nothing competes with it.
[Testing Notes]
- Pre-fix probe: strip window at CG 0,0 133x46 while the badges sat correctly
  at y 44 right-aligned - the exact displacement signature the 18:46:50 entry
  documented, now permanent because the repair was skipped.
- Post-fix: rebuilt, agent reloaded. Note the first launchctl bootstrap after
  bootout returned error 5 (raced the old instance teardown); a retry 2s later
  succeeded. MC opened, screenshot: strip on its pill, white, centred at CG
  1085,138 on the 2304pt main display, clear of the chrome.
- The displacement itself cannot be re-induced from outside the process
  (SLSMoveWindow is a cross-process no-op, per the 2026-07-30 entry), so the
  repair is verified by the placement path now being unconditional plus the
  correct live render.
- Found while verifying, not caused by the fix: CGS reports a single space.
  com.apple.spaces.plist was rewritten at 11:39:04 local, one minute after
  a screenshot still showed 7 desktops (with black previews), and none
  of the named-space uuids survive in it - macOS consolidated the spaces during
  a display reconfiguration right after boot. The strip rendering "1 comms" is
  correct for that state. The spacenames.json map keeps the dead uuids, so
  recreated spaces need spacename set again.

[2026-07-30 21:36:30 UTC] [SpaceBadge/MC strip goes stale and clips after a space reorder]
[Attempt #1]
[Files Changed]
- spacebadge.m:24 - stripText property, the last rendered string.
- spacebadge.m:246-249 - showStrip returns early when the text is unchanged, so
  it is cheap to call on every tick. sz.width is now ceil'd.
- spacebadge.m:262-274 - the label is no longer created with an autoresizing
  mask and left alone. Its frame is set from the content bounds on every update,
  after place: has run, and the inset went 22 -> 20 so there is 4pt of slack
  against a window that is still text+44 wide.
- spacebadge.m:290 - tick calls showStrip on every poll while MC is open, not
  only on the open edge.
[Two bugs, both needed]
1. The strip only rebuilt on the MC-open edge. Reordering spaces happens inside
   Mission Control, with MC already open, so mcVisible was already YES and
   showStrip never ran again. The strip kept the text from when MC opened.
2. Reordering produces the pathological case for the label: moving "personal"
   from slot 5 to slot 6 rearranges the same glyphs, so the string width is
   identical. The window frame therefore does not change, place: correctly does
   nothing, and because nothing resized the window, autoresizing never fired and
   the label kept whatever width it last had. The new text was set into a label
   still sized for an older, narrower string, and the tail was clipped.
[Measurements]
Before: strip window 630pt wide, text drawn from 23 to 516, leaving 114pt of
empty pill. The missing 94pt is " personal" at 22pt semibold. The label was
about 494 wide where it should have been 586.
After: text 23 to 605 in the same 630pt window, 25pt trailing blank, matching
the 20pt inset on the left.
A standalone harness confirmed autoresizing itself does not drift: fifteen
resize cycles across five different strings held label == window - 44 exactly
every time. So the fault was never drift, it was the resize not happening at all.
It also showed the field's cell wants slightly more than the attributed string
reports (585.5 against 585.2), which is why the label now gets 4pt of slack
rather than exactly the string width.
[Possible Ripple Effects]
- showStrip now runs every 300ms while MC is open. The early return compares one
  string, but it still calls CGSCopyManagedDisplaySpaces and re-reads
  spacenames.json each time to build that string. Fine for the seconds MC is up.
- The label no longer relies on its autoresizing mask at all. The mask is gone,
  so nothing competes with the explicit frame.
[Testing Notes]
- Full string renders again after a reorder, verified by cropping the strip
  window's exact bounds and measuring glyph extent, not by eye.
- Live update verified with MC held open: renaming a space rewrote the strip
  within ~1s, the window resized 630 -> 731 and re-centred 837 -> 786, and the
  text stayed within its margins. Name map restored and diffed afterwards.

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
- Raycast script command added at ~/Documents/scripts/Raycast/send.sh, matching
  the other four (silent mode, so the "sent X to Y" line surfaces as a HUD,
  which matters given send acts on whatever is frontmost). Those scripts live
  outside this repo and are not version controlled with it.
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
close cycle. What does clear it is a real user-driven space switch, confirmed by
hand.
[Testing Notes / process failure]
The first round of testing passed 6 for 6 and was worthless. It probed
CGWindowList and `spacename` and never looked at the screen, so it could not see
that every one of those runs was corrupting the session. The corruption was only
found when it was reported and a screenshot was taken. Anything that changes
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
