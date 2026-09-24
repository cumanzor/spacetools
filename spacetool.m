// spacetool - name, list, switch, create, remove macOS spaces; move windows between them
// modes: current | list | set <name> | switch <query> | bring <app> | send <space>
//        create [name] | rm <space> | layout save | layout restore
#import <Cocoa/Cocoa.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <mach/mach_time.h>

typedef int (*ConnFn)(void);
typedef CFArrayRef (*MDSFn)(int);
typedef CFArrayRef (*CopySpacesFn)(int, int, CFArrayRef);

static int cid;
static MDSFn mdsF;
static CopySpacesFn copySpacesF;

static NSString *mapPath(void) {
    return [NSHomeDirectory() stringByAppendingPathComponent:@".config/spacenames.json"];
}
static NSMutableDictionary *loadMap(void) {
    NSData *d = [NSData dataWithContentsOfFile:mapPath()];
    if (!d) return [NSMutableDictionary dictionary];
    id o = [NSJSONSerialization JSONObjectWithData:d options:NSJSONReadingMutableContainers error:nil];
    return [o isKindOfClass:[NSMutableDictionary class]] ? o : [NSMutableDictionary dictionary];
}
static void saveMap(NSDictionary *m) {
    [[NSFileManager defaultManager] createDirectoryAtPath:mapPath().stringByDeletingLastPathComponent
        withIntermediateDirectories:YES attributes:nil error:nil];
    NSData *d = [NSJSONSerialization dataWithJSONObject:m
        options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:nil];
    [d writeToFile:mapPath() atomically:YES];
}

// every space across displays, in mission control order
static NSArray *spaceInfos(void) {
    NSMutableArray *out = [NSMutableArray array];
    NSDictionary *map = loadMap();
    for (NSDictionary *d in (NSArray *)CFBridgingRelease(mdsF(cid))) {
        uint64_t cur = [d[@"Current Space"][@"ManagedSpaceID"] unsignedLongLongValue];
        int ord = 0;
        for (NSDictionary *s in d[@"Spaces"]) {
            ord++;
            uint64_t sid = [s[@"ManagedSpaceID"] unsignedLongLongValue];
            [out addObject:@{ @"sid": @(sid), @"uuid": s[@"uuid"] ?: @"",
                @"name": map[s[@"uuid"] ?: @""] ?: @"", @"ord": @(ord),
                @"display": d[@"Display Identifier"] ?: @"Main",
                @"current": @(sid == cur), @"type": s[@"type"] ?: @0 }];
        }
    }
    return out;
}
static NSDictionary *currentSpaceInfo(void) {
    for (NSDictionary *s in spaceInfos()) if ([s[@"current"] boolValue]) return s;
    return nil;
}
static NSDictionary *matchSpace(NSString *query) {
    NSArray *all = spaceInfos();
    NSString *q = query.lowercaseString;
    // a bare number is an ordinal before it is a name: "1" must not substring-
    // match a space named "messaging1", and the MC digit tap passes ordinals
    if (q.length && [q rangeOfCharacterFromSet:
            [NSCharacterSet decimalDigitCharacterSet].invertedSet].location == NSNotFound)
        for (NSDictionary *s in all) if ([s[@"ord"] intValue] == q.intValue) return s;
    for (NSDictionary *s in all) if ([[s[@"name"] lowercaseString] isEqualToString:q]) return s;
    for (NSDictionary *s in all) if ([s[@"name"] length] && [[s[@"name"] lowercaseString] hasPrefix:q]) return s;
    for (NSDictionary *s in all) if ([s[@"name"] length] && [[s[@"name"] lowercaseString] containsString:q]) return s;
    int n = query.intValue;
    if (n > 0) for (NSDictionary *s in all) if ([s[@"ord"] intValue] == n) return s;
    return nil;
}

// every op in one transaction: a space switch split across several transactions
// lets the window server apply half a switch
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
static void bridgedOp(id op) { bridgedOps(op ? @[op] : @[]); }

