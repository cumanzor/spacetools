// spacebadge - per-space corner name badge + mission control name strip
#import <Cocoa/Cocoa.h>
#import <objc/message.h>
#import <dlfcn.h>

typedef int (*ConnFn)(void);
typedef CFArrayRef (*MDSFn)(int);
typedef void (*AddFn)(int, CFArrayRef, CFArrayRef);
typedef void (*RemFn)(int, CFArrayRef, CFArrayRef);
typedef CFArrayRef (*CopySpacesFn)(int, int, CFArrayRef);

static int cid;
static MDSFn mdsF;
static AddFn addF;
static RemFn remF;
static CopySpacesFn copySpacesF;

@interface Badger : NSObject
@property NSMutableDictionary<NSString*, NSWindow*> *badges;   // uuid -> window
@property NSWindow *strip;
@property NSDate *mapMtime;
@property BOOL mcVisible;
@property NSTimer *settle;
@property NSString *stripText;
@end

static NSString *mapPath(void) {
    return [NSHomeDirectory() stringByAppendingPathComponent:@".config/spacenames.json"];
}
static NSDictionary *loadMap(void) {
    NSData *d = [NSData dataWithContentsOfFile:mapPath()];
    if (!d) return @{};
    id o = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
    return [o isKindOfClass:[NSDictionary class]] ? o : @{};
}
static NSArray *spaceList(void) {
    NSMutableArray *out = [NSMutableArray array];
    for (NSDictionary *d in (NSArray *)CFBridgingRelease(mdsF(cid))) {
        int ord = 0;
        for (NSDictionary *s in d[@"Spaces"]) {
            ord++;
            [out addObject:@{ @"sid": s[@"ManagedSpaceID"], @"uuid": s[@"uuid"] ?: @"",
                              @"ord": @(ord), @"type": s[@"type"] ?: @0,
                              @"display": d[@"Display Identifier"] ?: @"Main" }];
        }
    }
    return out;
}

// screens[0] is the menu bar display, which is what CGS calls "Main"
static NSScreen *screenForDisplay(NSString *ident) {
    NSScreen *fallback = [NSScreen screens].firstObject ?: [NSScreen mainScreen];
    if (!ident.length || [ident isEqualToString:@"Main"]) return fallback;
    for (NSScreen *s in [NSScreen screens]) {
        CGDirectDisplayID did = [s.deviceDescription[@"NSScreenNumber"] unsignedIntValue];
        CFUUIDRef u = CGDisplayCreateUUIDFromDisplayID(did);
        if (!u) continue;
        NSString *str = CFBridgingRelease(CFUUIDCreateString(NULL, u));
        CFRelease(u);
        if ([str isEqualToString:ident]) return s;
    }
    return fallback;   // space belongs to a display that is no longer attached
}

// A display change moves our windows behind AppKit's back: the window server
// relocates them but NSWindow.frame keeps reporting the old rect, so -setFrame:
// to that same rect short circuits and the window never comes back. Everything
// positional has to be decided against these numbers, not against .frame.
static NSDictionary<NSNumber *, NSValue *> *serverFrames(void) {
    CGFloat h = ([NSScreen screens].firstObject ?: [NSScreen mainScreen]).frame.size.height;
    int me = getpid();
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    for (NSDictionary *w in (NSArray *)CFBridgingRelease(CGWindowListCopyWindowInfo(
            kCGWindowListOptionAll, kCGNullWindowID))) {
        if ([w[(id)kCGWindowOwnerPID] intValue] != me) continue;
        CGRect b;
        if (!CGRectMakeWithDictionaryRepresentation((CFDictionaryRef)w[(id)kCGWindowBounds], &b)) continue;
        out[w[(id)kCGWindowNumber]] = [NSValue valueWithRect:
            NSMakeRect(b.origin.x, h - b.origin.y - b.size.height, b.size.width, b.size.height)];
    }
    return out;
}

static NSAttributedString *badgeText(NSString *name, CGFloat size) {
    NSShadow *sh = [NSShadow new];
    sh.shadowColor = [[NSColor blackColor] colorWithAlphaComponent:0.65];
    sh.shadowBlurRadius = 6; sh.shadowOffset = NSMakeSize(0, -1);
    return [[NSAttributedString alloc] initWithString:name attributes:@{
        NSFontAttributeName: [NSFont systemFontOfSize:size weight:NSFontWeightHeavy],
        NSForegroundColorAttributeName: [[NSColor whiteColor] colorWithAlphaComponent:0.42],
        NSStrokeColorAttributeName: [[NSColor blackColor] colorWithAlphaComponent:0.35],
        NSStrokeWidthAttributeName: @(-2.0),
        NSShadowAttributeName: sh }];
}


