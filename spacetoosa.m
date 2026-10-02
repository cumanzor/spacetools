// spacetoosa - Dock-hosted payload for per-window sticky spaces.
// Only the Dock's window-server connection can set window tag bit 11
// (onAllWorkspaces); every other writer is silently gated
// (docs/window-on-all-spaces.md). This dylib is dlopen'd into the Dock by
// loadsa (into the Dock and into WindowManager); its constructor opens
// /tmp/spacetool-sa_$USER.socket in the Dock, /tmp/spacetool-sa-wm_$USER.socket
// in WindowManager (0600), and
// serves its opcodes. Socket shape ported from yabai's osax payload
// (MIT, src/osax/payload.m).
#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <CoreGraphics/CoreGraphics.h>
#import <dlfcn.h>
#import <objc/runtime.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <malloc/malloc.h>
#import <ptrauth.h>
#import <errno.h>
#import <pthread.h>
#import <signal.h>
#import <sys/socket.h>
#import <sys/stat.h>
#import <sys/un.h>
#import <pwd.h>
#import <unistd.h>

typedef int (*ConnFn)(void);
typedef CGError (*TagsFn)(int, uint32_t, uint64_t *, size_t);
typedef CFTypeRef (*QueryWindowsFn)(int, CFArrayRef, int);
typedef CFTypeRef (*QueryResultCopyFn)(CFTypeRef);
typedef BOOL (*IterAdvanceFn)(CFTypeRef);
typedef uint32_t (*IterWidFn)(CFTypeRef);
typedef uint64_t (*IterTagsFn)(CFTypeRef);
typedef CFStringRef (*CopyDisplayForSpaceFn)(int, uint64_t);
typedef uint64_t (*CurrentSpaceOfDisplayFn)(int, CFStringRef);
typedef CGError (*SpaceListFn)(int, CFArrayRef);
typedef CGError (*SetCurrentSpaceFn)(int, CFStringRef, uint64_t);

enum { OP_HELLO = 1, OP_STICKY_SET = 2, OP_STICKY_CLEAR = 3, OP_STICKY_QUERY = 4,
       OP_DUMP_CLASSES = 5, OP_FIND_SPACES = 6, OP_SPACE_FOCUS = 7,
       OP_SPACE_CREATE = 8, OP_SPACE_DESTROY = 9, OP_SPACE_FOCUS_INSTANT = 10 };
#define SA_PROTO_VERSION 7
#define STICKY_BIT 11

enum { SPACEC_OK = 0, SPACEC_NO_SPACES = -1, SPACEC_BAD_SID = -2, SPACEC_NO_DISPLAY = -3,
       SPACEC_NO_CLASS = -4, SPACEC_TIMEOUT = -5, SPACEC_UNRESOLVED = -6, SPACEC_NOT_FOUND = -7 };

static int cid;

// same dylib in both hosts; the host picks the socket, report names and which
// images the class dump keeps
static BOOL inWindowManager;
static const char *hostSuffix(void) { return inWindowManager ? "-wm" : ""; }
static const char *userName(void) {
    const char *u = getenv("USER");
    if (u) return u;
    struct passwd *pw = getpwuid(getuid());
    return pw ? pw->pw_name : "unknown";
}
static BOOL hostImage(const char *img) {
    if (!img) return NO;
    return inWindowManager ? strstr(img, "WindowManager") != NULL : strstr(img, "/Dock.app/") != NULL;
}
static TagsFn setTagsF, clearTagsF;
static QueryWindowsFn queryF;
static QueryResultCopyFn iterCopyF;
static IterAdvanceFn iterAdvF;
static IterWidFn iterWidF;
static IterTagsFn iterTagsF;
static CopyDisplayForSpaceFn displayForSpaceF;
static CurrentSpaceOfDisplayFn currentSpaceOfDisplayF;
static SpaceListFn showSpacesF, hideSpacesF;
static SetCurrentSpaceFn setCurrentSpaceF;
static uintptr_t addSpaceFp, removeSpaceFp;

// the Dock's own add_space/remove_space C routines, located by the 27.x byte
// patterns from asmvik/yabai#2832 (LCS-Dev-Ergos' tables, MIT). The first
// instruction is wildcarded so both arm64e slices match (pacibsp vs
// pacibsppc); both patterns measured unique across the whole 26A428 Dock
// __TEXT, so an OS bump that drifts them zeroes the HELLO bits, loudly
static const char *addSpacePattern =
    "?? ?? ?? ?? E1 03 1E AA ?? ?? ?? 97 FE 03 01 AA FD 7B 05 A9 FD 43 01 91 "
    "F3 03 14 AA F5 03 00 AA 96 8E 43 F8 ";