static NSDictionary *currentSpaceOnDisplay(NSString *ident) {
    for (NSDictionary *s in spaceInfos())
        if ([s[@"current"] boolValue] && [s[@"display"] isEqualToString:ident]) return s;
    return nil;
}
static CGDirectDisplayID displayIDForIdent(NSString *ident) {
    if (!ident.length || [ident isEqualToString:@"Main"]) return CGMainDisplayID();
    CGDirectDisplayID ids[16]; uint32_t n = 0;
    CGGetActiveDisplayList(16, ids, &n);
    for (uint32_t i = 0; i < n; i++) {
        CFUUIDRef u = CGDisplayCreateUUIDFromDisplayID(ids[i]);
        if (!u) continue;
        NSString *str = CFBridgingRelease(CFUUIDCreateString(NULL, u));
        CFRelease(u);
        if ([str isEqualToString:ident]) return ids[i];
    }
    return CGMainDisplayID();
}

// macOS 27 ignores a dock swipe carrying only the CGEvent gesture fields; it
// wants the raw IOHID fluid-touch payload too, appended to the serialized event
// as field 4205. Layout, signs and 10ms phase pacing are InstantSpaceSwitcher's
// (MIT), from its macos-27 branch: Sources/ISS/event_serialize.c and ISS.c.
#pragma pack(push, 1)
typedef struct { uint32_t size, type, options; uint8_t depth, reserved[3]; } HIDBase;
typedef struct { HIDBase base; int32_t px, py, pz; uint32_t mask; uint16_t motion, flavor; int32_t progress; } HIDFluid;
typedef struct { HIDBase base; int32_t vx, vy, vz; } HIDVelocity;
typedef struct { uint64_t ts, sender; uint32_t options, attrLen, count; } HIDHeader;
#pragma pack(pop)

static int32_t fixed1616(double v) {
    int32_t f = (int32_t)(v * 65536.0);
    return (f == 0 && v != 0) ? (v > 0 ? 1 : -1) : f;
}

static BOOL postSwipePhase27(int phase, int dir, double speed) {
    double progress = dir > 0 ? -0.000016 : 0.000016;
    double vel = dir > 0 ? -speed : speed;
    BOOL ended = phase == 4;
    CGEventRef e = CGEventCreate(NULL);
    if (!e) return NO;
    CGEventSetIntegerValueField(e, 55, 30);      // gesture event
    CGEventSetIntegerValueField(e, 110, 23);     // subtype: dock control
    CGEventSetIntegerValueField(e, 123, 1);      // horizontal
    CGEventSetDoubleValueField(e, 124, progress);
    CGEventSetDoubleValueField(e, 125, 0.1);
    CGEventSetIntegerValueField(e, 132, phase);
    CGEventSetIntegerValueField(e, 134, phase);
    CGEventSetDoubleValueField(e, 138, 3.0);
    CGEventSetDoubleValueField(e, 169, (double)mach_absolute_time());
    if (ended) CGEventSetDoubleValueField(e, 129, vel);

    size_t plen = sizeof(HIDHeader) + sizeof(HIDFluid) + (ended ? sizeof(HIDVelocity) : 0);
    NSMutableData *payload = [NSMutableData dataWithLength:plen];
    uint8_t *p = payload.mutableBytes;
    HIDHeader *h = (HIDHeader *)p;
    h->ts = mach_absolute_time();
    h->count = ended ? 2 : 1;
    HIDFluid *f = (HIDFluid *)(p + sizeof *h);
    f->base.size = sizeof *f;
    f->base.type = 23;                           // fluid touch gesture
    f->base.options = (uint32_t)(phase & 0xff) << 24;
    f->px = fixed1616(0.1);
    f->motion = 1;
    f->flavor = 3;                               // dock primary
    f->progress = fixed1616(progress);
    if (ended) {
        HIDVelocity *v = (HIDVelocity *)(p + sizeof *h + sizeof *f);
        v->base.size = sizeof *v;
        v->base.type = 9;
        v->base.depth = 1;
        v->vx = fixed1616(vel);
    }

    NSMutableData *raw = [CFBridgingRelease(CGEventCreateData(NULL, e)) mutableCopy];
    CFRelease(e);
    const uint8_t *rb = raw.bytes;
    if (raw.length < 4 || rb[0] || rb[1] || rb[2] || rb[3] != 2) return NO;   // format v2 only
    uint8_t tag[4] = { (plen >> 8) & 0xff, plen & 0xff, (4205 >> 8) & 0xff, 4205 & 0xff };
    [raw appendBytes:tag length:4];
    [raw appendData:payload];
    CGEventRef a = CGEventCreateFromData(NULL, (__bridge CFDataRef)raw);
    if (!a) return NO;
    CGEventPost(kCGSessionEventTap, a);
    CFRelease(a);
    return YES;
}

