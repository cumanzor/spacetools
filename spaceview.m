// spaceview - resident space switcher: panel with a preview per space, 1-9 to switch
// modes: (none) run the agent | --bench [passes] | --probe-sharing | --request-access
#import <Cocoa/Cocoa.h>
#import <QuartzCore/QuartzCore.h>
#import <dlfcn.h>
#import <os/log.h>
#import <mach/mach.h>
#import <sys/socket.h>
#import <sys/un.h>
#import <sys/file.h>
#import <stdatomic.h>

typedef int (*ConnFn)(void);
typedef CFArrayRef (*MDSFn)(int);
typedef CFArrayRef (*CaptureSpaceFn)(int, uint64_t, uint32_t);

static int cid;
static MDSFn mdsF;
static CaptureSpaceFn captureF;

static NSString *const kToggle = @"dev.umanzor.spaceview.toggle";
static const CGFloat kPreviewW = 960, kPreviewH = 540;
static const NSWindowCollectionBehavior kPanelBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces |
    NSWindowCollectionBehaviorFullScreenAuxiliary | NSWindowCollectionBehaviorStationary |
    NSWindowCollectionBehaviorIgnoresCycle;

#define LOG(fmt, ...) os_log(OS_LOG_DEFAULT, "[spaceview] " fmt, ##__VA_ARGS__)

static NSDictionary *loadNames(void) {
    NSData *d = [NSData dataWithContentsOfFile:[NSHomeDirectory()
        stringByAppendingPathComponent:@".config/spacenames.json"]];
    if (!d) return @{};
    id o = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
    return [o isKindOfClass:[NSDictionary class]] ? o : @{};
}

// ord counts every space on the display, fullscreen ones included, so a digit
// lands where `sw N` does
static NSArray *displaySpaces(void) {
    NSMutableArray *out = [NSMutableArray array];
    NSDictionary *names = loadNames();
    for (NSDictionary *d in (NSArray *)CFBridgingRelease(mdsF(cid))) {
        uint64_t cur = [d[@"Current Space"][@"ManagedSpaceID"] unsignedLongLongValue];
        NSMutableArray *spaces = [NSMutableArray array];
        int ord = 0;
        for (NSDictionary *s in d[@"Spaces"]) {
            ord++;
            uint64_t sid = [s[@"ManagedSpaceID"] unsignedLongLongValue];
            id name = names[s[@"uuid"] ?: @""];
            [spaces addObject:@{ @"sid": @(sid), @"uuid": s[@"uuid"] ?: @"", @"ord": @(ord),
                @"name": [name isKindOfClass:[NSString class]] ? name : @"",
                @"type": s[@"type"] ?: @0, @"current": @(sid == cur) }];
        }
        [out addObject:@{ @"display": d[@"Display Identifier"] ?: @"Main",
                          @"current": @(cur), @"spaces": spaces }];
    }
    return out;
}

static NSString *uuidForScreen(NSScreen *s) {
    CGDirectDisplayID did = [s.deviceDescription[@"NSScreenNumber"] unsignedIntValue];
    CFUUIDRef u = CGDisplayCreateUUIDFromDisplayID(did);
    if (!u) return nil;
    NSString *str = CFBridgingRelease(CFUUIDCreateString(NULL, u));
    CFRelease(u);
    return str;
}

// with "displays have separate spaces" off there is one group, "Main", for all screens
static NSDictionary *groupForScreen(NSArray *groups, NSScreen *screen) {
    if (groups.count == 1) return groups[0];
    NSString *u = uuidForScreen(screen);
    for (NSDictionary *g in groups) if ([g[@"display"] isEqualToString:u]) return g;
    BOOL menuBarScreen = screen == [NSScreen screens].firstObject;
    for (NSDictionary *g in groups)
        if (menuBarScreen && [g[@"display"] isEqualToString:@"Main"]) return g;
    return groups.firstObject;
}

static NSScreen *screenUnderMouse(void) {
    NSPoint p = [NSEvent mouseLocation];
    for (NSScreen *s in [NSScreen screens]) if (NSMouseInRect(p, s.frame, NO)) return s;
    return [NSScreen screens].firstObject ?: [NSScreen mainScreen];
}

static uint64_t nowNs(void) { return clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW); }

static uint64_t physFootprint(void) {
    task_vm_info_data_t info;
    mach_msg_type_number_t n = TASK_VM_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &n) != KERN_SUCCESS) return 0;
    return info.phys_footprint;
}