static BOOL mcOpen(void) {
    NSArray *list = CFBridgingRelease(CGWindowListCopyWindowInfo(
        kCGWindowListOptionOnScreenOnly, kCGNullWindowID));
    for (NSDictionary *w in list)
        if ([w[(id)kCGWindowOwnerName] isEqual:@"Dock"] && [w[(id)kCGWindowLayer] intValue] == 18)
            return YES;
    return NO;
}

static CFMachPortRef keyTap;
static BOOL mcArmed;
static int maxOrd;

static void postEscape(void) {
    CGEventRef d = CGEventCreateKeyboardEvent(NULL, 53, true);
    CGEventRef u = CGEventCreateKeyboardEvent(NULL, 53, false);
    if (d) { CGEventPost(kCGSessionEventTap, d); CFRelease(d); }
    if (u) { CGEventPost(kCGSessionEventTap, u); CFRelease(u); }
}

static int digitForKeycode(int64_t kc) {
    static const int codes[9] = { 18, 19, 20, 21, 23, 22, 26, 28, 25 };   // 1..9
    for (int i = 0; i < 9; i++) if (codes[i] == kc) return i + 1;
    return 0;
}

// Mission Control swallows the Dock swipe gesture that `sw` switches with, so
// it has to be gone before the switch, not merely on its way out.
static void switchToOrd(int ord) {
    postEscape();
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        for (int i = 0; i < 40 && mcOpen(); i++) usleep(50000);
        NSTask *t = [NSTask new];
        t.executableURL = [NSURL fileURLWithPath:[NSHomeDirectory()
            stringByAppendingPathComponent:@"Applications/SpaceTool.app/Contents/MacOS/SpaceTool"]];
        t.arguments = @[@"switch", [NSString stringWithFormat:@"%d", ord]];
        [t launchAndReturnError:nil];
    });
}

static CGEventRef tapCallback(CGEventTapProxy proxy, CGEventType type, CGEventRef e, void *ctx) {
    if (type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput) {
        if (keyTap) CGEventTapEnable(keyTap, true);
        return e;
    }
    if (!mcArmed || type != kCGEventKeyDown) return e;
    if (CGEventGetFlags(e) & (kCGEventFlagMaskCommand | kCGEventFlagMaskControl |
                              kCGEventFlagMaskAlternate | kCGEventFlagMaskShift)) return e;
    int d = digitForKeycode(CGEventGetIntegerValueField(e, kCGKeyboardEventKeycode));
    if (!d || d > maxOrd) return e;
    switchToOrd(d);
    return NULL;   // swallow it so the digit does not leak to whatever is behind
}

static void installTap(void) {
    keyTap = CGEventTapCreate(kCGSessionEventTap, kCGHeadInsertEventTap,
        kCGEventTapOptionDefault, CGEventMaskBit(kCGEventKeyDown), tapCallback, NULL);
    if (!keyTap) return;
    CFRunLoopSourceRef src = CFMachPortCreateRunLoopSource(NULL, keyTap, 0);
    CFRunLoopAddSource(CFRunLoopGetMain(), src, kCFRunLoopCommonModes);
    CFRelease(src);
    CGEventTapEnable(keyTap, false);   // only armed while Mission Control is up
}

static void bridgedOp(id op) {
    Class brCls = NSClassFromString(@"SLSWindowManagementFallbackBridge");
    if (!op || !brCls) return;
    id bridge = [[brCls alloc] init];
    void (^blk)(void) = ^{
        ((void(*)(id,SEL,id))objc_msgSend)(bridge,
            sel_registerName("performAsynchronousBridgedWindowManagementOperation:"), op);
    };
    ((void(*)(id,SEL,id))objc_msgSend)(bridge,
        sel_registerName("performWindowManagementBridgeTransactionUsingBlock:"), blk);
}

static void bridgedMoveWindow(uint32_t wid, uint64_t sid) {
    Class opCls = NSClassFromString(@"SLSBridgedMoveWindowsToManagedSpaceOperation");
    if (!opCls) return;
    id (*initFn)(id, SEL, id, uint64_t) = (id(*)(id,SEL,id,uint64_t))objc_msgSend;
    bridgedOp(initFn(((id(*)(id,SEL))objc_msgSend)(opCls, sel_registerName("alloc")),
                     sel_registerName("initWithWindows:spaceID:"), @[@(wid)], sid));
}


@implementation Badger
- (instancetype)init {
    self = [super init];
    _badges = [NSMutableDictionary dictionary];
    return self;
}