static const char *removeSpacePattern =
    "?? ?? ?? ?? FF ?? ?? D1 FC ?? ?? A9 FA ?? ?? A9 F8 ?? ?? A9 F6 ?? ?? A9 "
    "F4 ?? ?? A9 FD ?? ?? A9 FD ?? ?? 91 ?? 03 03 AA F5 03 02 AA F4 03 01 AA ";

static uint64_t tagsFor(uint32_t wid) {
    uint64_t tags = 0;
    if (!queryF) return 0;
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

static void dumpMethods(NSMutableString *o, Class c, char kind) {
    unsigned n = 0;
    Method *ms = class_copyMethodList(c, &n);
    for (unsigned i = 0; i < n; i++)
        [o appendFormat:@"  %c %s  %s\n", kind, sel_getName(method_getName(ms[i])),
            method_getTypeEncoding(ms[i]) ?: ""];
    free(ms);
}

// read-only: names and layouts of every class the Dock image defines, so
// dock_spaces can be found by ivar/selector name instead of a hex pattern
static int64_t dumpClasses(const char *path) {
    unsigned n = 0;
    Class *all = objc_copyClassList(&n);
    NSMutableString *o = [NSMutableString string];
    unsigned kept = 0;
    for (unsigned i = 0; i < n; i++) {
        Class c = all[i];
        const char *img = class_getImageName(c);
        if (!hostImage(img)) continue;
        kept++;
        Class sup = class_getSuperclass(c);
        [o appendFormat:@"class %s : %s  size=%zu\n", class_getName(c),
            sup ? class_getName(sup) : "-", class_getInstanceSize(c)];
        unsigned ni = 0;
        Ivar *iv = class_copyIvarList(c, &ni);
        for (unsigned j = 0; j < ni; j++)
            [o appendFormat:@"  ivar %s  %s  +%td\n", ivar_getName(iv[j]) ?: "?",
                ivar_getTypeEncoding(iv[j]) ?: "", ivar_getOffset(iv[j])];
        free(iv);
        dumpMethods(o, object_getClass(c), '+');
        dumpMethods(o, c, '-');
    }
    free(all);
    [o insertString:[NSString stringWithFormat:@"# %u %s classes of %u total\n", kept,
        inWindowManager ? "WindowManager" : "Dock", n] atIndex:0];
    NSData *d = [o dataUsingEncoding:NSUTF8StringEncoding];
    if (![d writeToFile:@(path) atomically:YES]) return -1;
    chmod(path, 0600);
    return (int64_t)d.length;
}

// isa bits that hold the class address on arm64/arm64e macOS; the signature
// and refcount bits sit above the 47-bit VA, so masking never needs an auth
#define ISA_CLASS_BITS 0x00007ffffffffff8ULL

static BOOL isaIs(uintptr_t obj, Class c) {
    uintptr_t isa = *(uintptr_t *)obj;
    return (isa & ISA_CLASS_BITS) == ((uintptr_t)ptrauth_strip((__bridge void *)c,
        ptrauth_key_process_independent_data) & ISA_CLASS_BITS);
}

// a heap block big enough for c, checked through the allocator before any read
static BOOL heapObjectOf(uintptr_t v, Class c) {
    if (!v || (v & 0xf) || v > ISA_CLASS_BITS) return NO;
    if (!malloc_zone_from_ptr((void *)v)) return NO;
    if (malloc_size((void *)v) < class_getInstanceSize(c)) return NO;
    return isaIs(v, c);
}

static const struct mach_header_64 *dockImage(intptr_t *slide) {
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        const char *n = _dyld_get_image_name(i);
        if (n && strstr(n, "/Dock.app/Contents/MacOS/Dock")) {
            *slide = _dyld_get_image_vmaddr_slide(i);
            return (const struct mach_header_64 *)_dyld_get_image_header(i);
        }
    }
    return NULL;
}

#define MAX_HEAP_HITS 64
static uintptr_t heapHits[MAX_HEAP_HITS];
static unsigned heapHitCount, heapBlocks;
static Class heapTarget;

// runs with every zone force-locked: no allocation, no objc messaging
static void heapRecorder(task_t task, void *ctx, unsigned type, vm_range_t *r, unsigned n) {
    (void)task; (void)ctx; (void)type;
    size_t need = class_getInstanceSize(heapTarget);
    for (unsigned i = 0; i < n; i++) {
        heapBlocks++;
        if (r[i].size < need || r[i].size > 4096) continue;
        if (isaIs(r[i].address, heapTarget) && heapHitCount < MAX_HEAP_HITS)
            heapHits[heapHitCount++] = r[i].address;
    }
}

