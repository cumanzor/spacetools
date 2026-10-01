# The Dock's add_space / remove_space on 26A428: symbol map and how the payload drives them

Date: 2026-10-01. Machine: macOS 27.0 (Build 26A428), Apple M4 Pro, arm64e.
Companion records: `detailed_changelog.md` 2026-10-01 22:46:46 (the
implementation entry),
`~/Desktop/spacetools-wm-26a428-handoff.md` (the route analysis), and
asmvik/yabai#2832 (the patterns and the live 27.2 result this all rides on).
This doc is the full static-analysis record: what the two routines actually
do inside our exact Dock build, how every call target was resolved without
symbols, and how each finding maps into `spacetoosa.m` v6.

License note: the byte patterns and the call recipes ported here originate
in yabai (MIT) - issue asmvik/yabai#2832 and the branch
`LCS-Dev-Ergos/yabai:fix/macos-27-scripting-addition`
(`src/osax/arm64_payload.m`, `src/osax/payload.m`). Same provenance
convention as the other ported pieces in this repo.

## 0. Summary

| | add_space | remove_space |
|---|---|---|
| arm64e slice offset | `__TEXT+0x228cbc` | `__TEXT+0x18b9a0` |
| arm64e.x1 slice offset | `__TEXT+0x21a1dc` | `__TEXT+0x181838` |
| pattern hits (whole slice) | 1 (unique) | 1 (unique) |
| first instruction | `pacibsp` / `pacibsppc` (per slice) | same |
| entry (C ABI) | none - `x0` = new ManagedSpace, `x20` = DisplaySpaces | `x0` space, `x1` display_space, `x2` dock_spaces, `x3` sid, `x4` sid (unused) |
| size | ~0x1f0 bytes | ~0x510 bytes |
| window-server effect | `_CGSMoveManagedSpaceToDisplayIndex(cid, field(new_space), displayUuidNSString, index)` | `_SLSTransactionCreate` -> `_SLSTransactionDestroySpace(txn, sid)` -> `_SLSTransactionCommit(txn, 0)` |
| own guards | index must be small non-negative | refuses below 2 (`cmp #0x2; b.lt bail`) |
| wallpaper bookkeeping | `addSpace:forDisplayUUID:` | `removeSpace:`, then `spaceBecameFirst:onDisplay:` |
| Dock model effect | inserts ManagedSpace into `DisplaySpaces.spaces` at user-count+1 | Swift `_NativeDictionary` deletes (uuid-keyed), display array removal, async post |

Both are full bookkeeping routines, not thin wrappers around the CGS calls.
That is the measured reason the payload calls them (route a) instead of
reimplementing the sequence (route b): every step interleaves Swift model
mutation with the server calls, and skipping any of it desyncs the Dock.

## 1. The binary

`/System/Library/CoreServices/Dock.app/Contents/MacOS/Dock` is a fat
binary, big-endian fat header:

| entry | cputype | cpusubtype | file offset | size | align |
|---|---|---|---|---|---|
| 1 | 0x0100000c (arm64) | 0x80000002 (subtype 2, arm64e) | 0x4000 | 0x49e880 | 2^14 |
| 2 | 0x0100000c (arm64) | 0x8000000c (subtype 12, arm64e.x1) | 0x4a4000 | 0x48a700 | 2^14 |

Trap: `lipo -info` prints a single line ("arm64e (cputype ... cpusubtype
(12))") because it collapses duplicate architecture *names*; both slices are
present and distinct. Parse the fat header by hand.

Segment layout of the two slices (identical except `__TEXT`):

| segment | arm64e vmsize | arm64e.x1 vmsize |
|---|---|---|
| `__TEXT` (vmaddr 0x100000000) | **0x398000** | **0x384000** |
| `__DATA_CONST` | 0x30000 | 0x30000 |
| `__DATA` | 0x5c000 | 0x5c000 |
| `__LINKEDIT` | 0x94000 | 0x94000 |

