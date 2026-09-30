// spacetoosa - Dock-hosted payload for per-window sticky spaces.
// Only the Dock's window-server connection can set window tag bit 11
// (onAllWorkspaces); every other writer is silently gated
// (docs/window-on-all-spaces.md). This dylib is dlopen'd into the Dock by
// loadsa; its constructor opens /tmp/spacetool-sa_$USER.socket (0600) and
// serves four opcodes. Socket shape ported from yabai's osax payload
// (MIT, src/osax/payload.m).
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <dlfcn.h>
#import <errno.h>
#import <pthread.h>
#import <signal.h>
#import <sys/socket.h>
#import <sys/stat.h>
#import <sys/un.h>
#import <unistd.h>

typedef int (*ConnFn)(void);
typedef CGError (*TagsFn)(int, uint32_t, uint64_t *, size_t);
typedef CFTypeRef (*QueryWindowsFn)(int, CFArrayRef, int);
typedef CFTypeRef (*QueryResultCopyFn)(CFTypeRef);
typedef BOOL (*IterAdvanceFn)(CFTypeRef);
typedef uint32_t (*IterWidFn)(CFTypeRef);
typedef uint64_t (*IterTagsFn)(CFTypeRef);

enum { OP_HELLO = 1, OP_STICKY_SET = 2, OP_STICKY_CLEAR = 3, OP_STICKY_QUERY = 4 };
#define SA_PROTO_VERSION 1
#define STICKY_BIT 11

static int cid;
static TagsFn setTagsF, clearTagsF;
static QueryWindowsFn queryF;
static QueryResultCopyFn iterCopyF;
static IterAdvanceFn iterAdvF;
static IterWidFn iterWidF;
static IterTagsFn iterTagsF;

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
    if (op != OP_HELLO && !readN(fd, &wid, 4)) goto out;
    switch (op) {
    case OP_HELLO: {
        uint8_t r[5];
        uint32_t mask = (setTagsF ? 1u : 0u) | (clearTagsF ? 2u : 0u) | (queryF ? 4u : 0u);
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
    }
out:
    close(fd);
}

static void *serve(void *unused) {
    (void)unused;
    int s = socket(AF_UNIX, SOCK_STREAM, 0);
    if (s < 0) { NSLog(@"[spacetool-sa] socket: %s", strerror(errno)); return NULL; }
    const char *user = getenv("USER");
    if (!user) { NSLog(@"[spacetool-sa] no USER in Dock environment"); return NULL; }
    struct sockaddr_un addr;
    memset(&addr, 0, sizeof addr);
    addr.sun_family = AF_UNIX;
    snprintf(addr.sun_path, sizeof addr.sun_path, "/tmp/spacetool-sa_%s.socket", user);
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
    NSLog(@"[spacetool-sa] payload loaded");
    void *h = RTLD_DEFAULT;
    ConnFn connF = (ConnFn)dlsym(h, "SLSMainConnectionID");
    setTagsF = (TagsFn)dlsym(h, "SLSSetWindowTags");
    clearTagsF = (TagsFn)dlsym(h, "SLSClearWindowTags");
    queryF = (QueryWindowsFn)dlsym(h, "SLSWindowQueryWindows");
    iterCopyF = (QueryResultCopyFn)dlsym(h, "SLSWindowQueryResultCopyWindows");
    iterAdvF = (IterAdvanceFn)dlsym(h, "SLSWindowIteratorAdvance");
    iterWidF = (IterWidFn)dlsym(h, "SLSWindowIteratorGetWindowID");
    iterTagsF = (IterTagsFn)dlsym(h, "SLSWindowIteratorGetTags");
    if (!connF) { NSLog(@"[spacetool-sa] SLSMainConnectionID missing"); return; }
    cid = connF();
    NSLog(@"[spacetool-sa] cid %d set=%d clear=%d query=%d", cid,
           setTagsF != NULL, clearTagsF != NULL, queryF != NULL);
    if (!setTagsF && !clearTagsF && !queryF) return;
    // a client that vanishes mid-reply must not be able to SIGPIPE the Dock
    signal(SIGPIPE, SIG_IGN);
    pthread_t t;
    pthread_create(&t, NULL, serve, NULL);
    pthread_detach(t);
}
