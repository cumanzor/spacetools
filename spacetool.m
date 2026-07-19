// spacetool - name, list, switch macOS spaces; bring app windows to current space
// modes: current | list | set <name> | switch <query> | bring <app>
#import <Cocoa/Cocoa.h>
#import <objc/message.h>
#import <dlfcn.h>

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
    for (NSDictionary *s in all) if ([[s[@"name"] lowercaseString] isEqualToString:q]) return s;
    for (NSDictionary *s in all) if ([s[@"name"] length] && [[s[@"name"] lowercaseString] hasPrefix:q]) return s;
    for (NSDictionary *s in all) if ([s[@"name"] length] && [[s[@"name"] lowercaseString] containsString:q]) return s;
    int n = query.intValue;
    if (n > 0) for (NSDictionary *s in all) if ([s[@"ord"] intValue] == n) return s;
    return nil;
}

static void bridgedOp(NSString *clsName, id op) {
    Class brCls = NSClassFromString(@"SLSWindowManagementFallbackBridge");
    id bridge = [[brCls alloc] init];
    void (^blk)(void) = ^{
        ((void(*)(id,SEL,id))objc_msgSend)(bridge,
            sel_registerName("performAsynchronousBridgedWindowManagementOperation:"), op);
    };
    ((void(*)(id,SEL,id))objc_msgSend)(bridge,
        sel_registerName("performWindowManagementBridgeTransactionUsingBlock:"), blk);
    (void)clsName;
}
static int switchToSpace(NSDictionary *s) {
    Class opCls = NSClassFromString(@"SLSBridgedManagedDisplaySetCurrentSpaceOperation");
    if (!opCls) { fprintf(stderr, "spacetool: SkyLight bridge unavailable\n"); return 1; }
    id (*initFn)(id, SEL, id, uint64_t) = (id(*)(id,SEL,id,uint64_t))objc_msgSend;
    id op = initFn(((id(*)(id,SEL))objc_msgSend)(opCls, sel_registerName("alloc")),
                   sel_registerName("initWithDisplayIdentifier:spaceID:"),
                   s[@"display"], [s[@"sid"] unsignedLongLongValue]);
    bridgedOp(nil, op);
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.6]];
    return 0;
}
static void moveWindowsToSpace(NSArray *wids, uint64_t sid) {
    Class opCls = NSClassFromString(@"SLSBridgedMoveWindowsToManagedSpaceOperation");
    id (*initFn)(id, SEL, id, uint64_t) = (id(*)(id,SEL,id,uint64_t))objc_msgSend;
    id op = initFn(((id(*)(id,SEL))objc_msgSend)(opCls, sel_registerName("alloc")),
                   sel_registerName("initWithWindows:spaceID:"), wids, sid);
    bridgedOp(nil, op);
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
    fprintf(stderr, "usage: spacetool current|list|set <name>|switch <query>|bring <app>\n");
    return 2;
  }
}