The running Dock is **not** in the dyld shared cache: vmmap shows its
`__TEXT`, `__DATA_CONST` and `__LINKEDIT` regions file-backed from the
on-disk path. Everything in this doc therefore reads the on-disk slices
directly, with no cache extraction step.

### 1.1 Which slice is running (measured, no root)

The running Dock (pid 19841 at measurement time) loaded the **base arm64e
slice (subtype 2)**, not arm64e.x1, despite the M4 Pro - #2832's "selected
on newer chips" did not hold for 27.0/26A428 on this machine.

Method, needing no task port: the two slices differ in `__TEXT` vmsize
(0x398000 vs 0x384000), and the live file-backed `__TEXT` region is
`0x10042c000-0x1007c4000` = exactly 0x398000, with `__DATA_CONST` starting
at exactly base+0x398000. Two exact match points; the x1 layout would put
`__DATA_CONST` five pages earlier.

Access notes: `vmmap <dock pid>` works without sudo (Apple-signed tool,
same-uid target, Debugging Restrictions off on this box). Plain unsigned
tools get `task_for_pid` denied non-root. `pgrep Dock` also matches a
DriverKit dext (`com.apple.DriverKit-IOUserDockChannelSerial`); match the
real Dock by exact command path.

Consequence: the `pacibsppc` (FE A7 C1 DA) divergence does not bite today,
but the patterns wildcard the first instruction anyway so a future boot
that flips slice selection keeps working.

## 2. Methodology: resolving calls without symbols

