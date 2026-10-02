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
typedef CFArrayRef (*CopyWindowsFn)(int, uint32_t, CFArrayRef, uint32_t, uint64_t *, uint64_t *);
typedef CFArrayRef (*CaptureWindowsFn)(int, uint32_t *, int, uint32_t);
typedef CFArrayRef (*CopySpacesFn)(int, int, CFArrayRef);

static int cid;
static MDSFn mdsF;
static CaptureSpaceFn captureF;
static CopyWindowsFn copyWindowsF;
static CaptureWindowsFn captureWindowsF;
static CopySpacesFn copySpacesF;

static NSString *const kToggle = @"dev.umanzor.spaceview.toggle";
static const CGFloat kPreviewW = 960, kPreviewH = 540;
// fixed, not the drawn size, so a relayout never needs a recapture
static const CGFloat kWindowImgW = 640, kWindowImgH = 400;
// nominal bytes (footprint does not see IOSurface-backed captures); ~40 windows
// at the cap, keeping the 62MB phase 1 warm figure plus this under 120MB
static const size_t kWindowCacheCap = 40u << 20;
// stuck windows show up on every space's list; one filter so it stays a one-line change
static const BOOL kExcludeStuckWindows = YES;
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

// returns +1, never larger than maxW x maxH and never upscaled
static CGImageRef downscale(CGImageRef full, CGFloat maxW, CGFloat maxH) {
    size_t w = CGImageGetWidth(full), h = CGImageGetHeight(full);
    if (!w || !h) return NULL;
    double k = fmin(1.0, fmin(maxW / w, maxH / h));
    size_t sw = MAX(1, (size_t)lround(w * k)), sh = MAX(1, (size_t)lround(h * k));
    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef ctx = CGBitmapContextCreate(NULL, sw, sh, 8, 0, cs,
        kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
    CGColorSpaceRelease(cs);
    if (!ctx) return NULL;
    CGContextSetInterpolationQuality(ctx, kCGInterpolationMedium);
    CGContextDrawImage(ctx, CGRectMake(0, 0, sw, sh), full);
    CGImageRef out = CGBitmapContextCreateImage(ctx);
    CGContextRelease(ctx);
    return out;
}

static size_t nominalBytes(CGImageRef img) {
    return img ? CGImageGetBytesPerRow(img) * CGImageGetHeight(img) : 0;
}

// both captures return +1 and are IOSurface-backed: the full-res image dies
// inside the pool, only the downscale leaves
static CGImageRef captureSpaceScaled(uint64_t sid, double *ms) {
    CGImageRef out = NULL;
    uint64_t t0 = nowNs();
    @autoreleasepool {
        CFArrayRef imgs = captureF ? captureF(cid, sid, 0) : NULL;
        if (imgs && CFArrayGetCount(imgs))
            out = downscale((CGImageRef)CFArrayGetValueAtIndex(imgs, 0), kPreviewW, kPreviewH);
        if (imgs) CFRelease(imgs);
    }
    if (ms) *ms = (nowNs() - t0) / 1e6;
    return out;
}

static CGImageRef captureWindowScaled(uint32_t wid, double *ms) {
    CGImageRef out = NULL;
    uint64_t t0 = nowNs();
    @autoreleasepool {
        // 0x800|0x200: the probe's flags; they capture off-space windows at nominal res
        CFArrayRef imgs = captureWindowsF ? captureWindowsF(cid, &wid, 1, 0x800 | 0x200) : NULL;
        if (imgs && CFArrayGetCount(imgs))
            out = downscale((CGImageRef)CFArrayGetValueAtIndex(imgs, 0), kWindowImgW, kWindowImgH);
        if (imgs) CFRelease(imgs);
    }
    if (ms) *ms = (nowNs() - t0) / 1e6;
    return out;
}

static NSDictionary<NSNumber *, NSDictionary *> *windowInfoByWid(void) {
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    for (NSDictionary *w in (NSArray *)CFBridgingRelease(CGWindowListCopyWindowInfo(
            kCGWindowListOptionAll, kCGNullWindowID)))
        if (w[(id)kCGWindowNumber]) out[w[(id)kCGWindowNumber]] = w;
    return out;
}

static BOOL windowIsStuck(uint32_t wid) {
    if (!copySpacesF) return NO;
    NSArray *on = CFBridgingRelease(copySpacesF(cid, 7, (__bridge CFArrayRef)@[@(wid)]));
    return on.count > 1;
}

// the windows a pane shows for sid, in the order SkyLight returns them, with
// the probe's filter: layer 0, at least 120x120, known to CGWindowList
static NSArray<NSDictionary *> *windowsOnSpace(uint64_t sid, NSDictionary *info, int *stuckOut) {
    NSMutableArray *out = [NSMutableArray array];
    if (!copyWindowsF) return out;
    uint64_t set = 0, clr = 0;
    NSArray *wids = CFBridgingRelease(copyWindowsF(cid, 0, (__bridge CFArrayRef)@[@(sid)], 0x2, &set, &clr));
    int stuck = 0, z = 0;
    for (NSNumber *n in wids) {
        NSDictionary *w = info[n];
        if (!w || [w[(id)kCGWindowLayer] intValue] != 0) continue;
        CGRect b;
        if (!CGRectMakeWithDictionaryRepresentation((CFDictionaryRef)w[(id)kCGWindowBounds], &b)) continue;
        if (b.size.width < 120 || b.size.height < 120) continue;
        if (windowIsStuck(n.unsignedIntValue)) { stuck++; if (kExcludeStuckWindows) continue; }
        [out addObject:@{ @"wid": n, @"pid": w[(id)kCGWindowOwnerPID] ?: @0,
            @"app": w[(id)kCGWindowOwnerName] ?: @"", @"title": w[(id)kCGWindowName] ?: @"",
            @"frame": [NSValue valueWithRect:NSRectFromCGRect(b)], @"z": @(z++) }];
    }
    if (stuckOut) *stuckOut = stuck;
    return out;
}

// --- window layout ---
// pure: frames and a pane in, image rects out (y grows down, the caller flips).
// Every item is the image plus a label strip under it; items stay inside the
// pane and never overlap. Mission Control style when the windows can be pushed
// apart legibly, else a grid in z order
static const int kGridAbove = 12;            // more windows than this always grid
static const CGFloat kLayoutGap = 12, kLayoutMargin = 16, kLayoutLabelH = 18;
static const CGFloat kMinCellW = 72;         // narrower than this is not legible: grid

static CGSize sanitizedSize(CGRect f) {
    CGFloat w = isfinite(f.size.width) ? fabs(f.size.width) : 0, h = isfinite(f.size.height) ? fabs(f.size.height) : 0;
    return CGSizeMake(MAX(w, 1), MAX(h, 1));
}

static CGRect fitAspect(CGSize s, CGRect cell) {
    if (cell.size.width <= 0 || cell.size.height <= 0) return CGRectMake(cell.origin.x, cell.origin.y, 0, 0);
    CGFloat k = fmin(cell.size.width / s.width, cell.size.height / s.height);
    CGFloat w = s.width * k, h = s.height * k;
    return CGRectMake(cell.origin.x + (cell.size.width - w) / 2, cell.origin.y + (cell.size.height - h) / 2, w, h);
}

static void gridLayout(const CGSize *sz, int n, CGRect pane, CGRect *out) {
    CGFloat bestScore = -1;
    int bestCols = 1;
    for (int cols = 1; cols <= n; cols++) {
        int rows = (n + cols - 1) / cols;
        CGFloat cw = (pane.size.width - (cols + 1) * kLayoutGap) / cols;
        CGFloat ch = (pane.size.height - (rows + 1) * kLayoutGap) / rows - kLayoutLabelH;
        if (cw <= 0 || ch <= 0) continue;
        CGFloat score = 0;
        for (int i = 0; i < n; i++) { CGRect r = fitAspect(sz[i], CGRectMake(0, 0, cw, ch)); score += r.size.width * r.size.height; }
        if (score > bestScore) { bestScore = score; bestCols = cols; }
    }
    int cols = bestCols, rows = (n + cols - 1) / cols;
    CGFloat cw = MAX(0, (pane.size.width - (cols + 1) * kLayoutGap) / cols);
    CGFloat ch = MAX(0, (pane.size.height - (rows + 1) * kLayoutGap) / rows - kLayoutLabelH);
    for (int i = 0; i < n; i++) {
        int r = i / cols, c = i % cols;
        CGRect cell = CGRectMake(pane.origin.x + kLayoutGap + c * (cw + kLayoutGap),
                                 pane.origin.y + kLayoutGap + r * (ch + kLayoutLabelH + kLayoutGap), cw, ch);
        out[i] = fitAspect(sz[i], cell);
    }
}

static BOOL itemsOverlap(CGRect a, CGRect b, CGFloat gap) {
    if (a.size.width <= 0 || a.size.height <= 0 || b.size.width <= 0 || b.size.height <= 0) return NO;
    return a.origin.x < CGRectGetMaxX(b) + gap && b.origin.x < CGRectGetMaxX(a) + gap &&
           a.origin.y < CGRectGetMaxY(b) + gap && b.origin.y < CGRectGetMaxY(a) + gap;
}

// returns YES when it fell back to the grid
static BOOL layoutWindows(const CGRect *frames, int n, CGRect pane, CGRect *out) {
    if (n <= 0) return NO;
    // past 1e7 points a 12pt gap is lost to double precision; no real pane gets near
    if (!isfinite(pane.origin.x) || !isfinite(pane.origin.y) || !isfinite(pane.size.width) || !isfinite(pane.size.height)
            || pane.size.width <= 0 || pane.size.height <= 0 || fabs(pane.origin.x) > 1e7 || fabs(pane.origin.y) > 1e7
            || pane.size.width > 1e7 || pane.size.height > 1e7) {
        for (int i = 0; i < n; i++) out[i] = CGRectZero;
        return YES;
    }
    CGSize *sz = calloc(n, sizeof *sz);
    CGFloat *cx = calloc(n, sizeof *cx), *cy = calloc(n, sizeof *cy);
    for (int i = 0; i < n; i++) sz[i] = sanitizedSize(frames[i]);
    CGRect inner = CGRectInset(pane, kLayoutMargin, kLayoutMargin);
    BOOL grid = n > kGridAbove || inner.size.width <= 0 || inner.size.height <= kLayoutLabelH;
    if (!grid) {
        // natural positions: the union of the real frames mapped into the pane
        CGFloat minX = INFINITY, minY = INFINITY, maxX = -INFINITY, maxY = -INFINITY;
        for (int i = 0; i < n; i++) {
            CGFloat x = isfinite(frames[i].origin.x) ? frames[i].origin.x : 0, y = isfinite(frames[i].origin.y) ? frames[i].origin.y : 0;
            minX = fmin(minX, x); minY = fmin(minY, y); maxX = fmax(maxX, x + sz[i].width); maxY = fmax(maxY, y + sz[i].height);
        }
        CGFloat k = fmin(inner.size.width / (maxX - minX), (inner.size.height - kLayoutLabelH) / (maxY - minY));
        // origins past ~1e17 swallow the size (x + w == x), so the span is 0 and k is inf
        if (!isfinite(k) || k <= 0) grid = YES;
        for (int i = 0; i < n; i++) {
            CGFloat x = isfinite(frames[i].origin.x) ? frames[i].origin.x : 0, y = isfinite(frames[i].origin.y) ? frames[i].origin.y : 0;
            cx[i] = inner.origin.x + (x - minX + sz[i].width / 2) * k;
            cy[i] = inner.origin.y + (y - minY + sz[i].height / 2) * k;
        }
        BOOL settled = NO;
        for (int round = 0; round < 8 && !settled && !grid; round++) {
            for (int it = 0; it < 64; it++) {
                BOOL moved = NO;
                for (int i = 0; i < n; i++) for (int j = i + 1; j < n; j++) {
                    CGFloat wi = sz[i].width * k, hi = sz[i].height * k + kLayoutLabelH;
                    CGFloat wj = sz[j].width * k, hj = sz[j].height * k + kLayoutLabelH;
                    CGFloat ox = (wi + wj) / 2 + kLayoutGap - fabs(cx[i] - cx[j]);
                    CGFloat oy = (hi + hj) / 2 + kLayoutGap - fabs(cy[i] - cy[j]);
                    if (ox <= 0 || oy <= 0) continue;
                    moved = YES;
                    // ties break by index so identical frames still separate
                    if (ox < oy) { CGFloat d = (cx[i] < cx[j] || (cx[i] == cx[j] && i < j)) ? -1 : 1; cx[i] += d * ox / 2; cx[j] -= d * ox / 2; }
                    else         { CGFloat d = (cy[i] < cy[j] || (cy[i] == cy[j] && i < j)) ? -1 : 1; cy[i] += d * oy / 2; cy[j] -= d * oy / 2; }
                }
                if (!moved) break;
            }
            CGFloat bx0 = INFINITY, by0 = INFINITY, bx1 = -INFINITY, by1 = -INFINITY;
            for (int i = 0; i < n; i++) {
                CGFloat w = sz[i].width * k, h = sz[i].height * k + kLayoutLabelH;
                bx0 = fmin(bx0, cx[i] - w / 2); bx1 = fmax(bx1, cx[i] + w / 2);
                by0 = fmin(by0, cy[i] - h / 2); by1 = fmax(by1, cy[i] + h / 2);
            }
            CGFloat bw = bx1 - bx0, bh = by1 - by0;
            if (bw <= inner.size.width + 0.5 && bh <= inner.size.height + 0.5) {
                CGFloat dx = inner.origin.x + (inner.size.width - bw) / 2 - bx0, dy = inner.origin.y + (inner.size.height - bh) / 2 - by0;
                for (int i = 0; i < n; i++) { cx[i] += dx; cy[i] += dy; }
                settled = YES;
                break;
            }
            // too big: shrink about the bounding box centre (the label strip does not scale), then push again
            CGFloat s = 0.97 * fmin(inner.size.width / bw, inner.size.height / bh);
            CGFloat mx = (bx0 + bx1) / 2, my = (by0 + by1) / 2;
            for (int i = 0; i < n; i++) { cx[i] = mx + (cx[i] - mx) * s; cy[i] = my + (cy[i] - my) * s; }
            k *= s;
        }
        if (settled) {
            for (int i = 0; i < n; i++) {
                CGFloat w = sz[i].width * k, h = sz[i].height * k;
                out[i] = CGRectMake(cx[i] - w / 2, cy[i] - (h + kLayoutLabelH) / 2, w, h);
            }
            for (int i = 0; i < n && !grid; i++) for (int j = i + 1; j < n && !grid; j++) {
                CGRect a = out[i], b = out[j];
                a.size.height += kLayoutLabelH; b.size.height += kLayoutLabelH;
                if (itemsOverlap(a, b, 0)) grid = YES;
            }
            for (int i = 0; i < n && !grid; i++) if (out[i].size.width < kMinCellW && n > 1) grid = YES;
            for (int i = 0; i < n && !grid; i++)
                if (!isfinite(out[i].origin.x) || !isfinite(out[i].origin.y) || !isfinite(out[i].size.width) || !isfinite(out[i].size.height))
                    grid = YES;
        } else grid = YES;
    }
    if (grid) gridLayout(sz, n, pane, out);
    free(sz); free(cx); free(cy);
    return grid;
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
// blocking: run on switchQ only. YES once CGS reports sid current
static BOOL switchToSpace(uint64_t sid, int ord, BOOL firstGroup) {
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
                    return YES;
                }
                usleep(10000);
            }
            // the Dock may still apply it; a fallback now would switch twice
            LOG("switch to %d unconfirmed: %{public}s", ord, !io ? "no reply from the payload"
                : err == SPACEC_TIMEOUT ? "Dock main queue timed out" : "Dock accepted but CGS never got there");
            if (lfd >= 0) close(lfd);
            return NO;
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
    // sw resolves a bare ordinal against the first display that has it, so on
    // any other display it would switch the wrong space
    if (!firstGroup) {
        static BOOL said;
        if (!said) LOG("no fallback for %d: not on the first display's space list", ord);
        said = YES;
        return NO;
    }
    NSTask *t = [NSTask new];
    t.executableURL = [NSURL fileURLWithPath:[NSHomeDirectory()
        stringByAppendingPathComponent:@"Applications/SpaceTool.app/Contents/MacOS/SpaceTool"]];
    t.arguments = @[@"switch", [NSString stringWithFormat:@"%d", ord]];
    NSError *err = nil;
    if (![t launchAndReturnError:&err]) { LOG("SpaceTool switch failed to launch: %{public}@", err); return NO; }
    // the animated fallback slides for ~300ms; bounded so a stuck Dock cannot hold switchQ
    for (int i = 0; i < 200; i++) { if (spaceIsCurrent(sid)) return YES; usleep(10000); }
    LOG("fallback switch to %d not confirmed in 2s", ord);
    return NO;
}