// the Dock drops phases posted back to back on 27
static BOOL postDockSwipe27(int dir, double speed) {
    if (!postSwipePhase27(1, dir, speed)) return NO;
    usleep(10000);
    if (!postSwipePhase27(2, dir, speed)) return NO;
    usleep(10000);
    return postSwipePhase27(4, dir, speed);
}

// Setting the current space through SkyLight only moves the window server. The
// Dock keeps its own index and nothing in the bridge tells it otherwise, so
// Mission Control keeps drawing the space you left and ctrl-arrow counts from
// the wrong desktop. Driving the Dock's own swipe gesture makes the Dock
// perform the switch, so its model stays in step. Field numbers and the 9999
// velocity (which skips the slide animation) are yabai's, from
// src/space_manager.c space_manager_focus_space_using_gesture.
static int switchToSpace(NSDictionary *s) {
    NSString *ident = s[@"display"];
    NSDictionary *cur = currentSpaceOnDisplay(ident);
    if (!cur) { fprintf(stderr, "sw: no current space on display %s\n", ident.UTF8String); return 1; }
    int delta = [s[@"ord"] intValue] - [cur[@"ord"] intValue];
    if (delta == 0) return 0;

    CGRect b = CGDisplayBounds(displayIDForIdent(ident));
    if (![ident isEqualToString:currentSpaceInfo()[@"display"]])
        CGWarpMouseCursorPosition(CGPointMake(CGRectGetMidX(b), CGRectGetMidY(b)));

    if (NSProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27) {
        int dir = delta > 0 ? 1 : -1, n = abs(delta);
        for (int i = 0; i < n; i++)
            if (!postDockSwipe27(dir, 2000.0 * n)) { fprintf(stderr, "sw: could not build the swipe event\n"); return 1; }
    } else {
        CGEventRef e = CGEventCreate(NULL);
        if (!e) { fprintf(stderr, "sw: CGEventCreate failed\n"); return 1; }
        double sign = delta > 0 ? 1.0 : -1.0;
        CGEventSetIntegerValueField(e, 55, 30);      // gesture event
        CGEventSetIntegerValueField(e, 110, 23);     // subtype: dock control
        CGEventSetIntegerValueField(e, 123, 1);
        CGEventSetDoubleValueField(e, 124, sign);
        CGEventSetDoubleValueField(e, 129, sign * 9999.0);
        for (int i = 0, n = abs(delta); i < n; i++) {
            CGEventSetIntegerValueField(e, 132, 1);  // phase: began
            CGEventPost(kCGSessionEventTap, e);
            CGEventSetIntegerValueField(e, 132, 4);  // phase: ended
            CGEventPost(kCGSessionEventTap, e);
        }
        CFRelease(e);
    }

    for (int i = 0; i < 40; i++) {               // settle, then confirm it took
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
        if ([currentSpaceOnDisplay(ident)[@"sid"] isEqual:s[@"sid"]]) return 0;
    }
    fprintf(stderr, "sw: the Dock ignored the gesture. Grant Accessibility to\n"
                    "    ~/Applications/SpaceTool.app in System Settings >\n"
                    "    Privacy & Security > Accessibility, then try again.\n");
    return 1;
}
static void moveWindowsToSpace(NSArray *wids, uint64_t sid) {
    Class opCls = NSClassFromString(@"SLSBridgedMoveWindowsToManagedSpaceOperation");
    id (*initFn)(id, SEL, id, uint64_t) = (id(*)(id,SEL,id,uint64_t))objc_msgSend;
    id op = initFn(((id(*)(id,SEL))objc_msgSend)(opCls, sel_registerName("alloc")),
                   sel_registerName("initWithWindows:spaceID:"), wids, sid);
    bridgedOp(op);
}