The slice is stripped except one text symbol
(`__linkguard_warnlisted_image_handler` at 0x1002daeb4). Plain
`llvm-objdump` labels indirect targets with garbage ("_xpc_uuid_get_bytes
+0x1002e77ec" - a degenerate nearest-symbol). The resolution chain below
named every call in both routines. It is reusable for the next Dock
disassembly.

1. Extract the slices: `python3` over the fat header offsets
   (`data[0x4000:0x4000+0x49e880]`, `data[0x4a4000:0x4a4000+0x48a700]`).
2. Disassemble with `xcrun llvm-objdump --disassemble
   --start-address=... --stop-address=...`.
3. `__auth_stubs` (section `__TEXT,__auth_stubs`, addr 0x1002dfe4c, size
   0x83b0): 2107 stubs of 16 bytes each, of the form
   `adrp x17, page; add x17, x17, #imm; ldr x16, [x17]; braa x16, x17`.
   The GOT slot is `adrp_page_of_stub_pc + add_imm`. **The adrp page base
   is the stub's own PC**, not the section start - computing it from the
   section start silently mismaps every stub more than one page into the
   section and produces confident, wrong names (found the hard way).
4. Join the GOT slot to a symbol with `xcrun dyld_info -fixups slice`:
   bind lines like `__DATA_CONST __const 0x1003982E0 auth-bind
   libSystem/__NSConcreteGlobalBlock (div=... ad=1 key=...)`. With the
   correct slot math this names 2107/2107 stubs. One slot worth knowing
   cold: 0x1003bfa08 = `_objc_msgSend`.
5. `__objc_stubs` (section at 0x1002e8200): 16-byte stubs that bake the
   selector in - `adrp x1, selrefs; ldr x1, [x1, #off]; adrp x17,
   0x1003bf000; add x17, x17, #0xa08; ldr x16, [x17]; braa x16, x17` -
   i.e. `objc_msgSend` with a fixed selector. These are how the routines
   talk ObjC without visible selector loads.
6. Resolve a baked selector: read the selref slot (vmaddr -> file offset
   via the `LC_SEGMENT_64` map), mask the stored pointer with
   `0x0000ffffffffffff` and OR in the vmaddr base (selref pointers are
   ptrauth-signed in-file), then read the C string it lands on in
   `__objc_methname` (section at 0x10035c670, size 0x1c8df).
7. Branch veneers: 4-byte `b` islands (e.g. the cluster at 0x100272680 /
   0x100272690, four entries each) that forward to the real functions.
   A `bl` into a veneer is just an internal call; follow the `b` once or
   twice to land in code.
8. The arm64e prologue/epilogue helper pair, present at the ends of
   functions in this image (add_space has it, remove_space does not):
   entry `mov x1, x30; bl 0x10012d630; mov x30, x1`, exit
   `mov x1, x30; bl 0x1000d0814; mov x30, x1; autibsp; eor x16, x30, x30,
   lsl #1; tbz x16, #0x3e, ok; brk #0xc471`. This is the return-address
   re-sign through a BTI-safe veneer plus the standard PAC-failure trap
   (`brk #0xc471`). It is not a semantic step; ignore it when reading.

One more convention that matters for the payload: **x20 carries a context
out of the C ABI**. add_space receives its DisplaySpaces argument in x20
(that is why yabai's asm shim exists), and the internal helpers
0x100226a10 and 0x10022892c also read a context pointer from x20 without
it being a declared argument, relying on the caller's x20. Never call
these helpers directly; always enter through add_space/remove_space,
which set x20 per the convention.

## 3. add_space, mapped

`__TEXT+0x228cbc` (vm 0x100228cbc), ~0x1f0 bytes. Caller passes
`x0` = a freshly allocated `[[ManagedSpace alloc] init]`, `x20` = the
target `DockCore.DisplaySpaces`.

Annotated walkthrough (calls resolved per section 2):

```
pacibsp;  mov x1,x30; bl 0x10012d630; mov x30,x1        ; PAC prologue veneer
stp x29,x30,[sp,#0x50]; add x29,sp,#0x50
mov x19, x20                    ; x19 = DisplaySpaces
mov x21, x0                     ; x21 = new ManagedSpace
ldr x22, [x20,#0x38]!           ; x22 = DisplaySpaces->spaces   (ivar +56)
ldrb w8, [x20,#0x10]            ; flag at DisplaySpaces+0x48
cmp w8, #1; b.ne slow_path
```

Counting. Both paths call the count helper through the veneer at
0x100272690 with the spaces array. The slow path (flag != 1) runs the
Swift `_ArrayBuffer` fast enumeration (the tagged-pointer check
`and x26, x22, #0xc000000000000001`, buffer base, count at
`[buffer+0x10]`) and, per element, calls the `__objc_stubs` stub at
0x1002fae20 - `objc_msgSend(element, @selector(userSpace))`. That is the
exact meaning of #2832's "the function counts user spaces": the predicate
is `-[ManagedSpace userSpace]`. The fast path takes a precomputed count.

Both paths converge on the new index: `x22 = user_space_count + 1`.

Insert:

```
ldr x1, [x19,#0x38]             ; the spaces array again
mov x0, x22                     ; the new index
bl 0x100272680                   ; veneer -> insert helper (index, array)
mov x0, x21; bl _objc_retain
mov x0, x22; mov x1, x22; mov x2, x21
bl 0x100265f7c                   ; thunk builder: materializes pacia-signed
                                ; internal fn ptrs (discriminators 0x404b,
                                ; 0xfe9f, 0x6f20) then inserts new_space
bl 0x1000df1bc                  ; internal bookkeeping (unresolved)
ldr x24, [x21, x8]              ; a field of new_space at a runtime-computed
                                ; offset -> becomes CGS arg x1
```

The insert is model-only at this point: the ManagedSpace joins the Dock's
`DisplaySpaces.spaces` array at the computed index.

Window-server registration:

```
ldp x20, x23, [x19,#0x20]        ; DisplaySpaces->displayUUID - a Swift
                                ; String (raw bits + count), ivar +32
bl 0x1002c2aa8                  ; lazily-initialized connection getter
                                ; (swift_once singleton) -> cid
mov x0, x20; mov x1, x23
bl _$sSS10FoundationE19_bridgeToObjectiveC...   ; -> displayUuid NSString
tbnz x22,#63,err; lsr x8,x22,#32; cbnz x8,err   ; index must be small,
                                                ; non-negative
mov x0, x26                     ; cid
mov x1, x24                     ; field read off new_space
mov x2, x25                     ; display uuid NSString
mov x3, x22                     ; the new index
bl _CGSMoveManagedSpaceToDisplayIndex
```

This is the call the space-creation doc (section 6) dismissed as "moves an
existing managed space between displays... not a creator". Inside
add_space, on the Dock's universal-owner connection, with a fresh
ManagedSpace and the new index, it is the creator: it registers the new
space with the window server as *managed* on that display. Called as a
bare client symbol from outside it is not a creator - both readings are
correct in their own context.

Wallpaper bookkeeping, then trailing model work:

```
adrp x8, 0x100409000; add x8,#0xc50; ldr x22,[x8]   ; the
        ; DockCore.WallpaperAgentDesktopPictureManager singleton (global)
ldrb w19, [x19,#0x60]           ; per-display flag
swift_unknownObjectRetain(global)
(if flag) bridge displayUUID again -> x19 else x19 = 0
mov x0, x22                     ; wallpaper manager
mov x2, x21                     ; the new space
mov x3, x19                     ; display uuid NSString or nil
bl 0x1002ea9c0                  ; __objc_stubs: objc_msgSend(global,
                                ;   @selector(addSpace:forDisplayUUID:))
... releases ...
bl 0x100234458; bl 0x10023458c; bl 0x1001eb2b8; bl 0x100234664
                                ; shared Swift model bookkeeping (the same
                                ; cluster remove_space's tail uses)
```

So the phase-2 class-dump finding - "only WallpaperAgentDesktopPicture
Manager addSpace:/removeSpace: showed up" - was true, complete, and still
misleading: those selectors exist because the C routine calls them for
wallpaper bookkeeping after doing the real work itself.

What add_space never does: talk to WindowManager, XPC anyone, or check an
entitlement. The CGS call and the transaction machinery carry the change;
how WM learns is server-side (inferred, not proven - see section 7).

## 4. remove_space, mapped

`__TEXT+0x18b9a0` (vm 0x10018b9a0), ~0x510 bytes. Entry, per yabai's
typedef, verified by register use: `x0` = the ManagedSpace to remove,
`x1` = its DisplaySpaces, `x2` = the dock's `Spaces` singleton,
`x3` = the space id, `x4` = the space id again (unused in the body).

```
mov x19,x3 (sid); mov x21,x2 (Spaces); mov x20,x1 (DisplaySpaces); mov x22,x0 (space)
bl 0x100226a10                   ; helper(x0=space, x20=DisplaySpaces per the
                                 ; x20 convention): validates/derives against
                                 ; DisplaySpaces->spaces, returns a collection
bl 0x100272690                   ; veneer -> count(collection)
cmp x0, #0x2; b.lt bail          ; fewer than 2 -> REFUSE (the Dock's own
                                 ; last-space guard; bail pops and returns)
```

Key extraction - the space's uuid becomes the dictionary key:

```
mov x0, x22; bl 0x1002faea0      ; __objc_stubs: objc_msgSend(space,
                                 ;   @selector(uuid))  ->  -[ManagedSpace uuid]
objc_retainAutoreleasedReturnValue; String._unconditionallyBridgeFromObjectiveC
        ; -> Swift String on the stack (sp+0x30 / x20)
```

Early wallpaper notify:

```
adrp x8, 0x100409000; add x8,#0xc50; ldr x0,[x8]   ; wallpaper manager
mov x2, x22                      ; the space
bl 0x1002f4a60                   ; __objc_stubs: objc_msgSend(mgr,
                                 ;   @selector(removeSpace:))
```

Dock-model teardown, part 1 - the uuid-keyed Swift dictionary on `Spaces`:

```
adrp x8, 0x100401000; ldr x24, [x8,#0xe30]   ; a resilient-offset token
ldr x27, [x21, x24]                          ; the dictionary field off Spaces
        ; Swift _HashTable bucket walk (rbit/clz bit math on the hash),
_$ss27_stringCompareWithSmolCheck...         ; compare candidate key strings
        ; found bucket -> (x26, x23) = key/value pair
```

Part 2 - a loop over a second collection (count at `[x0+0x10]`, 16-byte
entries at `+0x20`): per entry it reads the dictionary field through the
same offset token, `bl 0x10026e560` (lookup), checks
`swift_isUniquelyReferenced_nonNull_native`, calls
`_NativeDictionary.ensureUnique(isUnique:capacity:)`, releases the old
value, and finally `_NativeDictionary._delete(at:)` - deleting the space's
entries from the per-display dictionaries.

Part 3 - the transactional window-server destroy:

```
bl _SLSTransactionCreate                     ; -> x20 = transaction
bl 0x1000c1b18 -> x22                        ; internal adapter (unresolved)
bl 0x10002e304(global 0x100405000+0xe30 type, ...)   ; struct init
bl _swift_allocObject(0x28, 7)               ; 40-byte context object
        ; copies a 16-byte constant from 0x10030a000+0xd60 into +0x10,
        ; stores the sid into +0x20
bl 0x100241d14(x22, 1, 0, 0x3000000000000, ctx)      ; attach (unresolved)
bl 0x1002c4cf8(x22, x19)                     ; internal (unresolved)
mov x0, x20; mov x1, x28 (sid)
bl _SLSTransactionDestroySpace               ; the destroy joins the txn
mov x0, x20; mov w1, #0
bl _SLSTransactionCommit(transaction, 0)     ; committed, synchronous=0
objc_release(transaction)
```

Part 4 - array and post-processing cleanup:

```
bl 0x10022892c(x0=dict result, x20=DisplaySpaces)   ; removes the space from
        ; DisplaySpaces->spaces (+0x38; internal calls 0x100226938,
        ; 0x1001ad1a0, 0x1001b796c + the shared 0x100234458 cluster)
bl 0x1000a5c60                                 ; cleanup (veneer)
bl 0x100188cf8(x20=Spaces)                     ; starts with Dispatch
        ; WorkItemFlagsVa (dispatch metadata) - posts async work on the
        ; Dock's model, presumably listener notification
cbz w24, skip_tail                              ; conditional tail
```

Part 5 - the conditional `spaceBecameFirst` notify (the selector #2832
named, confirmed by selref resolution):

```
mov x0, x26; bl 0x1002faea0                    ; -[ManagedSpace uuid] again
        ; bridges to NSString (x19), and bridges the display uuid (x21)
ldr(global wallpaper manager) -> x20
mov x0, x20; mov x2, x19; mov x3, x21
bl 0x1002f96a0                    ; __objc_stubs: objc_msgSend(mgr,
                                  ;   @selector(spaceBecameFirst:onDisplay:),
                                  ;   uuidNSString, displayUuidNSString)
epilogue: pops; autibsp; eor x16,x30,x30,lsl#1; tbz x16,#0x3e; brk #0xc471
```

The `bail` path (fewer than 2) is a clean early return: pops, autibsp, the
PAC trap check, and a `swift_bridgeObjectRelease` tailcall. No server call
happens - refusing below 2 spaces is the routine's own guard, not the
client's.

## 5. Internal helper map

| address | what it is | confidence |
|---|---|---|
| 0x100272680 | branch veneer (4 entries) -> insert helper via 0x10002b340 -> 0x10026f710 | structural |
| 0x100272690 | branch veneer -> count helper (0x10002c4ac -> 0x10002c324 chain) | structural; count semantics from use |
| 0x100226a10 | validation/derive helper, reads `DisplaySpaces->spaces` via the x20 convention, returns a collection | from use |
| 0x10022892c | removes from `DisplaySpaces->spaces` (+0x38) via the x20 convention | from use |
| 0x1002c2aa8 | lazily-initialized connection getter (swift_once), fills the cid role of the CGS call | from use |
| 0x100265f7c | thunk/closure builder; materializes multiple pacia-signed internal fn pointers (discriminators 0x404b, 0xfe9f, 0x6f20) then performs the insert | structural |
| 0x1000df1bc / 0x1000c1b18 / 0x100241d14 / 0x1002c4cf8 / 0x1000a5c60 / 0x10026e560 / 0x100234458 / 0x10023458c / 0x100234664 / 0x1001eb2b8 | internal Swift bookkeeping; 0x100234xxx is the shared cluster both routines use | unresolved |
| 0x1002e5f3c / 0x1002e5f5c / 0x1002e5f1c | auth stubs: `_SLSTransactionCreate` / `_SLSTransactionDestroySpace` / `_SLSTransactionCommit` | named via GOT bind |
| 0x1002e4bdc | auth stub: `_CGSMoveManagedSpaceToDisplayIndex` | named via GOT bind |
| 0x1002fae20 | `__objc_stubs`: msgSend `userSpace` | selref-resolved |
| 0x1002faea0 | `__objc_stubs`: msgSend `uuid` | selref-resolved |
| 0x1002ea9c0 | `__objc_stubs`: msgSend `addSpace:forDisplayUUID:` | selref-resolved |
| 0x1002f4a60 | `__objc_stubs`: msgSend `removeSpace:` | selref-resolved |
| 0x1002f96a0 | `__objc_stubs`: msgSend `spaceBecameFirst:onDisplay:` | selref-resolved |
| global 0x100409000+0xc50 | the `DockCore.WallpaperAgentDesktopPictureManager` singleton | from selectors + class dump |
| 0x10012d630 / 0x1000d0814 | prologue/epilogue return-address re-sign veneers | structural |

## 6. How the payload drives them (spacetoosa.m v6)

Every finding above maps to a payload decision:

- **Location**: `patternFind()` scans the *whole* `__TEXT` of the live
  Dock image (`dockImage()` header + slide, `LC_SEGMENT_64` walk) for the
  #2832 patterns with the first instruction wildcarded. Both patterns are
  measured unique across both whole slices of this build
  (add: 0x228cbc arm64e / 0x21a1dc x1; remove: 0x18b9a0 / 0x181838), so
  there is no per-version offset window to maintain - yabai's 27.x
  windows (0x160000/0x120000 + 0x1286a0 span) also contain our hits, but
  the whole-segment scan drops that maintenance entirely.
- **Loud degradation**: resolution lands in the HELLO mask (bits 0x8 /
  0x10) next to the four SLS symbol bits, so an OS bump that drifts the
  patterns reports as "payload did not resolve the Dock add/remove
  routine" and the client falls back to Mission Control with a stderr
  reason.
- **Calling**: `ptrauth_sign_unauthenticated(addr, ptrauth_key_asia, 0)`
  at constructor time, then the yabai call shapes verbatim - add_space
  through the `mov x0 / mov x20` asm shim (the x20 convention of section
  2 is why the shim must exist), remove_space as a plain 5-arg C call
  `(space, display_space, dock_spaces, sid, sid)`. An empty inline asm
  with both objects as inputs after the add call keeps ARC from
  releasing them between the shim and the indirect call.
- **Queue**: both run on the Dock main queue (`dispatch_async` + 2s
  semaphore, the codebase's focusSpace shape), matching yabai's
  `dispatch_sync(main)`.
- **Object graph**: reached through ivars by name, not offsets, all
  cross-checked against the live `sa-dump` class report:
  `Spaces._displaySpaces` +24; `DockCore.DisplaySpaces.spaces` +56
  (the `+0x38` of #2832 and the disassembly), `_currentSpace` +88,
  `displayUUID` +32 (a Swift String - deliberately *not* read raw by the
  payload); `ManagedSpace._spid` +8, `_uuid` +16. The display for a
  DisplaySpaces is identified the yabai way (its `_currentSpace` ->
  `spid` -> `SLSCopyManagedDisplayForSpace`) because
  `spacesForDisplay:` no longer exists on 26A428 - the payload's
  `spaceForSpid` walks `DisplaySpaces.spaces` and compares `spid`
  instead.
- **Create**: `[[ManagedSpace alloc] init]` + `add_space(new_space,
  display_space)`. The reference sid the client sends names only the
  *display* (any space on it works; the client sends the current space
  of the target display).
- **Destroy**: the NULL-id guard first - `SLSCopyManagedDisplayForSpace`
  must return non-NULL before anything touches
  `SLSManagedDisplayGetCurrentSpace`, because an unknown sid NULLs the
  display and crashes the Dock inside `SLSManagedDisplayGetCurrentSpace`
  (`CFEqual() called with NULL first argument`, #2832's crash, his fix
  commit mirrored here). Then `remove_space(...)`, then the
  `_currentSpace` resync when the active space died (yabai's
  post-destroy fix): `spaceForSpid(displaySpaces,
  SLSManagedDisplayGetCurrentSpace(...))` written into
  `DisplaySpaces._currentSpace`.
- **Client**: `create`/`rm` are payload-first, verify the effect through
  `CGSCopyManagedDisplaySpaces` diffs, fall back to the AX/Mission
  Control path on any payload error; `SPACETOOL_MC=1` forces the
  fallback.

## 7. Live verification (2026-10-01, Dock payload v6, HELLO 0x1f)

- `spacetool create "sa-test"` -> "created Desktop 8 (space 393)" in
  0.386s wall clock, no Mission Control flash, no Accessibility; the
  space appears in `CGSCopyManagedDisplaySpaces` (`spacetool list`).
- `spacetool rm "sa-test"` -> 0.316s.
- Hard path: create -> `switch` onto it -> `rm` while it is the ACTIVE
  space -> removed, `_currentSpace` resynced (current falls back to
  comms), Dock model and CGS agree.
- Crash guard, driven raw over the socket: `OP_SPACE_DESTROY` with sid
  0xdeadbeef -> err -2 (`SPACEC_BAD_SID`), Dock alive and still serving
  HELLO v6. Same for `OP_SPACE_CREATE` with a bogus reference sid.
- Both errors and success round-trip through the same reply shape the
  other opcodes use.

## 8. Open items (recorded, not chased)

- The exact meaning of `_CGSMoveManagedSpaceToDisplayIndex`'s second
  argument (a field read off the new ManagedSpace at a runtime-computed
  offset) is unresolved. The payload never calls the CGS function
  itself, so nothing depends on it; if route (b) is ever revisited, this
  is the first thing to pin down (find the ivar offset from the class
  dump, disassemble around the load).
- The flag at `DisplaySpaces+0x48` that picks add_space's counting path,
  and the flag at `+0x60` that gates the `addSpace:forDisplayUUID:`
  string argument, are unnamed (not in the ivar list; likely Swift
  stored properties without ObjC ivar exposure).
- How WindowManager learns about the change is not proven here. The
  wallpaper-manager messages are bookkeeping, not the WM forward; the
  observable facts are #2832's live note ("the Dock forwards the changes
  to WindowManager") and ours (Mission Control's row and
  `CGSCopyManagedDisplaySpaces` reflect create/destroy immediately).
  The forward plausibly rides the CGS/transaction machinery server-side.
- The unresolved internals in section 5 (0x1000df1bc and the 0x100234xxx
  cluster in particular) were characterized by role, not semantics.

## 9. Sources

- asmvik/yabai#2832 "macOS 27.2 beta (26B5091g): scripting addition
  patterns, Dock API changes and patch" - the patterns, the entry
  signatures, the NULL-crash, and the live 27.2 result (MIT).
- `LCS-Dev-Ergos/yabai` branch `fix/macos-27-scripting-addition`,
  `src/osax/arm64_payload.m` (pattern/offset tables, the x20 asm macros)
  and `src/osax/payload.m` (`do_space_create`, `do_space_destroy`, the
  ivar-based helpers) (MIT).
- Local, all 2026-10-01 on 26A428: fat-header parse and slice extraction
  (python), `vmmap` of the live Dock (slice pinning), `xcrun
  llvm-objdump`, `xcrun dyld_info -fixups`, `xcrun llvm-nm`, `strings`,
  the `sa-dump` live class report (`/tmp/spacetool-sa-classes_carlos.txt`)
  and the live payload tests in section 7.
- `docs/space-creation-without-mission-control.md` section 6 - the list
  `CGSMoveManagedSpaceToDisplayIndex` used to sit on with the wrong
  verdict, and the section 5 entitlement wall (still true, still beside
  the point).