// returns +1. The full-res capture (~48MB at 4608x2592) dies inside the pool;
// only the downscaled bitmap leaves this function
static CGImageRef captureSpaceScaled(uint64_t sid, double *ms) {
    CGImageRef out = NULL;
    uint64_t t0 = nowNs();
    @autoreleasepool {
        CFArrayRef imgs = captureF ? captureF(cid, sid, 0) : NULL;
        if (imgs && CFArrayGetCount(imgs)) {
            CGImageRef full = (CGImageRef)CFArrayGetValueAtIndex(imgs, 0);
            size_t w = CGImageGetWidth(full), h = CGImageGetHeight(full);
            double k = fmin(kPreviewW / w, kPreviewH / h);
            size_t sw = MAX(1, (size_t)lround(w * k)), sh = MAX(1, (size_t)lround(h * k));
            CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
            CGContextRef ctx = CGBitmapContextCreate(NULL, sw, sh, 8, 0, cs,
                kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
            CGColorSpaceRelease(cs);
            if (ctx) {
                CGContextSetInterpolationQuality(ctx, kCGInterpolationMedium);
                CGContextDrawImage(ctx, CGRectMake(0, 0, sw, sh), full);
                out = CGBitmapContextCreateImage(ctx);
                CGContextRelease(ctx);
            }
        }
        if (imgs) CFRelease(imgs);
    }
    if (ms) *ms = (nowNs() - t0) / 1e6;
    return out;
}

// --- scripting addition client (protocol in spacetool.m) ---
enum { OP_HELLO = 1, OP_SPACE_FOCUS_INSTANT = 10 };
enum { SPACEC_TIMEOUT = -5 };

static int saConnect(void) {
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    // the payload answers in under 5ms; never hang the switch queue on a wedged Dock
    struct timeval tv = { .tv_sec = 1, .tv_usec = 500000 };
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
    struct sockaddr_un a;
    memset(&a, 0, sizeof a);
    a.sun_family = AF_UNIX;
    snprintf(a.sun_path, sizeof a.sun_path, "/tmp/spacetool-sa_%s.socket", getenv("USER") ?: "unknown");
    if (connect(fd, (struct sockaddr *)&a, sizeof a) < 0) { close(fd); return -1; }
    return fd;
}
static BOOL saReadN(int fd, void *buf, size_t n) {
    uint8_t *p = buf;
    while (n) { ssize_t r = read(fd, p, n); if (r <= 0) return NO; p += r; n -= r; }
    return YES;
}
static BOOL saWriteN(int fd, const void *buf, size_t n) {
    const uint8_t *p = buf;
    while (n) { ssize_t w = write(fd, p, n); if (w <= 0) return NO; p += w; n -= w; }
    return YES;
}
static BOOL saHello(int32_t *version, uint32_t *mask) {
    int fd = saConnect();
    if (fd < 0) return NO;
    uint8_t op = OP_HELLO, rep[5];
    BOOL ok = saWriteN(fd, &op, 1) && saReadN(fd, rep, sizeof rep);
    close(fd);
    if (!ok) return NO;
    *version = rep[0];
    memcpy(mask, rep + 1, 4);
    return YES;
}

static BOOL mcOpen(void) {
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
static void postEscape(void) {
    CGEventRef d = CGEventCreateKeyboardEvent(NULL, 53, true);
    CGEventRef u = CGEventCreateKeyboardEvent(NULL, 53, false);
    if (d) { CGEventPost(kCGSessionEventTap, d); CFRelease(d); }
    if (u) { CGEventPost(kCGSessionEventTap, u); CFRelease(u); }
}
// mission control drops a switch issued while it is up, and ordering our panel
// front dismisses it mid-animation, so close it and wait for it to be gone
static void closeMissionControlBlocking(void) {
    if (!mcOpen()) return;
    postEscape();
    for (int i = 0; i < 40 && mcOpen(); i++) usleep(50000);
}

static BOOL spaceIsCurrent(uint64_t sid) {
    for (NSDictionary *g in (NSArray *)CFBridgingRelease(mdsF(cid)))
        if ([g[@"Current Space"][@"ManagedSpaceID"] unsignedLongLongValue] == sid) return YES;
    return NO;
}

// same lock as `sw`, so a digit here and a hotkey sw cannot interleave
static int lockSwitch(void) {
    NSString *lock = [NSString stringWithFormat:@"/tmp/spacetool-switch_%s.lock", getenv("USER") ?: "unknown"];
    int lfd = open(lock.fileSystemRepresentation, O_CREAT | O_RDWR, 0600);
    if (lfd >= 0) flock(lfd, LOCK_EX);
    return lfd;
}

// blocking: run on switchQ only
static void switchToSpace(uint64_t sid, int ord) {
    int lfd = lockSwitch();
    closeMissionControlBlocking();
    int32_t version = 0;
    uint32_t mask = 0;
    NSString *why = nil;
    if (!saHello(&version, &mask)) why = @"scripting addition not loaded";
    else if (version < 7) why = [NSString stringWithFormat:@"payload is v%d, needs v7", version];
    else if (!(mask & 32)) why = @"payload did not resolve SLSShowSpaces/HideSpaces/SetCurrentSpace";
    if (!why) {
        int fd = saConnect();
        uint8_t msg[9] = { OP_SPACE_FOCUS_INSTANT }, rep[12];
        memcpy(msg + 1, &sid, 8);
        uint64_t t0 = nowNs();
        BOOL sent = fd >= 0 && saWriteN(fd, msg, sizeof msg);
        BOOL io = sent && saReadN(fd, rep, sizeof rep);
        if (fd >= 0) close(fd);
        int32_t err = 0;
        if (io) memcpy(&err, rep, 4);
        if (!sent) why = @"payload went away";
        else if (io && err && err != SPACEC_TIMEOUT) why = [NSString stringWithFormat:@"instant switch refused (payload error %d)", err];
        else {
            // a main-queue timeout may still land late, so wait on CGS either way
            for (int i = 0; i < 100; i++) {
                if (spaceIsCurrent(sid)) {
                    LOG("switched to %d in %.1fms", ord, (nowNs() - t0) / 1e6);
                    if (lfd >= 0) close(lfd);
                    return;
                }
                usleep(10000);
            }
            // the Dock may still apply it; a fallback now would switch twice
            LOG("switch to %d unconfirmed: %{public}s", ord, !io ? "no reply from the payload"
                : err == SPACEC_TIMEOUT ? "Dock main queue timed out" : "Dock accepted but CGS never got there");
            if (lfd >= 0) close(lfd);
            return;
        }
    }
    // sw's animated Dock switch, then its swipe; never the bridged set-current,
    // which moves the window server without the Dock
    static NSMutableSet *logged;
    if (!logged) logged = [NSMutableSet set];
    if (![logged containsObject:why]) {
        [logged addObject:why];
        LOG("instant switch unavailable (%{public}s), using SpaceTool switch", why.UTF8String);
    }
    if (lfd >= 0) close(lfd);   // sw takes the same lock
    NSTask *t = [NSTask new];
    t.executableURL = [NSURL fileURLWithPath:[NSHomeDirectory()
        stringByAppendingPathComponent:@"Applications/SpaceTool.app/Contents/MacOS/SpaceTool"]];
    t.arguments = @[@"switch", [NSString stringWithFormat:@"%d", ord]];
    NSError *err = nil;
    if (![t launchAndReturnError:&err]) LOG("SpaceTool switch failed to launch: %{public}@", err);
}

// --- panel ---
@interface FlippedView : NSView
@end
@implementation FlippedView
- (BOOL)isFlipped { return YES; }
@end

@interface Cell : NSObject
@property NSView *view;
@property CALayer *preview;
@property NSTextField *label;
@end
@implementation Cell
@end

@interface Viewer : NSObject
@property NSPanel *panel;
@property NSScrollView *sidebar;
@property FlippedView *list;
@property NSMutableArray<Cell *> *cells;
@property NSArray *shown;                 // spaces of the panel's display, sidebar order
@property NSString *shownKey;             // sid/ord/name signature the cells were built from
@property NSMutableDictionary<NSNumber *, id> *previews;   // sid -> CGImage
@property NSMutableDictionary<NSString *, NSNumber *> *lastCurrent;   // display -> sid
@property NSMutableSet<NSNumber *> *pending;   // sids queued on captureQ, main-thread only
@property BOOL screensMoved;
@end

static Viewer *viewer;
static CFMachPortRef keyTap;
static atomic_bool panelVisible;
static BOOL fired;   // one switch per show: a second digit would race the first
static dispatch_queue_t captureQ, switchQ;
static CGWindowID panelWid;

static BOOL panelOnScreen(void) {
    if (!panelWid) return NO;
    NSArray *list = CFBridgingRelease(CGWindowListCopyWindowInfo(
        kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements, kCGNullWindowID));
    for (NSDictionary *w in list) if ([w[(id)kCGWindowNumber] unsignedIntValue] == panelWid) return YES;
    return NO;
}

static int digitForKeycode(int64_t kc) {
    static const int codes[9] = { 18, 19, 20, 21, 23, 22, 26, 28, 25 };   // 1..9
    for (int i = 0; i < 9; i++) if (codes[i] == kc) return i + 1;
    return 0;
}

static CGEventRef tapCallback(CGEventTapProxy proxy, CGEventType type, CGEventRef e, void *ctx);

@implementation Viewer

- (instancetype)init {
    if (!(self = [super init])) return nil;
    _cells = [NSMutableArray array];
    _previews = [NSMutableDictionary dictionary];
    _lastCurrent = [NSMutableDictionary dictionary];
    _pending = [NSMutableSet set];
    [self buildPanel];
    return self;
}

- (void)buildPanel {
    NSPanel *p = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 1200, 700)
        styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel
        backing:NSBackingStoreBuffered defer:NO];
    p.level = NSPopUpMenuWindowLevel;
    p.collectionBehavior = kPanelBehavior;
    p.opaque = NO;
    p.backgroundColor = NSColor.clearColor;
    p.hasShadow = YES;
    p.hidesOnDeactivate = NO;
    p.releasedWhenClosed = NO;

    NSVisualEffectView *bg = [[NSVisualEffectView alloc] initWithFrame:p.contentView.bounds];
    bg.material = NSVisualEffectMaterialHUDWindow;
    bg.state = NSVisualEffectStateActive;
    bg.blendingMode = NSVisualEffectBlendingModeBehindWindow;
    bg.wantsLayer = YES;
    bg.layer.cornerRadius = 14;
    bg.layer.masksToBounds = YES;
    bg.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    p.contentView = bg;

    NSScrollView *sv = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    sv.hasVerticalScroller = YES;
    sv.autohidesScrollers = YES;
    sv.drawsBackground = NO;
    sv.borderType = NSNoBorder;
    _list = [[FlippedView alloc] initWithFrame:NSZeroRect];
    sv.documentView = _list;
    [bg addSubview:sv];
    _sidebar = sv;
    // right pane stays empty until the window layout lands
    _panel = p;
    panelWid = (CGWindowID)p.windowNumber;
}