// The Dock owns the space list. SLSSpaceCreate/Destroy exist but leave the
// Dock desynced, the same failure the bridged switch had, so create and rm
// drive Mission Control's own controls: mc.spaces.add is a plain AXButton and
// every space thumbnail carries an AXRemoveDesktop action.
static NSString *axAttr(AXUIElementRef el, CFStringRef name) {
    CFTypeRef v = NULL;
    if (AXUIElementCopyAttributeValue(el, name, &v) != kAXErrorSuccess || !v) return @"";
    if (CFGetTypeID(v) == CFStringGetTypeID()) return CFBridgingRelease(v);
    NSString *out = [(__bridge id)v description];
    CFRelease(v);
    return out;
}
static NSArray *axChildren(AXUIElementRef el) {
    CFTypeRef v = NULL;
    if (AXUIElementCopyAttributeValue(el, kAXChildrenAttribute, &v) != kAXErrorSuccess || !v) return @[];
    return CFBridgingRelease(v);
}
static CGPoint axOrigin(AXUIElementRef el) {
    CGPoint p = CGPointZero;
    CFTypeRef v = NULL;
    if (AXUIElementCopyAttributeValue(el, kAXPositionAttribute, &v) == kAXErrorSuccess && v) {
        AXValueGetValue((AXValueRef)v, kAXValueTypeCGPoint, &p);
        CFRelease(v);
    }
    return p;
}
static AXUIElementRef axFind(AXUIElementRef el, NSString *ident, int depth) {
    if ([axAttr(el, kAXIdentifierAttribute) isEqualToString:ident]) return (AXUIElementRef)CFRetain(el);
    if (depth <= 0) return NULL;
    for (id k in axChildren(el)) {
        AXUIElementRef hit = axFind((__bridge AXUIElementRef)k, ident, depth - 1);
        if (hit) return hit;
    }
    return NULL;
}
static BOOL axReady(const char *verb) {
    if (AXIsProcessTrusted()) return YES;
    fprintf(stderr, "%s: needs Accessibility. Grant it to\n"
                    "    ~/Applications/SpaceTool.app in System Settings >\n"
                    "    Privacy & Security > Accessibility, then try again.\n", verb);
    return NO;
}

static void settle(double s) {
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:s]];
}
// macOS 26 and earlier: a Dock window at layer 18. macOS 27 moved Mission
// Control into WindowManager, which puts layer 19 shield windows up while open.
static BOOL mcShowing(void) {
    NSArray *list = CFBridgingRelease(CGWindowListCopyWindowInfo(
        kCGWindowListOptionOnScreenOnly, kCGNullWindowID));
    for (NSDictionary *w in list) {
        NSString *owner = w[(id)kCGWindowOwnerName];
        int layer = [w[(id)kCGWindowLayer] intValue];
        if (([owner isEqual:@"Dock"] && layer == 18) ||
            ([owner isEqual:@"WindowManager"] && layer == 19))
            return YES;
    }
    return NO;
}
static void closeMissionControl(void) {
    CGEventRef d = CGEventCreateKeyboardEvent(NULL, 53, true);
    CGEventRef u = CGEventCreateKeyboardEvent(NULL, 53, false);
    if (d) { CGEventPost(kCGSessionEventTap, d); CFRelease(d); }
    if (u) { CGEventPost(kCGSessionEventTap, u); CFRelease(u); }
    for (int i = 0; i < 20 && mcShowing(); i++) settle(0.1);
}

// mc.display groups: children of Dock's "mc" group up to macOS 26, direct
// children of the WindowManager app from macOS 27
static NSArray *mcDisplayGroups(AXUIElementRef dock, AXUIElementRef wm) {
    NSMutableArray *out = [NSMutableArray array];
    NSMutableArray *parents = [NSMutableArray array];
    if (wm) [parents addObject:(__bridge id)wm];
    AXUIElementRef mc = dock ? axFind(dock, @"mc", 3) : NULL;
    if (mc) [parents addObject:CFBridgingRelease(mc)];
    for (id p in parents)
        for (id k in axChildren((__bridge AXUIElementRef)p))
            if ([axAttr((__bridge AXUIElementRef)k, kAXIdentifierAttribute) isEqualToString:@"mc.display"])
                [out addObject:k];
    return out;
}