// --- focusing one window ---
extern AXError _AXUIElementGetWindow(AXUIElementRef, CGWindowID *);

static pid_t frontPid(void) {
    __block pid_t p = 0;
    // NSWorkspace wants the main thread
    dispatch_sync(dispatch_get_main_queue(), ^{ p = NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier; });
    return p;
}

// blocking: run on switchQ only. Matches the AXWindow by window id, never by
// title (terminals and browsers repeat titles), raises only that window, then
// makes its app frontmost. Every AX call is bounded so a hung app cannot hold
// switchQ for the default ~6s per message
static void focusWindow(pid_t pid, uint32_t wid, uint64_t sid) {
    uint64_t t0 = nowNs();
    id app = CFBridgingRelease(AXUIElementCreateApplication(pid));
    if (!app) return;
    AXUIElementSetMessagingTimeout((__bridge AXUIElementRef)app, 0.5);
    id win = nil;
    // right after a switch the app's AX window list can lag the space change
    for (int attempt = 0; attempt < 10 && !win; attempt++) {
        CFArrayRef raw = NULL;
        AXError e = AXUIElementCopyAttributeValue((__bridge AXUIElementRef)app, kAXWindowsAttribute, (CFTypeRef *)&raw);
        // CannotComplete is the messaging timeout: the app is not answering, and
        // retrying would hold switchQ 0.5s a go
        if (e == kAXErrorCannotComplete) { LOG("focus %u: pid %d not answering AX, skipped", wid, pid); return; }
        if (e == kAXErrorSuccess && raw) {
            // hold the match as a strong id: under ARC at -O2 the array can be
            // freed when enumeration ends (README gotcha)
            for (id w in (__bridge_transfer NSArray *)raw) {
                CGWindowID got = 0;
                if (_AXUIElementGetWindow((__bridge AXUIElementRef)w, &got) == kAXErrorSuccess && got == wid) { win = w; break; }
            }
        }
        if (!win) usleep(50000);
    }
    if (!win) { LOG("focus %u: window gone or not in AX, skipped", wid); return; }
    AXUIElementSetMessagingTimeout((__bridge AXUIElementRef)win, 0.5);
    AXError raise = AXUIElementPerformAction((__bridge AXUIElementRef)win, kAXRaiseAction);
    AXUIElementSetAttributeValue((__bridge AXUIElementRef)win, kAXMainAttribute, kCFBooleanTrue);
    AXError front = AXUIElementSetAttributeValue((__bridge AXUIElementRef)app, kAXFrontmostAttribute, kCFBooleanTrue);
    // frontmost may be refused for a background accessory app; fall back to
    // activating just that app (not ActivateAllWindows, which raises every window)
    BOOL viaAX = YES;
    for (int i = 0; i < 20 && frontPid() != pid; i++) usleep(10000);
    if (frontPid() != pid) {
        viaAX = NO;
        [[NSRunningApplication runningApplicationWithProcessIdentifier:pid] activateWithOptions:0];
        for (int i = 0; i < 30 && frontPid() != pid; i++) usleep(10000);
    }
    BOOL stayed = spaceIsCurrent(sid);
    LOG("focus %u (pid %d): raise %d, frontmost %d via %{public}s, front now %d, space %{public}s, %.0fms",
        wid, pid, raise, front, viaAX ? "AX" : "NSRunningApplication", frontPid() == pid,
        stayed ? "kept" : "MOVED (switch-to-space-with-windows setting?)", (nowNs() - t0) / 1e6);
}