static const CGFloat kSidebarW = 300, kPad = 14, kLabelH = 20;

- (CGFloat)thumbHeight {
    NSSize s = (self.panel.screen ?: [NSScreen screens].firstObject).frame.size;
    return round((kSidebarW - 2 * kPad) * s.height / MAX(1, s.width));
}

- (void)layoutForScreen:(NSScreen *)screen {
    NSRect sf = screen.visibleFrame;
    NSRect r = NSInsetRect(sf, sf.size.width * 0.15, sf.size.height * 0.12);
    r = NSIntegralRect(r);
    // after a display change NSWindow.frame keeps the pre-change rect, so a
    // setFrame: to that same rect is a no-op; force the move through an offset
    if (self.screensMoved) {
        [self.panel setFrame:NSOffsetRect(r, 1, 1) display:NO];
        self.screensMoved = NO;
    }
    [self.panel setFrame:r display:NO];
    self.sidebar.frame = NSMakeRect(0, 0, kSidebarW, r.size.height);
}

- (void)rebuildCellsIfNeeded:(NSArray *)spaces {
    NSMutableString *key = [NSMutableString string];
    for (NSDictionary *s in spaces) [key appendFormat:@"%@:%@:%@|", s[@"sid"], s[@"ord"], s[@"name"]];
    CGFloat th = [self thumbHeight];
    [key appendFormat:@"h%.0f", th];
    if ([key isEqualToString:self.shownKey]) return;
    self.shownKey = key;
    for (Cell *c in self.cells) [c.view removeFromSuperview];
    [self.cells removeAllObjects];
    CGFloat y = kPad, w = kSidebarW - 2 * kPad;
    for (NSDictionary *s in spaces) {
        Cell *c = [Cell new];
        c.view = [[NSView alloc] initWithFrame:NSMakeRect(kPad, y, w, th + kLabelH + 6)];
        c.view.wantsLayer = YES;
        CALayer *pv = [CALayer layer];
        pv.frame = CGRectMake(0, kLabelH + 6, w, th);   // layer coords are unflipped
        pv.contentsGravity = kCAGravityResizeAspect;
        pv.backgroundColor = [NSColor colorWithWhite:0 alpha:0.35].CGColor;
        pv.cornerRadius = 6;
        pv.masksToBounds = YES;
        pv.borderColor = NSColor.controlAccentColor.CGColor;
        [c.view.layer addSublayer:pv];
        c.preview = pv;
        NSString *name = [s[@"name"] length] ? s[@"name"] : [NSString stringWithFormat:@"Desktop %@", s[@"ord"]];
        NSTextField *l = [NSTextField labelWithString:[NSString stringWithFormat:@"%@  %@", s[@"ord"], name]];
        l.font = [NSFont systemFontOfSize:13 weight:NSFontWeightMedium];
        l.textColor = NSColor.labelColor;
        l.lineBreakMode = NSLineBreakByTruncatingTail;
        // explicit frame: autoresizing never refits a same-width string swap
        l.frame = NSMakeRect(2, 0, w - 4, kLabelH);
        [c.view addSubview:l];
        c.label = l;
        [self.list addSubview:c.view];
        [self.cells addObject:c];
        y += th + kLabelH + 6 + kPad;
    }
    self.list.frame = NSMakeRect(0, 0, kSidebarW, y);
}