// opens MC if needed and returns the retained mc.spaces group for a display.
// mc.display groups carry no identifier, so match their AX origin (global
// top-left coords) against the display's CGDisplayBounds.
static AXUIElementRef mcSpacesGroupFor(NSString *ident) {
    NSRunningApplication *dockApp = [NSRunningApplication
        runningApplicationsWithBundleIdentifier:@"com.apple.dock"].firstObject;
    NSRunningApplication *wmApp = [NSRunningApplication
        runningApplicationsWithBundleIdentifier:@"com.apple.WindowManager"].firstObject;
    if (!dockApp && !wmApp) return NULL;
    AXUIElementRef dock = dockApp ? AXUIElementCreateApplication(dockApp.processIdentifier) : NULL;
    AXUIElementRef wm = wmApp ? AXUIElementCreateApplication(wmApp.processIdentifier) : NULL;
    CGPoint want = CGDisplayBounds(displayIDForIdent(ident)).origin;
    if (!mcShowing())
        [[NSWorkspace sharedWorkspace] openApplicationAtURL:[NSURL fileURLWithPath:
            @"/System/Applications/Mission Control.app"]
            configuration:[NSWorkspaceOpenConfiguration configuration] completionHandler:nil];
    AXUIElementRef group = NULL;
    for (int i = 0; i < 30 && !group; i++) {
        settle(0.1);
        // strong ids, not raw AXUIElementRefs: the children array is a
        // temporary and ARC may free it (and its elements) right after the
        // enumeration under -O2
        id match = nil, first = nil;
        for (id k in mcDisplayGroups(dock, wm)) {
            if (!first) first = k;
            CGPoint p = axOrigin((__bridge AXUIElementRef)k);
            if (fabs(p.x - want.x) < 2 && fabs(p.y - want.y) < 2) { match = k; break; }
        }
        if (!match && i == 29) match = first;   // display moved mid-open, take the menu bar one
        if (match) group = (AXUIElementRef)CFBridgingRetain(match);
    }
    if (dock) CFRelease(dock);
    if (wm) CFRelease(wm);
    if (!group) return NULL;
    settle(0.35);   // let the bar finish laying out
    AXUIElementRef spaces = axFind(group, @"mc.spaces", 2);
    CFRelease(group);
    return spaces;
}

static NSArray *desktopsOnDisplay(NSString *ident) {
    NSMutableArray *out = [NSMutableArray array];
    for (NSDictionary *s in spaceInfos())
        if ([s[@"display"] isEqualToString:ident] && [s[@"type"] intValue] == 0)
            [out addObject:s];
    return out;
}

static NSString *label(NSDictionary *s) {
    return [s[@"name"] length] ? s[@"name"]
         : [NSString stringWithFormat:@"Desktop %d", [s[@"ord"] intValue]];
}