// --- panel ---
@interface FlippedView : NSView
@end
@implementation FlippedView
- (BOOL)isFlipped { return YES; }
@end

// the panel is nonactivating and, being borderless, never becomes key, so a
// click lands here without activating SpaceView or taking focus from the front app
@interface CellView : NSView
@property int ord;
@end

// one window in the right pane; the image is a sublayer so the label strip stays hit-testable
@interface WinCellView : NSView
@property CALayer *image;
@property NSTextField *label;
@property uint32_t wid;
@property pid_t pid;
@property uint64_t sid;   // the space it was listed under; the click re-resolves it
@end

@interface Cell : NSObject
@property CellView *view;
@property CALayer *preview;
@property NSTextField *label;
@end
@implementation Cell
@end

// one space's windows: the list from its last refresh and the images captured since
@interface WinSpace : NSObject
@property NSArray<NSDictionary *> *list;
@property NSMutableDictionary<NSNumber *, id> *images;   // wid -> CGImage
@property size_t bytes;
@property uint64_t lastSelected;   // eviction order; set at creation so a just-left space is not first out
@end
@implementation WinSpace
@end

@interface Viewer : NSObject
@property NSPanel *panel;
@property NSScrollView *sidebar;
@property FlippedView *list;
@property NSMutableArray<Cell *> *cells;
@property NSArray *shown;                 // spaces of the panel's display, sidebar order
@property BOOL shownFirstGroup;           // shown came from the first CGS display group
@property NSString *shownKey;             // sid/ord/name signature the cells were built from
@property NSMutableDictionary<NSNumber *, id> *previews;   // sid -> CGImage
@property NSMutableDictionary<NSString *, NSNumber *> *lastCurrent;   // display -> sid
@property NSMutableArray<NSDictionary *> *jobs;   // capture worker queue, main-thread only
@property NSMutableSet<NSString *> *jobKeys;        // queued or in flight, for coalescing
@property BOOL working;
@property NSMutableDictionary<NSNumber *, WinSpace *> *winCache;   // sid -> windows
@property size_t winBytes;
@property BOOL screensMoved;
@property FlippedView *pane;                       // right side: the selected space's windows
@property NSMutableArray<WinCellView *> *winCells; // reused across renders
@property NSTextField *paneNote;                   // "no windows" / "capturing"
@property NSInteger selected;                      // index into shown
@property NSPoint showMouse;                       // pointer at order-in
@property BOOL hoverArmed;                         // the pointer has really moved since then
@end