- (NSWindow *)makeOverlay:(NSRect)frame {
    NSWindow *w = [[NSWindow alloc] initWithContentRect:frame
        styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
    w.backgroundColor = [NSColor clearColor];
    w.opaque = NO; w.hasShadow = NO; w.ignoresMouseEvents = YES;
    w.level = NSFloatingWindowLevel;
    w.collectionBehavior = NSWindowCollectionBehaviorStationary | NSWindowCollectionBehaviorIgnoresCycle;
    return w;
}

- (void)place:(NSWindow *)w at:(NSRect)frame server:(NSDictionary *)server {
    NSValue *v = server[@(w.windowNumber)];
    if (v && NSEqualRects(v.rectValue, frame)) return;
    [w setFrame:NSOffsetRect(frame, 1, 0) display:NO];   // defeat the no-op short circuit
    [w setFrame:frame display:YES];
}

// a display change can also drop a badge off its space, which reads as the
// badge simply never showing up again
- (void)ensureSpace:(NSWindow *)w sid:(uint64_t)sid {
    if (!copySpacesF) return;
    NSNumber *wid = @(w.windowNumber);
    NSArray *on = CFBridgingRelease(copySpacesF(cid, 7, (__bridge CFArrayRef)@[wid]));
    if (on.count == 1 && [on.firstObject unsignedLongLongValue] == sid) return;
    bridgedMoveWindow(wid.unsignedIntValue, sid);
}

- (void)sync {
    NSDictionary *map = loadMap();
    NSArray *spaces = spaceList();
    NSDictionary *server = serverFrames();
    NSMutableSet *live = [NSMutableSet set];
    for (NSDictionary *s in spaces) {
        if ([s[@"type"] intValue] != 0) continue;          // skip fullscreen spaces
        NSString *uuid = s[@"uuid"];
        NSString *name = map[uuid];
        if (!name.length) continue;
        [live addObject:uuid];
        NSWindow *w = self.badges[uuid];
        NSRect vis = screenForDisplay(s[@"display"]).visibleFrame;
        NSAttributedString *t = badgeText(name, 54);
        NSSize sz = t.size;
        NSRect frame = NSMakeRect(MAX(NSMinX(vis) + 8, NSMaxX(vis) - sz.width - 36),
                                  NSMaxY(vis) - sz.height - 18, sz.width + 8, sz.height + 4);
        if (!w) {
            w = [self makeOverlay:frame];
            NSTextField *l = [NSTextField labelWithAttributedString:t];
            l.frame = ((NSView *)w.contentView).bounds;
            l.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
            [w.contentView addSubview:l];
            [w orderFrontRegardless];
            uint32_t wid = (uint32_t)w.windowNumber;
            uint64_t sid = [s[@"sid"] unsignedLongLongValue];
            // window must settle a runloop turn before space assignment sticks
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)),
                dispatch_get_main_queue(), ^{ bridgedMoveWindow(wid, sid); });
            self.badges[uuid] = w;
        } else {
            NSTextField *l = w.contentView.subviews.firstObject;
            if (![l.attributedStringValue.string isEqualToString:name]) l.attributedStringValue = t;
            [self place:w at:frame server:server];
            [self ensureSpace:w sid:[s[@"sid"] unsignedLongLongValue]];
        }
    }
    for (NSString *uuid in self.badges.allKeys) {
        if (![live containsObject:uuid]) {
            [self.badges[uuid] orderOut:nil];
            [self.badges removeObjectForKey:uuid];
        }
    }
}

- (BOOL)missionControlOpen { return mcOpen(); }

- (void)showStrip {
    NSDictionary *map = loadMap();
    NSMutableArray *parts = [NSMutableArray array];
    for (NSDictionary *s in spaceList()) {
        if ([s[@"type"] intValue] != 0) { [parts addObject:@"▢"]; continue; }
        NSString *name = map[s[@"uuid"]];
        [parts addObject:[NSString stringWithFormat:@"%d %@", [s[@"ord"] intValue],
                          name.length ? name : @"·"]];
    }
    maxOrd = (int)parts.count;
    NSString *text = [parts componentsJoinedByString:@"    "];
    NSAttributedString *t = [[NSAttributedString alloc] initWithString:text attributes:@{
        NSFontAttributeName: [NSFont systemFontOfSize:22 weight:NSFontWeightSemibold],
        NSForegroundColorAttributeName: [NSColor whiteColor] }];
    NSSize sz = t.size;
    sz.width = ceil(sz.width);
    // screens[0] is the menu bar display; mainScreen is key-window relative and
    // this process never has a key window
    NSRect scr = ([NSScreen screens].firstObject ?: [NSScreen mainScreen]).frame;
    NSRect frame = NSMakeRect(MAX(NSMinX(scr) + 8, NSMidX(scr) - sz.width/2 - 22),
                              NSMaxY(scr) - 158 - sz.height, sz.width + 44, sz.height + 20);
    if (!self.strip) {
        self.strip = [self makeOverlay:frame];
        self.strip.collectionBehavior |= NSWindowCollectionBehaviorCanJoinAllSpaces;
        NSView *v = self.strip.contentView;
        v.wantsLayer = YES;
        v.layer.backgroundColor = [[NSColor blackColor] colorWithAlphaComponent:0.6].CGColor;
        v.layer.cornerRadius = 14;
        NSTextField *l = [NSTextField labelWithAttributedString:t];
        [v addSubview:l];
        self.strip.alphaValue = 0;
        [self.strip orderFrontRegardless];   // pre-shown: ordering during MC dismisses it
    }
    NSTextField *l = self.strip.contentView.subviews.firstObject;
    // no unchanged-text early return above: a monitor config change can move or
    // shrink the strip behind AppKit's back, and place: is the only repair path
    if (![text isEqualToString:self.stripText]) {
        self.stripText = text;
        l.attributedStringValue = t;
    }
    [self place:self.strip at:frame server:serverFrames()];
    // size the label off the new bounds by hand. Autoresizing only fires when
    // the window actually changes size, and place: leaves it alone whenever the
    // frame already matches, which is exactly what reordering spaces produces:
    // same glyphs, same width, different text. The 20 inset against a 44 wider
    // window leaves 4pt of slack, because the field's cell wants a shade more
    // than the attributed string reports.
    l.frame = NSInsetRect(((NSView *)self.strip.contentView).bounds, 20, 10);
    self.strip.alphaValue = 1;
}