static void heapScan(Class c) {
    heapTarget = c; heapHitCount = 0; heapBlocks = 0;
    vm_address_t *zones = NULL;
    unsigned nz = 0;
    if (malloc_get_all_zones(mach_task_self(), NULL, &zones, &nz) != KERN_SUCCESS) return;
    malloc_zone_t *zs[32];
    if (nz > 32) nz = 32;
    for (unsigned i = 0; i < nz; i++) zs[i] = (malloc_zone_t *)zones[i];
    for (unsigned i = 0; i < nz; i++)
        if (zs[i]->introspect && zs[i]->introspect->force_lock) zs[i]->introspect->force_lock(zs[i]);
    for (unsigned i = 0; i < nz; i++)
        if (zs[i]->introspect && zs[i]->introspect->enumerator)
            zs[i]->introspect->enumerator(mach_task_self(), NULL, MALLOC_PTR_IN_USE_RANGE_TYPE,
                (vm_address_t)zs[i], NULL, heapRecorder);
    for (unsigned i = nz; i > 0; i--)
        if (zs[i-1]->introspect && zs[i-1]->introspect->force_unlock) zs[i-1]->introspect->force_unlock(zs[i-1]);
}

static NSString *describeOnMain(id obj, SEL sel) {
    if (![obj respondsToSelector:sel]) return @"(no such selector)";
    __block NSString *out = nil;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_main_queue(), ^{
        id r = ((id (*)(id, SEL))objc_msgSend)(obj, sel);
        out = [[r description] copy] ?: @"(nil)";
        dispatch_semaphore_signal(done);
    });
    if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC)))
        return @"(main queue busy, timed out)";
    return out.length > 20000 ? [[out substringToIndex:20000] stringByAppendingString:@"\n(truncated)"] : out;
}

static void describeSpaces(NSMutableString *o, uintptr_t sp) {
    id spaces = (__bridge id)(void *)sp;
    [o appendFormat:@"\n== Spaces %p\n", (void *)sp];
    Ivar ds = class_getInstanceVariable(object_getClass(spaces), "_displaySpaces");
    if (ds) {
        uintptr_t v = *(uintptr_t *)(sp + ivar_getOffset(ds));
        BOOL heap = v && !(v & 0xf) && malloc_zone_from_ptr((void *)v);
        [o appendFormat:@"_displaySpaces (+%td) = %p%s%s\n", ivar_getOffset(ds), (void *)v,
            heap ? "  class " : "", heap ? class_getName(object_getClass((__bridge id)(void *)v)) : ""];
    }
    for (NSString *selName in @[@"currentSpaces", @"displays", @"allUserSpaces", @"detailedDescription"])
        [o appendFormat:@"-- %@:\n%@\n", selName, describeOnMain(spaces, NSSelectorFromString(selName))];
}