static Viewer *viewer;
static CFMachPortRef keyTap;
static atomic_bool panelVisible;
static BOOL fired;   // one switch per show: a second digit or click would race the first
static dispatch_queue_t captureQ, switchQ;
static BOOL previewsOn;
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
    _jobs = [NSMutableArray array];
    _jobKeys = [NSMutableSet set];
    _winCache = [NSMutableDictionary dictionary];
    _winCells = [NSMutableArray array];
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
    _pane = [[FlippedView alloc] initWithFrame:NSZeroRect];
    [bg addSubview:_pane];
    _paneNote = [NSTextField labelWithString:@""];
    _paneNote.textColor = NSColor.secondaryLabelColor;
    _paneNote.alignment = NSTextAlignmentCenter;
    [_pane addSubview:_paneNote];
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
    self.pane.frame = NSMakeRect(kSidebarW, 0, r.size.width - kSidebarW, r.size.height);
    self.paneNote.frame = NSMakeRect(0, r.size.height / 2 - 12, r.size.width - kSidebarW, 24);
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
        c.view = [[CellView alloc] initWithFrame:NSMakeRect(kPad, y, w, th + kLabelH + 6)];
        c.view.wantsLayer = YES;
        c.view.ord = [s[@"ord"] intValue];
        c.view.layer.cornerRadius = 8;
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
        c.view.layer.backgroundColor = (NSInteger)i == self.selected
            ? [NSColor colorWithWhite:1 alpha:0.16].CGColor : nil;
    }
}

// --- selection and the right pane ---

- (void)selectIndex:(NSInteger)i {
    if (!self.shown.count) return;
    i = MAX(0, MIN((NSInteger)self.shown.count - 1, i));   // clamp, no wrap
    BOOL changed = i != self.selected;
    self.selected = i;
    uint64_t sid = [self.shown[i][@"sid"] unsignedLongLongValue];
    WinSpace *ws = self.winCache[@(sid)];
    if (ws) ws.lastSelected = nowNs();
    else [self captureWindowsOf:sid urgent:YES];
    if (changed || !ws) [self refreshCellContents];
    [self renderPane];
}

- (uint64_t)selectedSid {
    return self.selected < (NSInteger)self.shown.count ? [self.shown[self.selected][@"sid"] unsignedLongLongValue] : 0;
}

// cached images or placeholders, laid out by layoutWindows; never captures
- (void)renderPane {
    uint64_t sid = [self selectedSid];
    WinSpace *ws = self.winCache[@(sid)];
    NSArray *list = ws.list ?: @[];
    int n = (int)list.count;
    self.paneNote.stringValue = !previewsOn ? @"previews off: no Screen Recording grant"
        : !ws ? @"capturing windows…" : n ? @"" : @"no windows";
    self.paneNote.hidden = n > 0;
    CGRect *frames = calloc(MAX(n, 1), sizeof *frames), *out = calloc(MAX(n, 1), sizeof *out);
    for (int i = 0; i < n; i++) frames[i] = NSRectToCGRect([list[i][@"frame"] rectValue]);
    layoutWindows(frames, n, self.pane.bounds, out);
    while ((int)self.winCells.count < n) {
        WinCellView *v = [[WinCellView alloc] initWithFrame:NSZeroRect];
        v.wantsLayer = YES;
        v.image = [CALayer layer];
        v.image.contentsGravity = kCAGravityResizeAspect;
        v.image.cornerRadius = 5;
        v.image.masksToBounds = YES;
        v.image.backgroundColor = [NSColor colorWithWhite:0 alpha:0.35].CGColor;
        [v.layer addSublayer:v.image];
        v.label = [NSTextField labelWithString:@""];
        v.label.font = [NSFont systemFontOfSize:11];
        v.label.textColor = NSColor.labelColor;
        v.label.lineBreakMode = NSLineBreakByTruncatingTail;
        v.label.alignment = NSTextAlignmentCenter;
        [v addSubview:v.label];
        [self.pane addSubview:v];
        [self.winCells addObject:v];
    }
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    for (int i = 0; i < (int)self.winCells.count; i++) {
        WinCellView *v = self.winCells[i];
        v.hidden = i >= n;
        if (i >= n) { v.image.contents = nil; continue; }
        NSDictionary *w = list[i];
        CGRect r = out[i];
        v.frame = NSMakeRect(r.origin.x, r.origin.y, r.size.width, r.size.height + kLayoutLabelH);
        v.wid = [w[@"wid"] unsignedIntValue];
        v.pid = [w[@"pid"] intValue];
        v.sid = sid;
        // the view is unflipped: the image sits above the label strip
        v.image.frame = CGRectMake(0, kLayoutLabelH, r.size.width, r.size.height);
        v.image.contents = ws.images[w[@"wid"]];   // nil draws the placeholder fill
        NSString *t = [w[@"title"] length] ? [NSString stringWithFormat:@"%@ - %@", w[@"app"], w[@"title"]] : w[@"app"];
        v.label.stringValue = t;
        // explicit frame: autoresizing never refits a same-width string swap
        v.label.frame = NSMakeRect(0, 1, r.size.width, kLayoutLabelH - 2);
    }
    [CATransaction commit];
    free(frames); free(out);
}

