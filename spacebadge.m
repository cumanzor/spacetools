// spacebadge - per-space corner name badge + mission control name strip
#import <Cocoa/Cocoa.h>
#import <objc/message.h>
#import <dlfcn.h>

typedef int (*ConnFn)(void);
typedef CFArrayRef (*MDSFn)(int);
typedef void (*AddFn)(int, CFArrayRef, CFArrayRef);
typedef void (*RemFn)(int, CFArrayRef, CFArrayRef);

static int cid;
static MDSFn mdsF;
static AddFn addF;
static RemFn remF;

@interface Badger : NSObject
@property NSMutableDictionary<NSString*, NSWindow*> *badges;   // uuid -> window
@property NSWindow *strip;
@property NSDate *mapMtime;
@property BOOL mcVisible;
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
                              @"ord": @(ord), @"type": s[@"type"] ?: @0 }];
        }
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


static void bridgedMoveWindow(uint32_t wid, uint64_t sid) {
    Class opCls = NSClassFromString(@"SLSBridgedMoveWindowsToManagedSpaceOperation");
    Class brCls = NSClassFromString(@"SLSWindowManagementFallbackBridge");
    if (!opCls || !brCls) return;
    id (*initFn)(id, SEL, id, uint64_t) = (id(*)(id,SEL,id,uint64_t))objc_msgSend;
    id op = initFn(((id(*)(id,SEL))objc_msgSend)(opCls, sel_registerName("alloc")),
                   sel_registerName("initWithWindows:spaceID:"), @[@(wid)], sid);
    id bridge = [[brCls alloc] init];
    void (^blk)(void) = ^{
        ((void(*)(id,SEL,id))objc_msgSend)(bridge,
            sel_registerName("performAsynchronousBridgedWindowManagementOperation:"), op);
    };
    ((void(*)(id,SEL,id))objc_msgSend)(bridge,
        sel_registerName("performWindowManagementBridgeTransactionUsingBlock:"), blk);
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

- (void)sync {
    NSDictionary *map = loadMap();
    NSArray *spaces = spaceList();
    NSRect vis = [NSScreen mainScreen].visibleFrame;
    NSMutableSet *live = [NSMutableSet set];
    for (NSDictionary *s in spaces) {
        if ([s[@"type"] intValue] != 0) continue;          // skip fullscreen spaces
        NSString *uuid = s[@"uuid"];
        NSString *name = map[uuid];
        if (!name.length) continue;
        [live addObject:uuid];
        NSWindow *w = self.badges[uuid];
        NSAttributedString *t = badgeText(name, 54);
        NSSize sz = t.size;
        NSRect frame = NSMakeRect(NSMaxX(vis) - sz.width - 36,
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
            if (![l.attributedStringValue.string isEqualToString:name]) {
                l.attributedStringValue = t;
                [w setFrame:frame display:YES];
            }
        }
    }
    for (NSString *uuid in self.badges.allKeys) {
        if (![live containsObject:uuid]) {
            [self.badges[uuid] orderOut:nil];
            [self.badges removeObjectForKey:uuid];
        }
    }
}

- (BOOL)missionControlOpen {
    NSArray *list = CFBridgingRelease(CGWindowListCopyWindowInfo(
        kCGWindowListOptionOnScreenOnly, kCGNullWindowID));
    for (NSDictionary *w in list)
        if ([w[(id)kCGWindowOwnerName] isEqual:@"Dock"] && [w[(id)kCGWindowLayer] intValue] == 18)
            return YES;
    return NO;
}

- (void)showStrip {
    NSDictionary *map = loadMap();
    NSMutableArray *parts = [NSMutableArray array];
    for (NSDictionary *s in spaceList()) {
        if ([s[@"type"] intValue] != 0) { [parts addObject:@"▢"]; continue; }
        NSString *name = map[s[@"uuid"]];
        [parts addObject:[NSString stringWithFormat:@"%d %@", [s[@"ord"] intValue],
                          name.length ? name : @"·"]];
    }
    NSString *text = [parts componentsJoinedByString:@"    "];
    NSAttributedString *t = [[NSAttributedString alloc] initWithString:text attributes:@{
        NSFontAttributeName: [NSFont systemFontOfSize:22 weight:NSFontWeightSemibold],
        NSForegroundColorAttributeName: [NSColor whiteColor] }];
    NSSize sz = t.size;
    NSRect scr = [NSScreen mainScreen].frame;
    NSRect frame = NSMakeRect(NSMidX(scr) - sz.width/2 - 22,
                              NSMaxY(scr) - 158 - sz.height, sz.width + 44, sz.height + 20);
    if (!self.strip) {
        self.strip = [self makeOverlay:frame];
        self.strip.collectionBehavior |= NSWindowCollectionBehaviorCanJoinAllSpaces;
        NSView *v = self.strip.contentView;
        v.wantsLayer = YES;
        v.layer.backgroundColor = [[NSColor blackColor] colorWithAlphaComponent:0.6].CGColor;
        v.layer.cornerRadius = 14;
        NSTextField *l = [NSTextField labelWithAttributedString:t];
        l.frame = NSInsetRect(v.bounds, 22, 10);
        l.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        [v addSubview:l];
        self.strip.alphaValue = 0;
        [self.strip orderFrontRegardless];   // pre-shown: ordering during MC dismisses it
    }
    ((NSTextField *)self.strip.contentView.subviews.firstObject).attributedStringValue = t;
    [self.strip setFrame:frame display:YES];
    self.strip.alphaValue = 1;
}

- (void)tick {
    BOOL mc = [self missionControlOpen];
    if (mc && !self.mcVisible) {
        [self showStrip];
        for (NSWindow *b in self.badges.allValues) b.alphaValue = 0;
    }
    if (!mc && self.mcVisible) {
        self.strip.alphaValue = 0;
        for (NSWindow *b in self.badges.allValues) b.alphaValue = 1;
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

    Badger *b = [Badger new];
    [b sync];
    [[[NSWorkspace sharedWorkspace] notificationCenter]
        addObserverForName:NSWorkspaceActiveSpaceDidChangeNotification
        object:nil queue:nil usingBlock:^(NSNotification *n) { [b sync]; }];
    [NSTimer scheduledTimerWithTimeInterval:0.3 repeats:YES block:^(NSTimer *t) { [b tick]; }];
    [NSTimer scheduledTimerWithTimeInterval:2.0 repeats:YES block:^(NSTimer *t) { [b maybeResync]; }];
    [NSTimer scheduledTimerWithTimeInterval:15.0 repeats:YES block:^(NSTimer *t) { [b sync]; }];
    [[NSRunLoop currentRunLoop] run];
  }
  return 0;
}