static int64_t findSpaces(const char *path, BOOL heap) {
    NSMutableString *o = [NSMutableString string];
    id probe = [NSObject new];
    [o appendFormat:@"isa mask self-test: %s\n",
        isaIs((uintptr_t)(__bridge void *)probe, [NSObject class]) ? "ok" : "FAILED (results below are not trustworthy)"];
    Class spacesC = objc_getClass("Spaces"), agentC = objc_getClass("DockCore.DockAgent");
    Class targets[] = { spacesC, agentC, objc_getClass("DockVisibility"), objc_getClass("DockBar") };
    NSMutableOrderedSet *spacesFound = [NSMutableOrderedSet orderedSet];

    intptr_t slide = 0;
    const struct mach_header_64 *mh = dockImage(&slide);
    if (!mh) [o appendString:@"Dock image not found\n"];
    const struct load_command *lc = mh ? (const void *)(mh + 1) : NULL;
    for (uint32_t i = 0; mh && i < mh->ncmds; i++, lc = (const void *)((const uint8_t *)lc + lc->cmdsize)) {
        if (lc->cmd != LC_SEGMENT_64) continue;
        const struct segment_command_64 *seg = (const void *)lc;
        if (strncmp(seg->segname, "__DATA", 6) && strncmp(seg->segname, "__AUTH", 6)) continue;
        [o appendFormat:@"segment %.16s vm 0x%llx size 0x%llx\n", seg->segname, seg->vmaddr, seg->vmsize];
        const uintptr_t *p = (const uintptr_t *)(seg->vmaddr + slide);
        for (uint64_t k = 0; k < seg->vmsize / sizeof(uintptr_t); k++) {
            uintptr_t v = (uintptr_t)ptrauth_strip((void *)p[k], ptrauth_key_process_independent_data);
            for (unsigned t = 0; t < 4; t++) {
                if (!targets[t] || !heapObjectOf(v, targets[t])) continue;
                [o appendFormat:@"  global %.16s+0x%llx (unslid 0x%llx) -> %p %s\n", seg->segname,
                    k * 8, seg->vmaddr + k * 8, (void *)v, class_getName(targets[t])];
                if (targets[t] == spacesC) [spacesFound addObject:@(v)];
                if (targets[t] == agentC) {
                    Ivar iv = class_getInstanceVariable(agentC, "spaces");
                    uintptr_t sp = iv ? *(uintptr_t *)(v + ivar_getOffset(iv)) : 0;
                    BOOL ok = heapObjectOf(sp, spacesC);
                    [o appendFormat:@"    DockAgent.spaces (+%td) = %p %s\n", iv ? ivar_getOffset(iv) : 0,
                        (void *)sp, ok ? "Spaces" : "(not a Spaces)"];
                    if (ok) [spacesFound addObject:@(sp)];
                }
                if (t >= 2) {
                    const char *ivn = t == 2 ? "_spaces" : "spaces";
                    Ivar iv = class_getInstanceVariable(targets[t], ivn);
                    uintptr_t sp = iv ? *(uintptr_t *)(v + ivar_getOffset(iv)) : 0;
                    BOOL ok = heapObjectOf(sp, spacesC);
                    [o appendFormat:@"    .%s = %p %s\n", ivn, (void *)sp, ok ? "Spaces" : "(not a Spaces)"];
                    if (ok) [spacesFound addObject:@(sp)];
                }
            }
        }
    }
    if (heap && spacesC) {
        heapScan(spacesC);
        [o appendFormat:@"heap walk: %u blocks, %u Spaces instance(s)\n", heapBlocks, heapHitCount];
        for (unsigned i = 0; i < heapHitCount; i++) {
            [o appendFormat:@"  heap %p\n", (void *)heapHits[i]];
            [spacesFound addObject:@(heapHits[i])];
        }
    }
    [o appendFormat:@"distinct Spaces instances: %lu\n", (unsigned long)spacesFound.count];
    for (NSNumber *sp in spacesFound) describeSpaces(o, sp.unsignedLongValue);
    NSData *d = [o dataUsingEncoding:NSUTF8StringEncoding];
    if (![d writeToFile:@(path) atomically:YES]) return -1;
    chmod(path, 0600);
    return (int64_t)d.length;
}

// the Dock's one Spaces instance: a direct global, else DockAgent.spaces
static uintptr_t cachedSpaces;
static uintptr_t locateSpaces(void) {
    Class spacesC = objc_getClass("Spaces"), agentC = objc_getClass("DockCore.DockAgent");
    if (!spacesC) return 0;
    if (cachedSpaces && heapObjectOf(cachedSpaces, spacesC)) return cachedSpaces;
    cachedSpaces = 0;
    intptr_t slide = 0;
    const struct mach_header_64 *mh = dockImage(&slide);
    if (!mh) return 0;
    Ivar agentSpaces = agentC ? class_getInstanceVariable(agentC, "spaces") : NULL;
    const struct load_command *lc = (const void *)(mh + 1);
    for (uint32_t i = 0; i < mh->ncmds; i++, lc = (const void *)((const uint8_t *)lc + lc->cmdsize)) {
        if (lc->cmd != LC_SEGMENT_64) continue;
        const struct segment_command_64 *seg = (const void *)lc;
        if (strcmp(seg->segname, "__DATA")) continue;
        const uintptr_t *p = (const uintptr_t *)(seg->vmaddr + slide);
        for (uint64_t k = 0; k < seg->vmsize / sizeof(uintptr_t); k++) {
            uintptr_t v = (uintptr_t)ptrauth_strip((void *)p[k], ptrauth_key_process_independent_data);
            if (heapObjectOf(v, spacesC)) return cachedSpaces = v;
            if (agentSpaces && heapObjectOf(v, agentC)) {
                uintptr_t sp = *(uintptr_t *)(v + ivar_getOffset(agentSpaces));
                if (heapObjectOf(sp, spacesC)) return cachedSpaces = sp;
            }
        }
    }
    return 0;
}

enum { FOCUS_OK = 0, FOCUS_REFUSED = 1, FOCUS_NO_SPACES = -1, FOCUS_NOT_FOUND = -2, FOCUS_TIMEOUT = -3 };