static int cmdCurrent(void) { printf("%s\n", label(currentSpaceInfo()).UTF8String); return 0; }
static int cmdList(void) {
    for (NSDictionary *s in spaceInfos())
        printf("%s %2d  %-20s (space %llu)\n", [s[@"current"] boolValue] ? "*" : " ",
               [s[@"ord"] intValue], label(s).UTF8String, [s[@"sid"] unsignedLongLongValue]);
    return 0;
}
static int cmdSet(NSString *name) {
    NSDictionary *s = currentSpaceInfo();
    NSMutableDictionary *map = loadMap();
    if (name.length) map[s[@"uuid"]] = name; else [map removeObjectForKey:s[@"uuid"]];
    saveMap(map);
    printf("space %llu (Desktop %d) -> \"%s\"\n", [s[@"sid"] unsignedLongLongValue],
           [s[@"ord"] intValue], name.UTF8String);
    return 0;
}
static int cmdSwitch(NSString *query) {
    NSDictionary *s = matchSpace(query);
    if (!s) { fprintf(stderr, "sw: no space matching \"%s\"\n", query.UTF8String); return 1; }
    if ([s[@"current"] boolValue]) { printf("already on %s\n", label(s).UTF8String); return 0; }
    int r = switchToSpace(s);
    if (!r) printf("switched to %s\n", label(s).UTF8String);
    return r;
}
static int cmdBring(NSString *query) {
    NSDictionary *cur = currentSpaceInfo();
    uint64_t space = [cur[@"sid"] unsignedLongLongValue];
    NSString *q = query.lowercaseString;
    NSRunningApplication *match = nil;
    for (NSRunningApplication *a in [[NSWorkspace sharedWorkspace] runningApplications]) {
        if (a.activationPolicy != NSApplicationActivationPolicyRegular) continue;
        NSString *n = a.localizedName.lowercaseString;
        if ([n isEqualToString:q]) { match = a; break; }
        if (!match && ([n hasPrefix:q] || [n containsString:q])) match = a;
    }
    if (!match) { fprintf(stderr, "bring: no running app matching \"%s\"\n", query.UTF8String); return 1; }
    NSArray *list = CFBridgingRelease(CGWindowListCopyWindowInfo(
        kCGWindowListExcludeDesktopElements, kCGNullWindowID));
    NSMutableArray *wids = [NSMutableArray array];
    for (NSDictionary *w in list) {
        if ([w[(id)kCGWindowOwnerPID] intValue] != match.processIdentifier) continue;
        if ([w[(id)kCGWindowLayer] intValue] != 0) continue;
        CGRect b; CGRectMakeWithDictionaryRepresentation((CFDictionaryRef)w[(id)kCGWindowBounds], &b);
        if (b.size.width < 120 || b.size.height < 120) continue;
        NSNumber *wid = w[(id)kCGWindowNumber];
        NSArray *on = CFBridgingRelease(copySpacesF(cid, 7, (__bridge CFArrayRef)@[wid]));
        if (on.count != 1) continue;
        if ([on.firstObject unsignedLongLongValue] == space) continue;
        [wids addObject:wid];
    }
    if (wids.count) {
        moveWindowsToSpace(wids, space);
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.35]];
    }
    [match activateWithOptions:NSApplicationActivateAllWindows];
    printf("%s: moved %lu window%s here\n", match.localizedName.UTF8String,
           (unsigned long)wids.count, wids.count == 1 ? "" : "s");
    return 0;
}

// onscreen windows come back front to back, so the first real one is what the
// user is looking at, and onscreen already scopes us to the current space
static int cmdSend(NSString *query) {
    NSDictionary *dest = matchSpace(query);
    if (!dest) { fprintf(stderr, "send: no space matching \"%s\"\n", query.UTF8String); return 1; }
    if ([dest[@"current"] boolValue]) {
        printf("already on %s\n", label(dest).UTF8String); return 0;
    }
    NSArray *list = CFBridgingRelease(CGWindowListCopyWindowInfo(
        kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements, kCGNullWindowID));
    for (NSDictionary *w in list) {
        if ([w[(id)kCGWindowLayer] intValue] != 0) continue;
        CGRect b; CGRectMakeWithDictionaryRepresentation((CFDictionaryRef)w[(id)kCGWindowBounds], &b);
        if (b.size.width < 120 || b.size.height < 120) continue;
        moveWindowsToSpace(@[w[(id)kCGWindowNumber]], [dest[@"sid"] unsignedLongLongValue]);
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.35]];
        printf("sent %s to %s\n", [w[(id)kCGWindowOwnerName] description].UTF8String,
               label(dest).UTF8String);
        return 0;
    }
    fprintf(stderr, "send: no window to send\n");
    return 1;
}

static int cmdCreate(NSString *name) {
    if (!axReady("create")) return 1;
    NSString *ident = currentSpaceInfo()[@"display"] ?: @"Main";
    NSMutableSet *had = [NSMutableSet set];
    for (NSDictionary *s in spaceInfos()) [had addObject:s[@"uuid"]];
    AXUIElementRef spaces = mcSpacesGroupFor(ident);
    AXUIElementRef add = spaces ? axFind(spaces, @"mc.spaces.add", 2) : NULL;
    if (!add) {
        fprintf(stderr, "create: Mission Control UI not reachable\n");
        closeMissionControl();
        return 1;
    }
    AXError err = AXUIElementPerformAction(add, kAXPressAction);
    NSDictionary *fresh = nil;
    for (int i = 0; i < 30 && !fresh; i++) {
        settle(0.1);
        for (NSDictionary *s in spaceInfos())
            if (![had containsObject:s[@"uuid"]]) { fresh = s; break; }
    }
    closeMissionControl();
    if (!fresh) { fprintf(stderr, "create: the Dock did not add a space (axerr %d)\n", err); return 1; }
    if (name.length) {
        NSMutableDictionary *map = loadMap();
        map[fresh[@"uuid"]] = name;
        saveMap(map);
        printf("created Desktop %d (space %llu) -> \"%s\"\n", [fresh[@"ord"] intValue],
               [fresh[@"sid"] unsignedLongLongValue], name.UTF8String);
    } else {
        printf("created Desktop %d (space %llu)\n", [fresh[@"ord"] intValue],
               [fresh[@"sid"] unsignedLongLongValue]);
    }
    return 0;
}