- (void)refreshCellContents {
    for (NSUInteger i = 0; i < self.cells.count; i++) {
        NSDictionary *s = self.shown[i];
        Cell *c = self.cells[i];
        c.preview.contents = self.previews[s[@"sid"]];
        c.preview.borderWidth = [s[@"current"] boolValue] ? 2 : 0;
    }
}

- (void)storePreview:(CGImageRef)img sid:(uint64_t)sid {
    if (!img) return;
    self.previews[@(sid)] = (__bridge id)img;
    if (self.panel.visible) [self refreshCellContents];
}

// safe while the panel is up: SLSHWCaptureSpace leaves out all-spaces windows
// (measured with --probe-sharing), which also means stuck windows are missing
- (void)captureSid:(uint64_t)sid {
    // rapid toggles would otherwise stack 60-130ms captures of the same space
    if ([self.pending containsObject:@(sid)]) return;
    [self.pending addObject:@(sid)];
    dispatch_async(captureQ, ^{
        double ms = 0;
        CGImageRef img = captureSpaceScaled(sid, &ms);
        LOG("captured %llu in %.1fms", sid, ms);
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.pending removeObject:@(sid)];
            [self storePreview:img sid:sid];
            if (img) CGImageRelease(img);
        });
    });
}

- (void)captureAll {
    for (NSDictionary *g in displaySpaces())
        for (NSDictionary *s in g[@"spaces"])
            if ([s[@"type"] intValue] == 0) [self captureSid:[s[@"sid"] unsignedLongLongValue]];
}