// switchToUserSpace: takes a 0-based index into the user spaces across every
// display and traps on a negative one, so resolve the id to an index here
static int32_t focusSpace(uint64_t sid, int64_t *indexOut) {
    __block int32_t res = FOCUS_TIMEOUT;
    __block int64_t index = -1;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_main_queue(), ^{
        uintptr_t sp = locateSpaces();
        if (!sp) { res = FOCUS_NO_SPACES; dispatch_semaphore_signal(done); return; }
        id spaces = (__bridge id)(void *)sp;
        NSArray *all = ((id (*)(id, SEL))objc_msgSend)(spaces, sel_registerName("allUserSpaces"));
        SEL spidSel = sel_registerName("spid");
        res = FOCUS_NOT_FOUND;
        for (NSUInteger i = 0; i < all.count; i++) {
            id s = all[i];
            if (![s respondsToSelector:spidSel]) continue;
            if (((uint64_t (*)(id, SEL))objc_msgSend)(s, spidSel) != sid) continue;
            index = (int64_t)i;
            BOOL ok = ((BOOL (*)(id, SEL, long))objc_msgSend)(spaces,
                sel_registerName("switchToUserSpace:"), (long)i);
            res = ok ? FOCUS_OK : FOCUS_REFUSED;
            break;
        }
        dispatch_semaphore_signal(done);
    });
    dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC));
    *indexOut = index;
    return res;
}

// matched over the Dock's whole __TEXT at runtime; no per-version offset window
static uintptr_t patternFind(const char *pattern) {
    intptr_t slide = 0;
    const struct mach_header_64 *mh = dockImage(&slide);
    if (!mh) return 0;
    uint8_t want[96], solid[96];
    size_t n = 0;
    for (const char *p = pattern; *p; p += 3) {
        if (n >= sizeof want) return 0;
        if (p[0] == '?') solid[n] = 0;
        else { want[n] = (uint8_t)strtoul(p, NULL, 16); solid[n] = 1; }
        n++;
    }
    const struct load_command *lc = (const void *)(mh + 1);
    for (uint32_t i = 0; i < mh->ncmds; i++, lc = (const void *)((const uint8_t *)lc + lc->cmdsize)) {
        if (lc->cmd != LC_SEGMENT_64) continue;
        const struct segment_command_64 *seg = (const void *)lc;
        if (strcmp(seg->segname, "__TEXT")) continue;
        const uint8_t *b = (const uint8_t *)(seg->vmaddr + slide);
        for (uint64_t off = 0; off + n <= seg->vmsize; off++)
            for (size_t k = 0; ; k++) {
                if (k == n) return (uintptr_t)(b + off);
                if (solid[k] && b[off + k] != want[k]) break;
            }
        break;
    }
    return 0;
}

// add_space reads its DisplaySpaces argument from x20, outside the C ABI; the
// asm shim is yabai's (MIT, src/osax/arm64_payload.m)
#define callAddSpace(v0, v1, fn) \
    __asm__("mov x0, %0\n" "mov x20, %1\n" : : "r"((__bridge void *)(v0)), "r"((__bridge void *)(v1)) : "x0", "x20"); \
    ((void (*)(void))(fn))();

static uint64_t spaceSpid(id space) {
    return ((uint64_t (*)(id, SEL))objc_msgSend)(space, sel_registerName("spid"));
}

static id spaceForSpid(id displaySpaces, uint64_t sid) {
    Ivar iv = class_getInstanceVariable(object_getClass(displaySpaces), "spaces");
    if (!iv) return nil;
    NSArray *all = (__bridge id)(void *)*(uintptr_t *)((uintptr_t)(__bridge void *)displaySpaces + ivar_getOffset(iv));
    for (id s in all)
        if (spaceSpid(s) == sid) return s;
    return nil;
}

// the DisplaySpaces for a display: each one's _currentSpace names its display
// through SLS (yabai's route; spacesForDisplay: no longer exists on 26A428)
static id displaySpacesForUuid(uintptr_t sp, CFStringRef displayUuid) {
    Ivar iv = class_getInstanceVariable(object_getClass((__bridge id)(void *)sp), "_displaySpaces");
    if (!iv || !displayForSpaceF) return nil;
    NSArray *all = (__bridge id)(void *)*(uintptr_t *)(sp + ivar_getOffset(iv));
    for (id ds in all) {
        Ivar cur = class_getInstanceVariable(object_getClass(ds), "_currentSpace");
        if (!cur) continue;
        id curSpace = (__bridge id)(void *)*(uintptr_t *)((uintptr_t)(__bridge void *)ds + ivar_getOffset(cur));
        if (!curSpace) continue;
        CFStringRef uuid = displayForSpaceF(cid, spaceSpid(curSpace));
        BOOL match = uuid && CFStringCompare(uuid, displayUuid, 0) == kCFCompareEqualTo;
        if (uuid) CFRelease(uuid);
        if (match) return ds;
    }
    return nil;
}