- (void)storePreview:(CGImageRef)img sid:(uint64_t)sid {
    if (!img) return;
    self.previews[@(sid)] = (__bridge id)img;
    if (self.panel.visible) [self refreshCellContents];
}

// --- capture worker ---
// one capture at a time on captureQ. Urgent jobs (a selected, uncached space)
// go to the front, so they wait behind at most the one capture in flight
// rather than a whole leave batch of windows at 15-20ms each

- (void)enqueue:(NSDictionary *)job urgent:(BOOL)urgent {
    if ([self.jobKeys containsObject:job[@"key"]]) {
        if (!urgent) return;
        // promote a queued job; one already in flight is left alone
        NSUInteger i = [self.jobs indexOfObjectPassingTest:^BOOL(NSDictionary *j, NSUInteger k, BOOL *stop) {
            return [j[@"key"] isEqualToString:job[@"key"]]; }];
        if (i == NSNotFound || i == 0) return;
        NSDictionary *j = self.jobs[i];
        [self.jobs removeObjectAtIndex:i];
        [self.jobs insertObject:j atIndex:0];
        return;
    }
    [self.jobKeys addObject:job[@"key"]];
    if (urgent) [self.jobs insertObject:job atIndex:0]; else [self.jobs addObject:job];
    [self pump];
}

- (void)pump {
    if (self.working || !self.jobs.count) return;
    NSDictionary *job = self.jobs.firstObject;
    [self.jobs removeObjectAtIndex:0];
    NSString *kind = job[@"kind"];
    uint64_t sid = [job[@"sid"] unsignedLongLongValue];
    // a space evicted after its window jobs were queued: nothing to store into
    if ([kind isEqualToString:@"window"] && (!self.winCache[@(sid)] || ![self makeRoomForSid:sid])) {
        [self.jobKeys removeObject:job[@"key"]];
        [self pump];
        return;
    }
    self.working = YES;
    void (^done)(void (^)(void)) = ^(void (^apply)(void)) {
        dispatch_async(dispatch_get_main_queue(), ^{
            apply();
            [self.jobKeys removeObject:job[@"key"]];
            self.working = NO;
            [self pump];
        });
    };
    if ([kind isEqualToString:@"preview"]) {
        dispatch_async(captureQ, ^{
            double ms = 0;
            CGImageRef img = captureSpaceScaled(sid, &ms);
            LOG("captured %llu in %.1fms", sid, ms);
            done(^{ [self storePreview:img sid:sid]; if (img) CGImageRelease(img); });
        });
    } else if ([kind isEqualToString:@"list"]) {
        BOOL urgent = [job[@"urgent"] boolValue];
        dispatch_async(captureQ, ^{
            int stuck = 0;
            NSArray *list = windowsOnSpace(sid, windowInfoByWid(), &stuck);
            done(^{ [self storeList:list sid:sid stuck:stuck urgent:urgent]; });
        });
    } else {
        uint32_t wid = [job[@"wid"] unsignedIntValue];
        dispatch_async(captureQ, ^{
            double ms = 0;
            CGImageRef img = captureWindowScaled(wid, &ms);
            done(^{ [self storeWindow:img wid:wid sid:sid ms:ms]; if (img) CGImageRelease(img); });
        });
    }
}

// safe while the panel is up: SLSHWCaptureSpace leaves out all-spaces windows
// (measured with --probe-sharing), which also means stuck windows are missing
- (void)captureSid:(uint64_t)sid { [self captureSid:sid urgent:NO]; }

- (void)captureSid:(uint64_t)sid urgent:(BOOL)urgent {
    if (!previewsOn) return;
    [self enqueue:@{ @"kind": @"preview", @"sid": @(sid),
                     @"key": [NSString stringWithFormat:@"p%llu", sid] } urgent:urgent];
}

// the list first, then one job per window, all at the same priority
- (void)captureWindowsOf:(uint64_t)sid urgent:(BOOL)urgent {
    if (!previewsOn || !copyWindowsF || !captureWindowsF) return;
    [self enqueue:@{ @"kind": @"list", @"sid": @(sid), @"urgent": @(urgent),
                     @"key": [NSString stringWithFormat:@"l%llu", sid] } urgent:urgent];
}

- (void)storeList:(NSArray *)list sid:(uint64_t)sid stuck:(int)stuck urgent:(BOOL)urgent {
    WinSpace *ws = self.winCache[@(sid)];
    if (!ws) {
        ws = [WinSpace new];
        ws.images = [NSMutableDictionary dictionary];
        ws.lastSelected = nowNs();
        self.winCache[@(sid)] = ws;
    }
    ws.list = list;
    NSMutableSet *live = [NSMutableSet set];
    for (NSDictionary *w in list) [live addObject:w[@"wid"]];
    for (NSNumber *wid in ws.images.allKeys)
        if (![live containsObject:wid]) [self dropImage:wid from:ws];
    LOG("space %llu: %lu windows (%d stuck skipped)", sid, (unsigned long)list.count, stuck);
    if (self.panel.visible && sid == [self selectedSid]) [self renderPane];
    // urgent jobs go to the front one by one, so add them in reverse to keep z order
    NSEnumerator *e = urgent ? list.reverseObjectEnumerator : list.objectEnumerator;
    for (NSDictionary *w in e)
        [self enqueue:@{ @"kind": @"window", @"sid": @(sid), @"wid": w[@"wid"],
            @"key": [NSString stringWithFormat:@"w%llu:%@", sid, w[@"wid"]] } urgent:urgent];
}

- (void)dropImage:(NSNumber *)wid from:(WinSpace *)ws {
    id img = ws.images[wid];
    if (!img) return;
    size_t b = nominalBytes((__bridge CGImageRef)img);
    ws.bytes -= b;
    self.winBytes -= b;
    [ws.images removeObjectForKey:wid];
}

- (void)storeWindow:(CGImageRef)img wid:(uint32_t)wid sid:(uint64_t)sid ms:(double)ms {
    WinSpace *ws = self.winCache[@(sid)];
    if (!ws || !img) return;   // evicted or forgotten while in flight
    [self dropImage:@(wid) from:ws];
    size_t b = nominalBytes(img);
    ws.images[@(wid)] = (__bridge id)img;
    ws.bytes += b;
    self.winBytes += b;
    LOG("window %u on %llu in %.1fms, cache %.1fMB", wid, sid, ms, self.winBytes / 1048576.0);
    if (self.panel.visible && sid == [self selectedSid]) [self renderPane];
}