- (void)captureCurrent {
    for (NSDictionary *g in displaySpaces()) [self captureSid:[g[@"current"] unsignedLongLongValue]];
}

- (void)forgetGoneSpaces:(NSArray *)groups {
    NSMutableSet *live = [NSMutableSet set];
    for (NSDictionary *g in groups) for (NSDictionary *s in g[@"spaces"]) [live addObject:s[@"sid"]];
    for (NSNumber *k in self.previews.allKeys) if (![live containsObject:k]) [self.previews removeObjectForKey:k];
}

- (void)spaceChanged {
    [self hide];
    NSArray *groups = displaySpaces();
    [self forgetGoneSpaces:groups];
    for (NSDictionary *g in groups) {
        NSNumber *prev = self.lastCurrent[g[@"display"]];
        if (prev && ![prev isEqual:g[@"current"]]) [self captureSid:prev.unsignedLongLongValue];
        self.lastCurrent[g[@"display"]] = g[@"current"];
    }
}

// no mission control check here: the window list read costs 2-10ms of a
// one-frame budget. On macOS 27 the panel orders in above MC without
// dismissing it, and a digit closes MC before switching
- (void)toggle:(uint64_t)sentNs {
    uint64_t t0 = nowNs();
    if (self.panel.visible) { [self hide]; return; }
    [self show:sentNs received:t0];
}

- (NSDictionary *)prepareForScreen:(NSScreen *)screen {
    NSArray *groups = displaySpaces();
    NSDictionary *g = groups.count ? groupForScreen(groups, screen) : nil;
    NSMutableArray *spaces = [NSMutableArray array];
    for (NSDictionary *s in g[@"spaces"]) if ([s[@"type"] intValue] == 0) [spaces addObject:s];
    self.shown = spaces;
    [self layoutForScreen:screen];
    [self rebuildCellsIfNeeded:spaces];
    [self refreshCellContents];
    return g;
}