// create: new_space = [[ManagedSpace alloc] init], then the Dock's own
// add_space(new_space, display_space) on the Dock main queue. The reference
// sid only names the display to create on.
static int32_t createSpace(uint64_t refSid) {
    __block int32_t res = SPACEC_TIMEOUT;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_main_queue(), ^{
        uintptr_t sp = locateSpaces();
        if (!sp) res = SPACEC_NO_SPACES;
        else if (!displayForSpaceF || !addSpaceFp) res = SPACEC_UNRESOLVED;
        else {
            CFStringRef displayUuid = displayForSpaceF(cid, refSid);
            if (!displayUuid) res = SPACEC_BAD_SID;
            else {
                id ds = displaySpacesForUuid(sp, displayUuid);
                CFRelease(displayUuid);
                Class c = objc_getClass("ManagedSpace") ?: objc_getClass("Dock.ManagedSpace");
                if (!ds) res = SPACEC_NO_DISPLAY;
                else if (!c) res = SPACEC_NO_CLASS;
                else {
                    id newSpace = ((id (*)(id, SEL))objc_msgSend)((id)c, sel_registerName("alloc"));
                    newSpace = ((id (*)(id, SEL))objc_msgSend)(newSpace, sel_registerName("init"));
                    callAddSpace(newSpace, ds, addSpaceFp);
                    // the empty asm keeps both objects alive across the indirect call;
                    // ARC cannot see that the call above consumes them
                    __asm__ volatile("" : : "r"((__bridge void *)newSpace), "r"((__bridge void *)ds));
                    res = SPACEC_OK;
                }
            }
        }
        dispatch_semaphore_signal(done);
    });
    dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC));
    return res;
}

// destroy: the Dock's own remove_space(space, display_space, dock_spaces,
// sid, sid), then _currentSpace resync if the active space died (yabai's
// post-destroy fix). SLSCopyManagedDisplayForSpace must be checked first:
// an unknown sid NULLs the display and crashes the Dock inside
// SLSManagedDisplayGetCurrentSpace (asmvik/yabai#2832)
static int32_t destroySpace(uint64_t sid) {
    if (!displayForSpaceF || !currentSpaceOfDisplayF || !removeSpaceFp) return SPACEC_UNRESOLVED;
    CFStringRef displayUuid = displayForSpaceF(cid, sid);
    if (!displayUuid) return SPACEC_BAD_SID;
    uint64_t activeSid = currentSpaceOfDisplayF(cid, displayUuid);
    __block int32_t res = SPACEC_TIMEOUT;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_main_queue(), ^{
        uintptr_t sp = locateSpaces();
        if (!sp) res = SPACEC_NO_SPACES;
        else {
            id ds = displaySpacesForUuid(sp, displayUuid);
            id space = ds ? spaceForSpid(ds, sid) : nil;
            if (!ds || !space) res = SPACEC_NOT_FOUND;
            else {
                ((void (*)(id, id, id, uint64_t, uint64_t))removeSpaceFp)(
                    space, ds, (__bridge id)(void *)sp, sid, sid);
                if (activeSid == sid) {
                    id dest = spaceForSpid(ds, currentSpaceOfDisplayF(cid, displayUuid));
                    if (dest) {
                        Ivar cur = class_getInstanceVariable(object_getClass(ds), "_currentSpace");
                        // the ivar is a strong ref: retain the new value, leak the old (yabai's choice)
                        if (cur)
                            *(uintptr_t *)((uintptr_t)(__bridge void *)ds + ivar_getOffset(cur)) =
                                (uintptr_t)CFBridgingRetain(dest);
                    }
                }
                res = SPACEC_OK;
            }
        }
        CFRelease(displayUuid);
        dispatch_semaphore_signal(done);
    });
    dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC));
    return res;
}

// no animation: show/hide/set-current on the window server, then tell the
// Dock's model ourselves (yabai's do_space_focus). SLSCopyManagedDisplayForSpace
// first, for the same NULL-display crash destroySpace guards against
static int32_t focusSpaceInstant(uint64_t sid) {
    if (!displayForSpaceF || !currentSpaceOfDisplayF || !showSpacesF || !hideSpacesF || !setCurrentSpaceF)
        return SPACEC_UNRESOLVED;
    CFStringRef displayUuid = displayForSpaceF(cid, sid);
    if (!displayUuid) return SPACEC_BAD_SID;
    __block int32_t res = SPACEC_TIMEOUT;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_main_queue(), ^{
        uintptr_t sp = locateSpaces();
        id ds = sp ? displaySpacesForUuid(sp, displayUuid) : nil;
        id dest = ds ? spaceForSpid(ds, sid) : nil;
        Ivar cur = ds ? class_getInstanceVariable(object_getClass(ds), "_currentSpace") : NULL;
        uint64_t src = currentSpaceOfDisplayF(cid, displayUuid);
        if (!sp) res = SPACEC_NO_SPACES;
        else if (!ds) res = SPACEC_NO_DISPLAY;
        else if (!dest || !cur) res = SPACEC_NOT_FOUND;
        else {
            if (src != sid) {
                showSpacesF(cid, (__bridge CFArrayRef)@[@(sid)]);
                hideSpacesF(cid, (__bridge CFArrayRef)@[@(src)]);
                setCurrentSpaceF(cid, displayUuid, sid);
                // the ivar is a strong ref: retain the new value, leak the old (yabai's choice)
                *(uintptr_t *)((uintptr_t)(__bridge void *)ds + ivar_getOffset(cur)) =
                    (uintptr_t)CFBridgingRetain(dest);
            }
            res = SPACEC_OK;
        }
        CFRelease(displayUuid);
        dispatch_semaphore_signal(done);
    });
    dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC));
    return res;
}