// the in-flight capture counts against the cap: reserve its worst case before
// starting it. Evicts whole spaces, least recently selected first; never sid
// itself or a space that is current
- (BOOL)makeRoomForSid:(uint64_t)sid {
    size_t need = (size_t)kWindowImgW * (size_t)kWindowImgH * 4;
    if (self.winBytes + need <= kWindowCacheCap) return YES;
    NSMutableSet *keep = [NSMutableSet setWithObject:@(sid)];
    [keep addObjectsFromArray:self.lastCurrent.allValues];
    NSArray *order = [self.winCache.allKeys sortedArrayUsingComparator:^NSComparisonResult(NSNumber *a, NSNumber *b) {
        uint64_t x = self.winCache[a].lastSelected, y = self.winCache[b].lastSelected;
        return x < y ? NSOrderedAscending : x > y ? NSOrderedDescending : NSOrderedSame; }];
    for (NSNumber *k in order) {
        if (self.winBytes + need <= kWindowCacheCap) break;
        if ([keep containsObject:k] || !self.winCache[k].bytes) continue;   // 0 bytes frees nothing
        LOG("evicting windows of %@ (%.1fMB)", k, self.winCache[k].bytes / 1048576.0);
        self.winBytes -= self.winCache[k].bytes;
        [self.winCache removeObjectForKey:k];
    }
    return self.winBytes + need <= kWindowCacheCap;
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
    for (NSNumber *k in self.winCache.allKeys) if (![live containsObject:k]) {
        self.winBytes -= self.winCache[k].bytes;
        [self.winCache removeObjectForKey:k];
    }
}