// the first orderFront otherwise pays for view, layer and backing setup (~65ms)
- (void)prewarm {
    [self prepareForScreen:screenUnderMouse()];
    [self.panel.contentView layoutSubtreeIfNeeded];
    self.panel.alphaValue = 0;
    [self.panel orderFrontRegardless];
    [self.panel displayIfNeeded];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 300 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        if (!atomic_load(&panelVisible)) [self.panel orderOut:nil];
        self.panel.alphaValue = 1;
    });
}

- (void)show:(uint64_t)sentNs received:(uint64_t)t0 {
    NSDictionary *g = [self prepareForScreen:screenUnderMouse()];
    uint64_t tPrep = nowNs();
    fired = NO;
    atomic_store(&panelVisible, true);
    __block uint64_t tOrder = 0;
    [CATransaction begin];
    [CATransaction setCompletionBlock:^{
        LOG("open: ipc %.1fms, prep %.1fms, order %.1fms, committed %.1fms", sentNs ? (t0 - sentNs) / 1e6 : -1.0,
            (tPrep - t0) / 1e6, (tOrder - tPrep) / 1e6, (nowNs() - t0) / 1e6);
    }];
    [self.panel orderFrontRegardless];
    tOrder = nowNs();
    [CATransaction commit];
    if (keyTap) CGEventTapEnable(keyTap, true);
    // cached shot goes up first; the fresh one replaces it ~100ms later
    if (g) [self captureSid:[g[@"current"] unsignedLongLongValue]];
    // a space created since launch has never been left, so nothing captured it
    for (NSDictionary *s in self.shown)
        if (!self.previews[s[@"sid"]]) [self captureSid:[s[@"sid"] unsignedLongLongValue]];
}

- (void)hide {
    if (keyTap) CGEventTapEnable(keyTap, false);
    atomic_store(&panelVisible, false);
    [self.panel orderOut:nil];
}

- (void)switchToOrd:(int)ord {
    NSDictionary *target = nil;
    for (NSDictionary *s in self.shown) if ([s[@"ord"] intValue] == ord) target = s;
    [self hide];
    if (!target || [target[@"current"] boolValue]) return;
    uint64_t sid = [target[@"sid"] unsignedLongLongValue];
    dispatch_async(switchQ, ^{ switchToSpace(sid, ord); });
}

- (BOOL)hasOrd:(int)ord {
    for (NSDictionary *s in self.shown) if ([s[@"ord"] intValue] == ord) return YES;
    return NO;
}
@end

// runs on the main runloop: keep it to a lookup and a dispatch
static CGEventRef tapCallback(CGEventTapProxy proxy, CGEventType type, CGEventRef e, void *ctx) {
    if (type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput) {
        if (keyTap && atomic_load(&panelVisible)) CGEventTapEnable(keyTap, true);
        return e;
    }
    if (!atomic_load(&panelVisible) || type != kCGEventKeyDown) return e;
    if (CGEventGetFlags(e) & (kCGEventFlagMaskCommand | kCGEventFlagMaskControl |
                              kCGEventFlagMaskAlternate | kCGEventFlagMaskShift)) return e;
    int64_t kc = CGEventGetIntegerValueField(e, kCGKeyboardEventKeycode);
    BOOL repeat = CGEventGetIntegerValueField(e, kCGKeyboardEventAutorepeat) != 0;
    if (kc == 53) {
        if (!repeat) dispatch_async(dispatch_get_main_queue(), ^{ [viewer hide]; });
        return NULL;
    }
    int d = digitForKeycode(kc);
    if (!d || ![viewer hasOrd:d]) return e;
    if (fired || repeat) return NULL;
    fired = YES;
    dispatch_async(dispatch_get_main_queue(), ^{ [viewer switchToOrd:d]; });
    return NULL;
}

static void installTap(void) {
    keyTap = CGEventTapCreate(kCGSessionEventTap, kCGHeadInsertEventTap,
        kCGEventTapOptionDefault, CGEventMaskBit(kCGEventKeyDown), tapCallback, NULL);
    if (!keyTap) return;
    CFRunLoopSourceRef src = CFMachPortCreateRunLoopSource(NULL, keyTap, 0);
    CFRunLoopAddSource(CFRunLoopGetMain(), src, kCFRunLoopCommonModes);
    CFRelease(src);
    CGEventTapEnable(keyTap, false);   // armed only while the panel is up
}