static BOOL readN(int fd, void *buf, size_t n) {
    uint8_t *p = buf;
    while (n) {
        ssize_t r = read(fd, p, n);
        if (r <= 0) return NO;
        p += r; n -= r;
    }
    return YES;
}

static BOOL writeN(int fd, const void *buf, size_t n) {
    const uint8_t *p = buf;
    while (n) {
        ssize_t w = write(fd, p, n);
        if (w <= 0) return NO;
        p += w; n -= w;
    }
    return YES;
}

static void handle(int fd) {
    uint8_t op = 0;
    uint32_t wid = 0;
    if (!readN(fd, &op, 1)) goto out;
    if (op != OP_HELLO && op != OP_DUMP_CLASSES && op != OP_FIND_SPACES && !readN(fd, &wid, 4)) goto out;
    switch (op) {
    case OP_HELLO: {
        uint8_t r[5];
        uint32_t mask = (setTagsF ? 1u : 0u) | (clearTagsF ? 2u : 0u) | (queryF ? 4u : 0u)
                      | (addSpaceFp ? 8u : 0u) | (removeSpaceFp ? 16u : 0u)
                      | (showSpacesF && hideSpacesF && setCurrentSpaceF ? 32u : 0u);
        r[0] = SA_PROTO_VERSION;
        memcpy(r + 1, &mask, 4);
        writeN(fd, r, sizeof r);
        break;
    }
    case OP_STICKY_SET:
    case OP_STICKY_CLEAR: {
        int32_t err = kCGErrorFailure;
        uint64_t tags = 0;
        if (op == OP_STICKY_SET ? setTagsF != NULL : clearTagsF != NULL) {
            uint64_t mask = 1ULL << STICKY_BIT;
            err = (int32_t)(op == OP_STICKY_SET
                ? setTagsF(cid, wid, &mask, 64)
                : clearTagsF(cid, wid, &mask, 64));
            tags = tagsFor(wid);
        }
        uint8_t r[12];
        memcpy(r, &err, 4);
        memcpy(r + 4, &tags, 8);
        writeN(fd, r, sizeof r);
        break;
    }
    case OP_STICKY_QUERY: {
        int32_t err = kCGErrorSuccess;
        uint64_t tags = tagsFor(wid);
        uint8_t r[12];
        memcpy(r, &err, 4);
        memcpy(r + 4, &tags, 8);
        writeN(fd, r, sizeof r);
        break;
    }
    case OP_SPACE_FOCUS: {
        uint64_t sid = wid;
        uint32_t hi = 0;
        if (!readN(fd, &hi, 4)) goto out;
        sid |= (uint64_t)hi << 32;
        int64_t index = -1;
        int32_t err = focusSpace(sid, &index);
        uint8_t r[12];
        memcpy(r, &err, 4);
        memcpy(r + 4, &index, 8);
        writeN(fd, r, sizeof r);
        break;
    }
    case OP_SPACE_CREATE:
    case OP_SPACE_DESTROY:
    case OP_SPACE_FOCUS_INSTANT: {
        uint64_t sid = wid;
        uint32_t hi = 0;
        if (!readN(fd, &hi, 4)) goto out;
        sid |= (uint64_t)hi << 32;
        int32_t err = op == OP_SPACE_CREATE ? createSpace(sid)
                    : op == OP_SPACE_DESTROY ? destroySpace(sid) : focusSpaceInstant(sid);
        uint8_t r[12];
        memcpy(r, &err, 4);
        memset(r + 4, 0, 8);
        writeN(fd, r, sizeof r);
        break;
    }
    case OP_DUMP_CLASSES:
    case OP_FIND_SPACES: {
        uint8_t flags = 0;
        if (op == OP_FIND_SPACES && !readN(fd, &flags, 1)) goto out;
        char path[128];
        snprintf(path, sizeof path, "/tmp/spacetool-sa-%s%s_%s.txt",
                 op == OP_DUMP_CLASSES ? "classes" : "find", hostSuffix(), userName());
        int64_t len = op == OP_DUMP_CLASSES ? dumpClasses(path) : findSpaces(path, flags & 1);
        int32_t err = len < 0 ? kCGErrorFailure : kCGErrorSuccess;
        uint64_t ulen = len < 0 ? 0 : (uint64_t)len;
        uint8_t r[12];
        memcpy(r, &err, 4);
        memcpy(r + 4, &ulen, 8);
        writeN(fd, r, sizeof r);
        break;
    }
    }
out:
    close(fd);
}