static int cmdRemove(NSString *query) {
    if (!axReady("rm")) return 1;
    NSDictionary *s = matchSpace(query);
    if (!s) { fprintf(stderr, "rm: no space matching \"%s\"\n", query.UTF8String); return 1; }
    if ([s[@"type"] intValue] != 0) {
        fprintf(stderr, "rm: %s is a fullscreen app space; leave fullscreen instead\n",
                label(s).UTF8String);
        return 1;
    }
    NSString *ident = s[@"display"];
    NSUInteger total = 0;
    for (NSDictionary *i in spaceInfos()) if ([i[@"display"] isEqualToString:ident]) total++;
    if (desktopsOnDisplay(ident).count < 2) {
        fprintf(stderr, "rm: refusing to remove the last desktop\n");
        return 1;
    }
    AXUIElementRef spaces = mcSpacesGroupFor(ident);
    AXUIElementRef list = spaces ? axFind(spaces, @"mc.spaces.list", 2) : NULL;
    if (!list) {
        fprintf(stderr, "rm: Mission Control UI not reachable\n");
        closeMissionControl();
        return 1;
    }
    NSArray *thumbs = axChildren(list);
    if (thumbs.count != total) {
        fprintf(stderr, "rm: Mission Control shows %lu thumbnails for %lu spaces, not touching it\n",
                (unsigned long)thumbs.count, (unsigned long)total);
        closeMissionControl();
        return 1;
    }
    AXError err = AXUIElementPerformAction(
        (__bridge AXUIElementRef)thumbs[[s[@"ord"] intValue] - 1], CFSTR("AXRemoveDesktop"));
    BOOL gone = NO;
    for (int i = 0; i < 30 && !gone; i++) {
        settle(0.1);
        gone = YES;
        for (NSDictionary *now in spaceInfos())
            if ([now[@"uuid"] isEqual:s[@"uuid"]]) { gone = NO; break; }
    }
    closeMissionControl();
    if (!gone) { fprintf(stderr, "rm: the Dock did not remove it (axerr %d)\n", err); return 1; }
    NSMutableDictionary *map = loadMap();
    if (map[s[@"uuid"]]) { [map removeObjectForKey:s[@"uuid"]]; saveMap(map); }
    printf("removed %s (space %llu)\n", label(s).UTF8String, [s[@"sid"] unsignedLongLongValue]);
    return 0;
}