// a dock/undock fires this repeatedly and visibleFrame keeps moving for a beat
// after the last one, so debounce and then sync again once it has settled
- (void)screensChanged {
    [self.settle invalidate];
    __weak typeof(self) ws = self;
    self.settle = [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:NO block:^(NSTimer *t) {
        [ws sync];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)),
            dispatch_get_main_queue(), ^{ [ws sync]; });
    }];
}

- (void)tick {
    BOOL mc = [self missionControlOpen];
    if (mc) [self showStrip];   // spaces get reordered while it is open, so keep up
    if (mc && !self.mcVisible) {
        for (NSWindow *b in self.badges.allValues) b.alphaValue = 0;
        mcArmed = YES;
        if (keyTap) CGEventTapEnable(keyTap, true);
    }
    if (!mc && self.mcVisible) {
        self.strip.alphaValue = 0;
        for (NSWindow *b in self.badges.allValues) b.alphaValue = 1;
        mcArmed = NO;
        if (keyTap) CGEventTapEnable(keyTap, false);
    }
    self.mcVisible = mc;
}

- (void)maybeResync {
    NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:mapPath() error:nil];
    NSDate *mt = attrs[NSFileModificationDate];
    if (mt && ![mt isEqualToDate:self.mapMtime]) { self.mapMtime = mt; [self sync]; }
}
@end

int main() {
  @autoreleasepool {
    [NSApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    [NSApp finishLaunching];
    void *h = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY);
    cid = ((ConnFn)dlsym(h, "_CGSDefaultConnection"))();
    mdsF = (MDSFn)dlsym(h, "CGSCopyManagedDisplaySpaces");
    addF = (AddFn)dlsym(h, "CGSAddWindowsToSpaces");
    remF = (RemFn)dlsym(h, "CGSRemoveWindowsFromSpaces");
    copySpacesF = (CopySpacesFn)dlsym(h, "CGSCopySpacesForWindows");

    if (!AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)
            @{ (__bridge id)kAXTrustedCheckOptionPrompt: @YES }))
        fprintf(stderr, "spacebadge: no Accessibility grant, "
                        "1-9 switching inside Mission Control is off\n");
    installTap();

    Badger *b = [Badger new];
    [b sync];
    [[[NSWorkspace sharedWorkspace] notificationCenter]
        addObserverForName:NSWorkspaceActiveSpaceDidChangeNotification
        object:nil queue:nil usingBlock:^(NSNotification *n) { [b sync]; }];
    [[NSNotificationCenter defaultCenter]
        addObserverForName:NSApplicationDidChangeScreenParametersNotification
        object:nil queue:nil usingBlock:^(NSNotification *n) { [b screensChanged]; }];
    [NSTimer scheduledTimerWithTimeInterval:0.3 repeats:YES block:^(NSTimer *t) { [b tick]; }];
    [NSTimer scheduledTimerWithTimeInterval:2.0 repeats:YES block:^(NSTimer *t) { [b maybeResync]; }];
    [NSTimer scheduledTimerWithTimeInterval:15.0 repeats:YES block:^(NSTimer *t) { [b sync]; }];
    // NSApp run, not NSRunLoop run: AppKit only refreshes NSScreen and posts
    // DidChangeScreenParameters while it drains its own event queue. Under a bare
    // runloop every screen value stays frozen at whatever the displays looked
    // like when the agent launched, which at login is mid-settle.
    [NSApp run];
  }
  return 0;
}