static void *serve(void *unused) {
    (void)unused;
    int s = socket(AF_UNIX, SOCK_STREAM, 0);
    if (s < 0) { NSLog(@"[spacetool-sa] socket: %s", strerror(errno)); return NULL; }
    const char *user = userName();
    struct sockaddr_un addr;
    memset(&addr, 0, sizeof addr);
    addr.sun_family = AF_UNIX;
    snprintf(addr.sun_path, sizeof addr.sun_path, "/tmp/spacetool-sa%s_%s.socket", hostSuffix(), user);
    unlink(addr.sun_path);
    if (bind(s, (struct sockaddr *)&addr, sizeof addr) < 0) {
        NSLog(@"[spacetool-sa] bind: %s", strerror(errno));
        return NULL;
    }
    chmod(addr.sun_path, 0600);
    if (listen(s, 8) < 0) { NSLog(@"[spacetool-sa] listen: %s", strerror(errno)); return NULL; }
    NSLog(@"[spacetool-sa] listening at %s", addr.sun_path);
    for (;;) {
        int fd = accept(s, NULL, 0);
        if (fd >= 0) handle(fd);
    }
    return NULL;
}

__attribute__((constructor))
static void loadPayload(void) {
    inWindowManager = !strcmp(getprogname(), "WindowManager");
    NSLog(@"[spacetool-sa] payload loaded in %s", getprogname());
    void *h = RTLD_DEFAULT;
    ConnFn connF = (ConnFn)dlsym(h, "SLSMainConnectionID");
    setTagsF = (TagsFn)dlsym(h, "SLSSetWindowTags");
    clearTagsF = (TagsFn)dlsym(h, "SLSClearWindowTags");
    queryF = (QueryWindowsFn)dlsym(h, "SLSWindowQueryWindows");
    iterCopyF = (QueryResultCopyFn)dlsym(h, "SLSWindowQueryResultCopyWindows");
    iterAdvF = (IterAdvanceFn)dlsym(h, "SLSWindowIteratorAdvance");
    iterWidF = (IterWidFn)dlsym(h, "SLSWindowIteratorGetWindowID");
    iterTagsF = (IterTagsFn)dlsym(h, "SLSWindowIteratorGetTags");
    displayForSpaceF = (CopyDisplayForSpaceFn)dlsym(h, "SLSCopyManagedDisplayForSpace");
    currentSpaceOfDisplayF = (CurrentSpaceOfDisplayFn)dlsym(h, "SLSManagedDisplayGetCurrentSpace");
    showSpacesF = (SpaceListFn)dlsym(h, "SLSShowSpaces");
    hideSpacesF = (SpaceListFn)dlsym(h, "SLSHideSpaces");
    setCurrentSpaceF = (SetCurrentSpaceFn)dlsym(h, "SLSManagedDisplaySetCurrentSpace");
    if (!connF) { NSLog(@"[spacetool-sa] SLSMainConnectionID missing"); return; }
    cid = connF();
    NSLog(@"[spacetool-sa] cid %d set=%d clear=%d query=%d", cid,
           setTagsF != NULL, clearTagsF != NULL, queryF != NULL);
    if (!inWindowManager) {
        addSpaceFp = patternFind(addSpacePattern);
        removeSpaceFp = patternFind(removeSpacePattern);
        if (!displayForSpaceF || !currentSpaceOfDisplayF) { addSpaceFp = 0; removeSpaceFp = 0; }
        if (addSpaceFp)
            addSpaceFp = (uintptr_t)ptrauth_sign_unauthenticated((void *)addSpaceFp,
                ptrauth_key_asia, 0);
        if (removeSpaceFp)
            removeSpaceFp = (uintptr_t)ptrauth_sign_unauthenticated((void *)removeSpaceFp,
                ptrauth_key_asia, 0);
        NSLog(@"[spacetool-sa] space create=%s destroy=%s",
              addSpaceFp ? "ok" : "PATTERN MISS (HELLO will report it)",
              removeSpaceFp ? "ok" : "PATTERN MISS (HELLO will report it)");
    }
    if (!setTagsF && !clearTagsF && !queryF) return;
    // a client that vanishes mid-reply must not be able to SIGPIPE the host
    signal(SIGPIPE, SIG_IGN);
    pthread_t t;
    pthread_create(&t, NULL, serve, NULL);
    pthread_detach(t);
}