- (void)spaceChanged {
    [self hide];
    NSArray *groups = displaySpaces();
    [self forgetGoneSpaces:groups];
    for (NSDictionary *g in groups) {
        NSNumber *prev = self.lastCurrent[g[@"display"]];
        if (prev && ![prev isEqual:g[@"current"]]) {
            [self captureSid:prev.unsignedLongLongValue];
            [self captureWindowsOf:prev.unsignedLongLongValue urgent:NO];
        }
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
    self.shownFirstGroup = g == groups.firstObject;
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
    // the current space, even with the pointer resting on another cell: order-in
    // fires mouseEntered without any motion
    self.showMouse = [NSEvent mouseLocation];
    self.hoverArmed = NO;
    self.selected = -1;
    NSInteger cur = 0;
    for (NSUInteger i = 0; i < self.shown.count; i++) if ([self.shown[i][@"current"] boolValue]) cur = i;
    [self selectIndex:cur];
    // the space you are on is the one most likely changed since it was last
    // left; queued, never captured here, and the cached render stays up meanwhile
    if (self.shown.count) [self captureWindowsOf:[self.shown[cur][@"sid"] unsignedLongLongValue] urgent:YES];
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
    // urgent: the fresh shot of the space you are on must not wait behind a leave batch
    if (g) [self captureSid:[g[@"current"] unsignedLongLongValue] urgent:YES];
    // a space created since launch has never been left, so nothing captured it
    for (NSDictionary *s in self.shown)
        if (!self.previews[s[@"sid"]]) [self captureSid:[s[@"sid"] unsignedLongLongValue]];
}

- (void)hide {
    if (atomic_load(&panelVisible)) LOG("hide");
    if (keyTap) CGEventTapEnable(keyTap, false);
    atomic_store(&panelVisible, false);
    [self.panel orderOut:nil];
}

- (void)switchToOrd:(int)ord {
    NSDictionary *target = nil;
    for (NSDictionary *s in self.shown) if ([s[@"ord"] intValue] == ord) target = s;
    [self hide];
    if (!target) return;
    // already there: still leave the user out of mission control, as a switch would
    if ([target[@"current"] boolValue]) { dispatch_async(switchQ, ^{ closeMissionControlBlocking(); }); return; }
    uint64_t sid = [target[@"sid"] unsignedLongLongValue];
    BOOL first = self.shownFirstGroup;
    dispatch_async(switchQ, ^{ switchToSpace(sid, ord, first); });
}

// switch to the window's space (resolved now, not from the cache: it may have
// moved), wait for CGS to confirm, then focus it. On the current space: no switch
- (void)focusWindowCell:(WinCellView *)v {
    if (fired) return;
    fired = YES;
    uint32_t wid = v.wid;
    pid_t pid = v.pid;
    uint64_t sid = v.sid;
    NSArray *on = copySpacesF ? CFBridgingRelease(copySpacesF(cid, 7, (__bridge CFArrayRef)@[@(wid)])) : nil;
    BOOL gone = on.count == 0;
    if (on.count == 1) sid = [on.firstObject unsignedLongLongValue];
    NSDictionary *target = nil;
    for (NSDictionary *s in self.shown) if ([s[@"sid"] unsignedLongLongValue] == sid) target = s;
    BOOL here = spaceIsCurrent(sid);
    int ord = [target[@"ord"] intValue];
    BOOL first = self.shownFirstGroup;
    [self hide];
    if (!here && !target) { LOG("focus %u: its space %llu is not on this display, skipped", wid, sid); return; }
    dispatch_async(switchQ, ^{
        if (!here) {
            closeMissionControlBlocking();
            if (!switchToSpace(sid, ord, first)) { LOG("focus %u: switch unconfirmed, not focusing", wid); return; }
        } else closeMissionControlBlocking();
        if (gone) { LOG("focus %u: window vanished since capture, switch only", wid); return; }
        focusWindow(pid, wid, sid);
    });
}

- (void)moveSelection:(NSInteger)d { [self selectIndex:self.selected + d]; }

- (void)switchToSelected {
    if (self.selected < 0 || self.selected >= (NSInteger)self.shown.count) return;
    [self switchToOrd:[self.shown[self.selected][@"ord"] intValue]];
}

- (void)hoverIndexOf:(CellView *)v {
    if (!self.hoverArmed) {
        NSPoint p = [NSEvent mouseLocation];
        if (fabs(p.x - self.showMouse.x) < 1 && fabs(p.y - self.showMouse.y) < 1) return;
        self.hoverArmed = YES;
    }
    for (NSUInteger i = 0; i < self.cells.count; i++)
        if (self.cells[i].view == v && (NSInteger)i != self.selected) { [self selectIndex:i]; return; }
}

- (BOOL)hasOrd:(int)ord {
    for (NSDictionary *s in self.shown) if ([s[@"ord"] intValue] == ord) return YES;
    return NO;
}
@end

@implementation WinCellView
- (BOOL)acceptsFirstMouse:(NSEvent *)e { return YES; }
// the label would otherwise take the hit over its strip
- (NSView *)hitTest:(NSPoint)p { return !self.hidden && NSPointInRect(p, self.frame) ? self : nil; }
- (void)mouseDown:(NSEvent *)e { self.layer.backgroundColor = [NSColor colorWithWhite:1 alpha:0.18].CGColor; }
// on the up, inside, like the sidebar cells
- (void)mouseUp:(NSEvent *)e {
    self.layer.backgroundColor = nil;
    if (!NSPointInRect([self convertPoint:e.locationInWindow fromView:nil], self.bounds)) return;
    [viewer focusWindowCell:self];
}
@end

@implementation CellView
- (BOOL)acceptsFirstMouse:(NSEvent *)e { return YES; }
// the name label would otherwise be the hit view over its strip and refuse the first mouse
- (NSView *)hitTest:(NSPoint)p { return NSPointInRect(p, self.frame) ? self : nil; }
- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    for (NSTrackingArea *a in self.trackingAreas) [self removeTrackingArea:a];
    // ActiveAlways: SpaceView is never the active app
    [self addTrackingArea:[[NSTrackingArea alloc] initWithRect:NSZeroRect
        options:NSTrackingMouseEnteredAndExited | NSTrackingMouseMoved | NSTrackingActiveAlways | NSTrackingInVisibleRect
        owner:self userInfo:nil]];
}
// hover moves the selection, but only after real pointer motion since the open
- (void)mouseEntered:(NSEvent *)e { [viewer hoverIndexOf:self]; }
- (void)mouseMoved:(NSEvent *)e { [viewer hoverIndexOf:self]; }
// act on the up: hiding on the down could hand the orphan mouseUp to whatever
// window is under the pointer once the panel is gone
- (void)mouseDown:(NSEvent *)e { self.layer.backgroundColor = [NSColor colorWithWhite:1 alpha:0.22].CGColor; }
- (void)mouseUp:(NSEvent *)e {
    [viewer refreshCellContents];   // back to the selection tint
    if (!NSPointInRect([self convertPoint:e.locationInWindow fromView:nil], self.bounds)) return;
    if (fired) return;
    fired = YES;
    [viewer switchToOrd:self.ord];
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
    if (kc == 125 || kc == 126) {   // down, up: repeats allowed, they just keep moving
        NSInteger step = kc == 125 ? 1 : -1;
        dispatch_async(dispatch_get_main_queue(), ^{ [viewer moveSelection:step]; });
        return NULL;
    }
    if (kc == 36 || kc == 76) {     // return, keypad enter
        if (fired || repeat) return NULL;
        fired = YES;
        dispatch_async(dispatch_get_main_queue(), ^{ [viewer switchToSelected]; });
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

// drives layoutWindows with random and degenerate input and checks what the
// pane relies on: finite, inside the pane, no overlaps, aspect kept, deterministic
static CGFloat fuzzVal(void) {
    double r = drand48();
    if (r < 0.03) return NAN;
    if (r < 0.05) return INFINITY;
    if (r < 0.08) return 0;
    if (r < 0.11) return -(drand48() * 2000);
    if (r < 0.13) return 1e9;
    if (r < 0.15) return (drand48() < 0.5 ? 1 : -1) * pow(10, 15 + drand48() * 6);   // 1e15..1e21: x + w == x
    return drand48();   // caller scales
}
static int cmdFuzzLayout(long iters, long seed) {
    srand48(seed);
    long fails = 0, grids = 0, checked = 0;
    for (long it = 0; it < iters; it++) {
        int n = (int)(drand48() * 30);
        CGRect pane = CGRectMake(drand48() * 400, drand48() * 400, drand48() < 0.05 ? fuzzVal() : drand48() * 2000,
                                 drand48() < 0.05 ? fuzzVal() : drand48() * 1500);
        CGRect *f = calloc(n ? n : 1, sizeof *f), *a = calloc(n ? n : 1, sizeof *a), *b = calloc(n ? n : 1, sizeof *b);
        for (int i = 0; i < n; i++) {
            BOOL odd = drand48() < 0.15;
            f[i] = CGRectMake(odd ? fuzzVal() * 6000 : drand48() * 6000 - 3000, odd ? fuzzVal() * 4000 : drand48() * 4000 - 1000,
                              odd ? fuzzVal() * 3000 : 120 + drand48() * 3000, odd ? fuzzVal() * 2000 : 120 + drand48() * 2000);
            // a third of runs stack windows on the same frame, the push-apart worst case
            if (i && drand48() < 0.33) f[i] = f[i - 1];
        }
        // every origin far out: x + w == x, so the frames' span collapses to 0
        if (drand48() < 0.03) {
            CGFloat far = (drand48() < 0.5 ? 1 : -1) * pow(10, 17 + drand48() * 4);
            for (int i = 0; i < n; i++) { f[i].origin.x = far; f[i].origin.y = far; }
        }
        BOOL g = layoutWindows(f, n, pane, a);
        layoutWindows(f, n, pane, b);
        grids += g;
        NSMutableArray *why = [NSMutableArray array];
        if (n && memcmp(a, b, n * sizeof *a)) [why addObject:@"nondeterministic"];
        BOOL paneOK = isfinite(pane.size.width) && isfinite(pane.size.height) && isfinite(pane.origin.x) && isfinite(pane.origin.y);
        for (int i = 0; i < n; i++) {
            CGRect r = a[i];
            if (!isfinite(r.origin.x) || !isfinite(r.origin.y) || !isfinite(r.size.width) || !isfinite(r.size.height)) {
                [why addObject:[NSString stringWithFormat:@"%d not finite", i]]; continue; }
            if (r.size.width <= 0 || r.size.height <= 0) continue;
            checked++;
            CGRect item = CGRectMake(r.origin.x, r.origin.y, r.size.width, r.size.height + kLayoutLabelH);
            if (paneOK && !CGRectContainsRect(CGRectInset(pane, -0.5, -0.5), item))
                [why addObject:[NSString stringWithFormat:@"%d outside pane", i]];
            CGSize s0 = sanitizedSize(f[i]);
            double want = s0.width / s0.height, got = r.size.width / r.size.height;
            if (fabs(got - want) / want > 1e-6) [why addObject:[NSString stringWithFormat:@"%d aspect %.4f vs %.4f", i, got, want]];
            for (int j = i + 1; j < n; j++) {
                CGRect o = a[j];
                if (o.size.width <= 0 || o.size.height <= 0) continue;
                CGRect oi = CGRectMake(o.origin.x, o.origin.y, o.size.width, o.size.height + kLayoutLabelH);
                if (CGRectIntersectsRect(CGRectInset(item, 0.25, 0.25), CGRectInset(oi, 0.25, 0.25)))
                    [why addObject:[NSString stringWithFormat:@"%d overlaps %d", i, j]];
            }
        }
        if (why.count) {
            if (fails < 5) printf("FAIL iter %ld n=%d pane=%.0fx%.0f grid=%d: %s\n", it, n, pane.size.width, pane.size.height, g,
                                  [[why subarrayWithRange:NSMakeRange(0, MIN(4, why.count))] componentsJoinedByString:@"; "].UTF8String);
            fails++;
        }
        free(f); free(a); free(b);
    }
    printf("fuzz-layout seed %ld: %ld layouts, %ld grid, %ld cells checked, %ld failing\n", seed, iters, grids, checked, fails);
    // realistic desks (1-8 windows on a 2304x1296 display, a 1300x900 pane): how
    // often the Mission Control style layout survives instead of the grid
    long real = 0, realGrid = 0;
    for (int it = 0; it < 2000; it++) {
        int n = 1 + (int)(drand48() * 8);
        CGRect f[8], o[8];
        for (int i = 0; i < n; i++) {
            CGFloat w = 400 + drand48() * 1600, h = 300 + drand48() * 900;
            f[i] = CGRectMake(drand48() * (2304 - w), 25 + drand48() * (1271 - h), w, h);
        }
        real++;
        realGrid += layoutWindows(f, n, CGRectMake(0, 0, 1300, 900), o);
    }
    printf("realistic: %ld layouts, %ld grid (%.0f%%)\n", real, realGrid, 100.0 * realGrid / real);
    return fails ? 1 : 0;
}

// window lists and captures for every user space, synchronously. Checks the
// SkyLight order against the onscreen (front to back) order on current spaces
static int cmdBenchWindows(int passes) {
    if (!CGPreflightScreenCaptureAccess()) { fprintf(stderr, "spaceview: no Screen Recording grant\n"); return 1; }
    printf("footprint start %.1fMB, iosurface regions %d\n", physFootprint() / 1048576.0, iosurfaceRegions());
    NSMutableDictionary *keep = [NSMutableDictionary dictionary];
    for (int p = 1; p <= passes; p++) @autoreleasepool {
        double total = 0, worst = 0;
        int n = 0;
        size_t bytes = 0;
        uint64_t tl = nowNs();
        NSDictionary *info = windowInfoByWid();
        double infoMs = (nowNs() - tl) / 1e6;
        for (NSDictionary *g in displaySpaces())
            for (NSDictionary *s in g[@"spaces"]) {
                if ([s[@"type"] intValue] != 0) continue;
                uint64_t sid = [s[@"sid"] unsignedLongLongValue];
                int stuck = 0;
                uint64_t t0 = nowNs();
                NSArray *list = windowsOnSpace(sid, info, &stuck);
                double listMs = (nowNs() - t0) / 1e6;
                if (p == 1) {
                    printf("  space %d sid=%llu: %lu windows, %d stuck skipped, list %.2fms\n",
                           [s[@"ord"] intValue], sid, (unsigned long)list.count, stuck, listMs);
                    if ([s[@"current"] boolValue]) {
                        NSMutableArray *on = [NSMutableArray array];
                        NSSet *mine = [NSSet setWithArray:[list valueForKey:@"wid"]];
                        for (NSDictionary *w in (NSArray *)CFBridgingRelease(CGWindowListCopyWindowInfo(
                                kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements, kCGNullWindowID)))
                            if ([mine containsObject:w[(id)kCGWindowNumber]]) [on addObject:w[(id)kCGWindowNumber]];
                        printf("    order vs onscreen front-to-back: %s\n    sls:      %s\n    onscreen: %s\n",
                               [on isEqualToArray:[list valueForKey:@"wid"]] ? "same" : "DIFFERENT",
                               [[list valueForKey:@"wid"] componentsJoinedByString:@","].UTF8String,
                               [on componentsJoinedByString:@","].UTF8String);
                    }
                }
                for (NSDictionary *w in list) {
                    double ms = 0;
                    CGImageRef img = captureWindowScaled([w[@"wid"] unsignedIntValue], &ms);
                    total += ms; worst = fmax(worst, ms); n++;
                    if (p == 1) printf("    wid %-6u %-18.18s %4zux%-4zu %.1fms%s\n", [w[@"wid"] unsignedIntValue],
                        [w[@"app"] UTF8String], img ? CGImageGetWidth(img) : 0, img ? CGImageGetHeight(img) : 0,
                        ms, img ? "" : " (no image)");
                    if (img) { bytes += nominalBytes(img); keep[w[@"wid"]] = CFBridgingRelease(img); }
                }
            }
        printf("pass %d: %d windows %.0fms (worst %.1f), info %.1fms, nominal %.1fMB, footprint %.1fMB, iosurface regions %d\n",
               p, n, total, worst, infoMs, bytes / 1048576.0, physFootprint() / 1048576.0, iosurfaceRegions());
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
    copyWindowsF = (CopyWindowsFn)dlsym(h, "SLSCopyWindowsWithOptionsAndTags");
    captureWindowsF = (CaptureWindowsFn)dlsym(h, "SLSHWCaptureWindowList");
    copySpacesF = (CopySpacesFn)dlsym(h, "CGSCopySpacesForWindows");

    NSString *mode = argc > 1 ? [NSString stringWithUTF8String:argv[1]] : @"";
    if ([mode isEqualToString:@"--bench"]) return cmdBench(argc > 2 ? MAX(1, atoi(argv[2])) : 1);
    if ([mode isEqualToString:@"--probe-sharing"]) return cmdProbeSharing();
    if ([mode isEqualToString:@"--fuzz-layout"])
        return cmdFuzzLayout(argc > 2 ? MAX(1, atol(argv[2])) : 10000, argc > 3 ? atol(argv[3]) : 1);
    if ([mode isEqualToString:@"--bench-windows"]) return cmdBenchWindows(argc > 2 ? MAX(1, atoi(argv[2])) : 1);
    if ([mode isEqualToString:@"--request-access"]) {
        BOOL ok = CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess();
        AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)@{ (__bridge id)kAXTrustedCheckOptionPrompt: @YES });
        return ok ? 0 : 1;
    }
    if (mode.length) { fprintf(stderr, "usage: spaceview [--bench [passes]|--bench-windows [passes]|--fuzz-layout [iters] [seed]|--probe-sharing|--request-access]\n"); return 2; }

    BOOL screenOK = CGPreflightScreenCaptureAccess(), axOK = AXIsProcessTrusted();
    LOG("pid %d, screen recording %d, accessibility %d, capture symbol %d",
        getpid(), screenOK, axOK, captureF != NULL);
    previewsOn = screenOK && captureF;
    if (!previewsOn) LOG("previews off");
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

    // a dev build next to the installed agent listens on its own name, or one
    // spacetool view would open both panels
    const char *dev = getenv("SPACEVIEW_TOGGLE");
    NSString *toggle = dev && *dev ? @(dev) : kToggle;
    LOG("toggle notification %{public}@", toggle);
    [[NSDistributedNotificationCenter defaultCenter] addObserverForName:toggle object:nil
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