static NSString *layoutPath(void) {
    return [NSHomeDirectory() stringByAppendingPathComponent:@".config/spacelayout.json"];
}
static int cmdLayoutSave(void) {
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    NSUInteger count = 0, named = 0;
    for (NSDictionary *s in spaceInfos()) {
        if ([s[@"type"] intValue] != 0) continue;
        NSMutableArray *arr = out[s[@"display"]];
        if (!arr) out[s[@"display"]] = arr = [NSMutableArray array];
        [arr addObject:s[@"name"]];
        count++;
        if ([s[@"name"] length]) named++;
    }
    NSData *d = [NSJSONSerialization dataWithJSONObject:out
        options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:nil];
    [d writeToFile:layoutPath() atomically:YES];
    printf("saved %lu desktop%s (%lu named) to ~/.config/spacelayout.json\n",
           (unsigned long)count, count == 1 ? "" : "s", (unsigned long)named);
    return 0;
}
// creates missing desktops and reapplies names by position. Never removes
// spaces: extras are reported and left alone.
static int cmdLayoutRestore(void) {
    NSData *d = [NSData dataWithContentsOfFile:layoutPath()];
    NSDictionary *want = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil;
    if (![want isKindOfClass:[NSDictionary class]] || !want.count) {
        fprintf(stderr, "restore: nothing saved at ~/.config/spacelayout.json"
                        " (run spacename layout save first)\n");
        return 1;
    }
    if (!axReady("restore")) return 1;
    NSUInteger created = 0, named = 0;
    int rc = 0;
    for (NSString *ident in want) {
        NSArray *names = want[ident];
        if (!desktopsOnDisplay(ident).count) {
            fprintf(stderr, "restore: display %s not present, skipped\n", ident.UTF8String);
            rc = 1;
            continue;
        }
        NSInteger need = (NSInteger)names.count - (NSInteger)desktopsOnDisplay(ident).count;
        if (need > 0) {
            AXUIElementRef spaces = mcSpacesGroupFor(ident);
            AXUIElementRef add = spaces ? axFind(spaces, @"mc.spaces.add", 2) : NULL;
            if (!add) {
                fprintf(stderr, "restore: Mission Control UI not reachable\n");
                closeMissionControl();
                return 1;
            }
            for (NSInteger i = 0; i < need; i++) {
                NSUInteger before = desktopsOnDisplay(ident).count;
                AXUIElementPerformAction(add, kAXPressAction);
                int t = 0;
                for (; t < 30 && desktopsOnDisplay(ident).count == before; t++) settle(0.1);
                if (t == 30) {
                    fprintf(stderr, "restore: the Dock stopped adding spaces\n");
                    closeMissionControl();
                    return 1;
                }
                created++;
            }
            closeMissionControl();
        }
        NSArray *desks = desktopsOnDisplay(ident);
        NSMutableDictionary *map = loadMap();
        for (NSUInteger i = 0; i < MIN(names.count, desks.count); i++) {
            if (![names[i] length]) continue;
            map[desks[i][@"uuid"]] = names[i];
            named++;
        }
        saveMap(map);
        if (desks.count > names.count)
            printf("restore: %lu extra desktop%s left alone\n",
                   (unsigned long)(desks.count - names.count),
                   desks.count - names.count == 1 ? "" : "s");
    }
    printf("restored: %lu desktop%s created, %lu name%s applied\n",
           (unsigned long)created, created == 1 ? "" : "s",
           (unsigned long)named, named == 1 ? "" : "s");
    return rc;
}

int main(int argc, char **argv) {
  @autoreleasepool {
    setvbuf(stdout, NULL, _IONBF, 0);
    [NSApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    [NSApp finishLaunching];
    void *h = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY);
    cid = ((ConnFn)dlsym(h, "_CGSDefaultConnection"))();
    mdsF = (MDSFn)dlsym(h, "CGSCopyManagedDisplaySpaces");
    copySpacesF = (CopySpacesFn)dlsym(h, "CGSCopySpacesForWindows");

    NSString *mode = argc > 1 ? [NSString stringWithUTF8String:argv[1]] : @"current";
    NSMutableArray *rest = [NSMutableArray array];
    for (int i = 2; i < argc; i++) [rest addObject:[NSString stringWithUTF8String:argv[i]]];
    NSString *arg = [rest componentsJoinedByString:@" "];

    if ([mode isEqualToString:@"current"]) return cmdCurrent();
    if ([mode isEqualToString:@"list"])    return cmdList();
    if ([mode isEqualToString:@"set"])     return cmdSet(arg);
    if ([mode isEqualToString:@"switch"])  return arg.length ? cmdSwitch(arg) : cmdList();
    if ([mode isEqualToString:@"bring"])   return arg.length ? cmdBring(arg) : 2;
    if ([mode isEqualToString:@"send"])    return arg.length ? cmdSend(arg) : 2;
    if ([mode isEqualToString:@"create"])  return cmdCreate(arg);
    if ([mode isEqualToString:@"rm"])      return arg.length ? cmdRemove(arg) : 2;
    if ([mode isEqualToString:@"layout"]) {
        if ([arg isEqualToString:@"save"])    return cmdLayoutSave();
        if ([arg isEqualToString:@"restore"]) return cmdLayoutRestore();
        fprintf(stderr, "usage: spacetool layout save|restore\n");
        return 2;
    }
    fprintf(stderr, "usage: spacetool current|list|set <name>|switch <query>"
                    "|bring <app>|send <space>|create [name]|rm <space>"
                    "|layout save|restore\n");
    return 2;
  }
}