// --- diagnostics ---
// captures are IOSurface-backed and not charged to phys_footprint, so a leaked
// one only shows up as a region count
static int iosurfaceRegions(void) {
    NSTask *t = [NSTask new];
    t.executableURL = [NSURL fileURLWithPath:@"/usr/bin/footprint"];
    t.arguments = @[@"-p", [NSString stringWithFormat:@"%d", getpid()]];
    NSPipe *pipe = [NSPipe pipe];
    t.standardOutput = pipe;
    t.standardError = [NSFileHandle fileHandleWithNullDevice];
    if (![t launchAndReturnError:nil]) return -1;
    NSData *d = [pipe.fileHandleForReading readDataToEndOfFile];
    [t waitUntilExit];
    int regions = 0;
    for (NSString *line in [[[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding]
            componentsSeparatedByString:@"\n"]) {
        if (![line containsString:@"IOSurface"]) continue;
        NSArray *f = [[line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet]
            componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        f = [f filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"length > 0"]];
        // Dirty, Clean, Reclaimable as value+unit pairs, then Regions
        if (f.count > 6) regions += [f[6] intValue];
    }
    return regions;
}
static int cmdBench(int passes) {
    if (!CGPreflightScreenCaptureAccess()) { fprintf(stderr, "spaceview: no Screen Recording grant\n"); return 1; }
    printf("footprint start %.1fMB, iosurface regions %d\n", physFootprint() / 1048576.0, iosurfaceRegions());
    NSMutableDictionary *keep = [NSMutableDictionary dictionary];
    for (int p = 1; p <= passes; p++) @autoreleasepool {
        double total = 0;
        int n = 0;
        for (NSDictionary *g in displaySpaces())
            for (NSDictionary *s in g[@"spaces"]) {
                if ([s[@"type"] intValue] != 0) continue;
                double ms = 0;
                CGImageRef img = captureSpaceScaled([s[@"sid"] unsignedLongLongValue], &ms);
                total += ms;
                n++;
                if (p == 1) printf("  space %d sid=%llu %zux%zu %.1fms%s\n", [s[@"ord"] intValue], [s[@"sid"] unsignedLongLongValue],
                    img ? CGImageGetWidth(img) : 0, img ? CGImageGetHeight(img) : 0, ms, img ? "" : " (no image)");
                if (img) keep[s[@"sid"]] = CFBridgingRelease(img);
            }
        size_t bytes = 0;
        for (id im in keep.allValues) bytes += CGImageGetBytesPerRow((__bridge CGImageRef)im) * CGImageGetHeight((__bridge CGImageRef)im);
        printf("pass %d: %d captures %.0fms, cache %.1fMB, footprint %.1fMB, iosurface regions %d\n",
               p, n, total, bytes / 1048576.0, physFootprint() / 1048576.0, iosurfaceRegions());
    }
    return 0;
}

// counts panel-colored pixels in a capture of the current space, with the panel
// up as sharingType none and then readOnly
static int cmdProbeSharing(void) {
    if (!CGPreflightScreenCaptureAccess()) { fprintf(stderr, "spaceview: no Screen Recording grant\n"); return 1; }
    NSScreen *screen = [NSScreen screens].firstObject;
    NSRect r = NSInsetRect(screen.frame, screen.frame.size.width * 0.3, screen.frame.size.height * 0.3);
    NSPanel *p = [[NSPanel alloc] initWithContentRect:r
        styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel
        backing:NSBackingStoreBuffered defer:NO];
    p.level = NSPopUpMenuWindowLevel;
    p.collectionBehavior = kPanelBehavior;
    p.backgroundColor = [NSColor colorWithSRGBRed:1 green:0 blue:1 alpha:1];
    uint64_t sid = 0;
    for (NSDictionary *g in displaySpaces()) { sid = [g[@"current"] unsignedLongLongValue]; break; }
    double frac[3] = { 0 };
    panelWid = (CGWindowID)p.windowNumber;
    for (int i = 0; i < 3; i++) {
        p.sharingType = i == 0 ? NSWindowSharingNone : NSWindowSharingReadOnly;
        // control: an ordinary single-space window, to prove the probe can see one at all
        if (i == 2) p.collectionBehavior = NSWindowCollectionBehaviorDefault;
        [p orderFrontRegardless];
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.4]];
        BOOL on = panelOnScreen();
        CGImageRef img = captureSpaceScaled(sid, NULL);
        [p orderOut:nil];
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.2]];
        if (!img) { printf("capture failed\n"); return 1; }
        size_t w = CGImageGetWidth(img), h = CGImageGetHeight(img), bpr = CGImageGetBytesPerRow(img);
        CFDataRef data = CGDataProviderCopyData(CGImageGetDataProvider(img));
        const uint8_t *px = CFDataGetBytePtr(data);
        size_t hits = 0;
        for (size_t y = 0; y < h; y++)
            for (size_t x = 0; x < w; x++) {
                const uint8_t *q = px + y * bpr + x * 4;   // BGRA
                if (q[2] > 230 && q[1] < 40 && q[0] > 230) hits++;
            }
        frac[i] = (double)hits / (w * h);
        const uint8_t *c = px + (h / 2) * bpr + (w / 2) * 4;
        printf("  center pixel rgb %d,%d,%d\n", c[2], c[1], c[0]);
        printf("%s: %.1f%% panel pixels (onscreen %d)\n",
               i == 0 ? "allSpaces none" : i == 1 ? "allSpaces readOnly" : "single-space readOnly", frac[i] * 100, on);
        CFRelease(data);
        CGImageRelease(img);
    }
    if (frac[2] < 0.01) { printf("inconclusive: the single-space control is missing too\n"); return 3; }
    printf("all-spaces panel %s the capture (none %s, readOnly %s)\n",
           frac[0] > 0.01 || frac[1] > 0.01 ? "shows in" : "is absent from",
           frac[0] > 0.01 ? "in" : "out", frac[1] > 0.01 ? "in" : "out");
    return frac[0] > 0.01 ? 2 : 0;
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
    captureF = (CaptureSpaceFn)dlsym(h, "SLSHWCaptureSpace");

    NSString *mode = argc > 1 ? [NSString stringWithUTF8String:argv[1]] : @"";
    if ([mode isEqualToString:@"--bench"]) return cmdBench(argc > 2 ? MAX(1, atoi(argv[2])) : 1);
    if ([mode isEqualToString:@"--probe-sharing"]) return cmdProbeSharing();
    if ([mode isEqualToString:@"--request-access"]) {
        BOOL ok = CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess();
        AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)@{ (__bridge id)kAXTrustedCheckOptionPrompt: @YES });
        return ok ? 0 : 1;
    }
    if (mode.length) { fprintf(stderr, "usage: spaceview [--bench [passes]|--probe-sharing|--request-access]\n"); return 2; }

    BOOL screenOK = CGPreflightScreenCaptureAccess(), axOK = AXIsProcessTrusted();
    LOG("pid %d, screen recording %d, accessibility %d, capture symbol %d",
        getpid(), screenOK, axOK, captureF != NULL);
    if (!screenOK || !captureF) LOG("previews off");
    if (!axOK) LOG("keys off; spacetool view again to close");
    // a windowless accessory app reads as idle to automatic termination
    [NSProcessInfo.processInfo disableAutomaticTermination:@"resident switcher"];
    [NSProcessInfo.processInfo disableSuddenTermination];
    captureQ = dispatch_queue_create("spaceview.capture", DISPATCH_QUEUE_SERIAL);
    switchQ = dispatch_queue_create("spaceview.switch", DISPATCH_QUEUE_SERIAL);
    installTap();

    viewer = [Viewer new];
    for (NSDictionary *g in displaySpaces()) viewer.lastCurrent[g[@"display"]] = g[@"current"];
    [viewer captureAll];
    [viewer prewarm];

    [[NSDistributedNotificationCenter defaultCenter] addObserverForName:kToggle object:nil
        queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *n) {
            [viewer toggle:[n.userInfo[@"t"] unsignedLongLongValue]];
        }];
    [[[NSWorkspace sharedWorkspace] notificationCenter]
        addObserverForName:NSWorkspaceActiveSpaceDidChangeNotification
        object:nil queue:nil usingBlock:^(NSNotification *n) { [viewer spaceChanged]; }];
    [[NSNotificationCenter defaultCenter]
        addObserverForName:NSApplicationDidChangeScreenParametersNotification
        object:nil queue:nil usingBlock:^(NSNotification *n) { viewer.screensMoved = YES; }];
    NSTimer *idle = [NSTimer scheduledTimerWithTimeInterval:120 repeats:YES block:^(NSTimer *t) {
        if (!viewer.panel.visible) [viewer captureCurrent];
    }];
    idle.tolerance = 30;
    [NSApp run];
  }
  return 0;
}
