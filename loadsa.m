// loadsa - injects the spacetoosa payload into the Dock and WindowManager.
// Runs as root, takes no arguments (the sudoers pin allows none): for each
// target, task_for_pid, write a small shellcode stub that
// spawns a proper pthread calling dlopen on the payload, then run it via a
// converted arm64e thread state. Ported from yabai's src/osax/loader.m (MIT);
// the arm64e injection path there is based on work by Jeremy Legendre.
// Needs the csrutil relaxations from docs/window-on-all-spaces.md plus the
// -arm64e_preview_abi boot-arg (this loader and the payload are arm64e).
//
// Unlike yabai's loader, this one reports whether the injection actually
// took: the pthread stub stores dlopen's handle and dlerror's message
// pointer into a slot on the injected stack, which this loader reads back,
// and the exit code is 0 only once the payload's socket answers.
#import <Cocoa/Cocoa.h>
#import <dlfcn.h>
#import <mach/mach.h>
#import <mach/mach_vm.h>
#import <ptrauth.h>
#import <stdio.h>
#import <string.h>
#import <sys/socket.h>
#import <sys/un.h>
#import <unistd.h>
extern int *__error(void);

kern_return_t (*_thread_convert_thread_state)(thread_act_t thread, int direction, thread_state_flavor_t flavor, thread_state_t in_state, mach_msg_type_number_t in_stateCnt, thread_state_t out_state, mach_msg_type_number_t *out_stateCnt);

static const char *payload_path =
    "/Library/ScriptingAdditions/spacetools.osax/Contents/MacOS/spacetoosa";

// shellcode v3, assembled from loadsa-shellcode.s (assembler-verified
// encodings; keep the .s and the array in sync). the old yabai bytes
// discarded both the pthread_create_from_mach_thread and the dlopen
// result, so "payload injected" printed even when dlopen never took.
// entry: call pthread_create_from_mach_thread(&pth, 0, stub, 0),
// pre-zeroing the pth out-slot (entry_sp - 0x28, 0 = creation failed), set
// x0 to the magic and spin until the loader polls it. stub: dlopen
// (payload_path, RTLD_LAZY), then dlerror(), then __error(); store
// {handle, message pointer, errno} into the 24-byte result slot the loader
// patches in below, dmb ish so the slot is visible before the poll.
// patch offsets (verified against the v3 disassembly): +88
// pthread_create_from_mach_thread, +208 dlopen, +216 dlerror, +224
// __error, +232 result slot address, +240 payload_path.
static char shell_code[] =
"\xFF\xC3\x00\xD1"                          // sub	sp, sp, #0x30
"\xFD\x7B\x02\xA9"                          // stp	x29, x30, [sp, #0x20]
"\xFD\x83\x00\x91"                          // add	x29, sp, #0x20
"\xA0\xC3\x1F\xB8"                          // stur	w0, [x29, #-0x4]
"\xE1\x0B\x00\xF9"                          // str	x1, [sp, #0x10]
"\xE0\x23\x00\x91"                          // add	x0, sp, #0x8
"\x08\x00\x80\xD2"                          // mov	x8, #0x0
"\xE8\x07\x00\xF9"                          // str	x8, [sp, #0x8]
"\xE1\x03\x08\xAA"                          // mov	x1, x8
"\xE2\x01\x00\x10"                          // adr	x2, #60
"\xE2\x23\xC1\xDA"                          // paciza	x2
"\xE3\x03\x08\xAA"                          // mov	x3, x8
"\x49\x01\x00\x10"                          // adr	x9, #40
"\x29\x01\x40\xF9"                          // ldr	x9, [x9]
"\x20\x01\x3F\xD6"                          // blr	x9
"\xA0\x4C\x8C\xD2"                          // mov	x0, #0x6265
"\x20\x2C\xAF\xF2"                          // movk	x0, #0x7961, lsl #16
"\x09\x00\x00\x10"                          // adr	x9, #0
"\x20\x01\x1F\xD6"                          // br	x9
"\xFD\x7B\x42\xA9"                          // ldp	x29, x30, [sp, #0x20]
"\xFF\xC3\x00\x91"                          // add	sp, sp, #0x30
"\xC0\x03\x5F\xD6"                          // ret
"\x00\x00\x00\x00\x00\x00\x00\x00"                         // +88  pthread_create_from_mach_thread
"\x7F\x23\x03\xD5"                          // pacibsp
"\xFF\xC3\x00\xD1"                          // sub	sp, sp, #0x30
"\xFD\x7B\x02\xA9"                          // stp	x29, x30, [sp, #0x20]
"\xFD\x83\x00\x91"                          // add	x29, sp, #0x20
"\xF3\x53\x00\xA9"                          // stp	x19, x20, [sp]
"\xF3\x02\x00\x10"                          // adr	x19, #92
"\x73\x02\x40\xF9"                          // ldr	x19, [x19]
"\x60\x82\x00\x91"                          // add	x0, x19, #0x20
"\xE1\x03\x1F\xAA"                          // mov	x1, xzr
"\xA2\x05\x00\x10"                          // adr	x2, #180
"\xE2\x23\xC1\xDA"                          // paciza	x2
"\xE3\x03\x1F\xAA"                          // mov	x3, xzr
"\x09\x01\x00\x10"                          // adr	x9, #32
"\x29\x01\x40\xF9"                          // ldr	x9, [x9]
"\x20\x01\x3F\xD6"                          // blr	x9
"\x60\x02\x00\xF9"                          // str	x0, [x19]
"\xF3\x53\x40\xA9"                          // ldp	x19, x20, [sp]
"\xFD\x7B\x42\xA9"                          // ldp	x29, x30, [sp, #0x20]
"\xFF\xC3\x00\x91"                          // add	sp, sp, #0x30
"\xFF\x0F\x5F\xD6"                          // retab
"\x00\x00\x00\x00\x00\x00\x00\x00"                         // +176 pthread_create
"\x00\x00\x00\x00\x00\x00\x00\x00"                         // +184 dlopen
"\x00\x00\x00\x00\x00\x00\x00\x00"                         // +192 dlerror
"\x00\x00\x00\x00\x00\x00\x00\x00"                         // +200 __error
"\x00\x00\x00\x00\x00\x00\x00\x00"                         // +208 result slot address (patched to the injected stack)
"\x00\x00\x00\x00\x00\x00\x00\x00"                         // payload_path
"\x00\x00\x00\x00\x00\x00\x00\x00"                         //
"\x00\x00\x00\x00\x00\x00\x00\x00"                         //
"\x00\x00\x00\x00\x00\x00\x00\x00"                         //
"\x00\x00\x00\x00\x00\x00\x00\x00"                         //
"\x00\x00\x00\x00\x00\x00\x00\x00"                         //
"\x00\x00\x00\x00\x00\x00\x00\x00"                         //
"\x00\x00\x00\x00\x00\x00\x00\x00"                         //
"\x00\x00\x00\x00\x00\x00\x00\x00"                         //
"\x00\x00\x00\x00\x00\x00\x00\x00"                         //
"\x00\x00\x00\x00\x00\x00\x00\x00"                         //
"\x00\x00\x00\x00\x00\x00\x00\x00"                         //
"\x7F\x23\x03\xD5"                          // pacibsp
"\xFF\xC3\x00\xD1"                          // sub	sp, sp, #0x30
"\xFD\x7B\x02\xA9"                          // stp	x29, x30, [sp, #0x20]
"\xFD\x83\x00\x91"                          // add	x29, sp, #0x20
"\xF3\x53\x00\xA9"                          // stp	x19, x20, [sp]
"\x33\xFC\xFF\x10"                          // adr	x19, #-124
"\x73\x02\x40\xF9"                          // ldr	x19, [x19]
"\x21\x00\x80\xD2"                          // mov	x1, #0x1
"\x00\xFC\xFF\x10"                          // adr	x0, #-128
"\xE9\xFA\xFF\x10"                          // adr	x9, #-164
"\x29\x01\x40\xF9"                          // ldr	x9, [x9]
"\x20\x01\x3F\xD6"                          // blr	x9
"\xF4\x03\x00\xAA"                          // mov	x20, x0
"\xA9\xFA\xFF\x10"                          // adr	x9, #-172
"\x29\x01\x40\xF9"                          // ldr	x9, [x9]
"\x20\x01\x3F\xD6"                          // blr	x9
"\x74\x06\x00\xF9"                          // str	x20, [x19, #0x8]
"\x60\x0A\x00\xF9"                          // str	x0, [x19, #0x10]
"\x49\xFA\xFF\x10"                          // adr	x9, #-184
"\x29\x01\x40\xF9"                          // ldr	x9, [x9]
"\x20\x01\x3F\xD6"                          // blr	x9
"\x09\x00\x40\xB9"                          // ldr	w9, [x0]
"\x69\x0E\x00\xF9"                          // str	x9, [x19, #0x18]
"\xBF\x3B\x03\xD5"                          // dmb	ish
"\xF3\x53\x40\xA9"                          // ldp	x19, x20, [sp]
"\xFD\x7B\x42\xA9"                          // ldp	x29, x30, [sp, #0x20]
"\xFF\xC3\x00\x91"                          // add	sp, sp, #0x30
"\xFF\x0F\x5F\xD6";                          // retab (stub3 end)

// patch offsets into shell_code (see the v2 comment above)
enum { OFF_PCFMT = 88, OFF_STUB2 = 96, OFF_PTHREAD_CREATE = 176,
       OFF_DLOPEN = 184, OFF_DLERROR = 192, OFF_ERRNO = 200,
       OFF_SLOT = 208, OFF_PATH = 216, OFF_STUB3 = 312 };
_Static_assert(sizeof(shell_code) == 425, "shellcode v4 layout changed");

// the pthread stub reports {dlopen handle, dlerror message pointer} into
// stack[0..16]; this sentinel distinguishes "not reported yet" from NULL
static const uint64_t result_sentinel[5] = {
    0x0B1E5ED05E5E7775ULL, 0x0B1E5ED05E5E7775ULL, 0x0B1E5ED05E5E7775ULL,
    0x0B1E5ED05E5E7775ULL, 0x0B1E5ED05E5E7775ULL };

// WindowManager is a launchd agent and never reports isFinishedLaunching
typedef struct { const char *name, *bundle, *socket; BOOL needsLaunched; } Target;
static const Target targets[] = {
    { "Dock", "com.apple.dock", "spacetool-sa", YES },
    { "WindowManager", "com.apple.WindowManager", "spacetool-sa-wm", NO },
};

static pid_t targetPid(const Target *t) {
    NSArray *list = [NSRunningApplication
        runningApplicationsWithBundleIdentifier:@(t->bundle)];
    if (list.count == 1 && (!t->needsLaunched || [list[0] isFinishedLaunching]))
        return [list[0] processIdentifier];
    return 0;
}

// sudo resets USER to root; the socket belongs to the invoking user
static int payloadActive(const Target *t) {
    const char *user = getenv("SUDO_USER") ?: getenv("USER");
    if (!user) return 0;
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return 0;
    struct timeval tv = { .tv_sec = 0, .tv_usec = 250000 };
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
    struct sockaddr_un a;
    memset(&a, 0, sizeof a);
    a.sun_family = AF_UNIX;
    snprintf(a.sun_path, sizeof a.sun_path, "/tmp/%s_%s.socket", t->socket, user);
    if (connect(fd, (struct sockaddr *)&a, sizeof a) < 0) { close(fd); return 0; }
    uint8_t op = 1, rep[5];   // OP_HELLO
    int alive = write(fd, &op, 1) == 1 && read(fd, rep, sizeof rep) == (ssize_t)sizeof rep;
    close(fd);
    return alive;
}

static int readWord(mach_port_t task, uint64_t addr, uint64_t *out) {
    mach_vm_size_t n = 0;
    if (mach_vm_read_overwrite(task, addr, sizeof *out,
            (mach_vm_address_t)out, &n) != KERN_SUCCESS || n != sizeof *out) {
        fprintf(stderr, "loadsa: could not read back %llu in the target\n",
                (unsigned long long)addr);
        return 1;
    }
    return 0;
}

// after the entry stub signalled: the pcfmt thread (stub2) stores its
// pthread_create rc at slot[0], then the normal pthread it spawned (stub3)
// stores {dlopen handle, dlerror message pointer, errno} at slot[1..3].
// 0 only once the payload's socket answers does the injection count as
// done. the old "payload injected" message printed on the stub magic alone
// and lied whenever dlopen failed inside the target, which is what hid the
// WindowManager failure in the first place.
static int reportResult(const Target *t, mach_port_t task, uint64_t stack,
                        vm_size_t stack_size, pid_t pid) {
    const char *name = t->name;
    uint64_t pth = 0;
    if (readWord(task, stack + stack_size / 2 - 0x28, &pth)) return 1;
    if (!pth) {
        fprintf(stderr, "loadsa: %s: stub ran but pthread_create_from_mach_thread"
                        " created no pthread (pid %d)\n", name, pid);
        return 1;
    }
    fprintf(stderr, "loadsa: %s: pcfmt thread up (0x%llx), waiting for"
                    " pthread_create\n", name, (unsigned long long)pth);

    uint64_t rc = 0;
    for (int i = 0; i < 100; ++i) {
        if (readWord(task, stack, &rc)) return 1;
        if (rc != result_sentinel[0]) break;
        usleep(100000);
    }
    if (rc == result_sentinel[0]) {
        fprintf(stderr, "loadsa: %s: stub2 never reported (pthread_create did not"
                        " return within 10s)\n", name);
        return 1;
    }
    if (rc != 0) {
        fprintf(stderr, "loadsa: %s: pthread_create on the pcfmt thread failed:"
                        " rc %llu\n", name, (unsigned long long)rc);
        return 1;
    }

    uint64_t handle = 0, msg = 0, err_no = 0;
    for (int i = 0; i < 100; ++i) {
        if (readWord(task, stack + 8, &handle)) return 1;
        if (handle != result_sentinel[1]) {
            if (readWord(task, stack + 16, &msg)) return 1;
            if (readWord(task, stack + 24, &err_no)) return 1;
            break;
        }
        usleep(100000);
    }
    if (handle == result_sentinel[1]) {
        fprintf(stderr, "loadsa: %s: stub3 never reported; dlopen did not"
                        " return within 10s\n", name);
        return 1;
    }
    if (!handle) {
        char err[256] = "(no dlerror message)";
        if (msg) {
            mach_vm_size_t n = 0;
            if (mach_vm_read_overwrite(task, msg, sizeof err - 1,
                    (mach_vm_address_t)err, &n) != KERN_SUCCESS || !n)
                strcpy(err, "(dlerror message unreadable)");
            else err[n < sizeof err - 1 ? n : sizeof err - 1] = 0;
        }
        fprintf(stderr, "loadsa: %s: dlopen failed (errno %llu): %s\n", name,
                (unsigned long long)err_no,
                err[0] ? err : "(empty dlerror message; pthread TSD may be"
                               " unavailable on mach-converted threads)");
        return 1;
    }
    fprintf(stderr, "loadsa: %s: dlopen succeeded (handle 0x%llx), waiting for"
                    " the payload socket\n", name, (unsigned long long)handle);
    for (int i = 0; i < 100; ++i) {
        if (payloadActive(t)) {
            fprintf(stderr, "loadsa: payload injected into %s (pid %d)\n", name, pid);
            return 0;
        }
        usleep(100000);
    }
    fprintf(stderr, "loadsa: %s: dlopen succeeded but the payload socket never"
                    " came up (constructor did not finish)\n", name);
    return 1;
}

static int inject(const Target *t) {
    const char *name = t->name;
    int result = 1;
    mach_port_t task = 0;
    thread_act_t thread = 0;
    mach_vm_address_t code = 0, stack = 0;
    vm_size_t stack_size = 16 * 1024;
    pid_t pid = targetPid(t);

    if (!pid) { fprintf(stderr, "loadsa: could not locate %s pid\n", name); return 1; }
    if (payloadActive(t)) {
        fprintf(stderr, "loadsa: payload already active in %s (pid %d)\n", name, pid);
        return 0;
    }
    if (task_for_pid(mach_task_self(), pid, &task) != KERN_SUCCESS) {
        fprintf(stderr, "loadsa: no task port for %s (pid %d). run as root"
                        " with Debugging Restrictions disabled\n", name, pid);
        return 1;
    }
    if (mach_vm_allocate(task, &stack, stack_size, VM_FLAGS_ANYWHERE) != KERN_SUCCESS) {
        fprintf(stderr, "loadsa: could not allocate stack\n"); return 1;
    }
    if (mach_vm_write(task, stack, (vm_address_t)result_sentinel, sizeof result_sentinel) != KERN_SUCCESS) {
        fprintf(stderr, "loadsa: could not write stack\n"); return 1;
    }
    if (vm_protect(task, stack, stack_size, 1, VM_PROT_READ | VM_PROT_WRITE) != KERN_SUCCESS) {
        fprintf(stderr, "loadsa: could not protect stack\n"); return 1;
    }
    if (mach_vm_allocate(task, &code, sizeof(shell_code), VM_FLAGS_ANYWHERE) != KERN_SUCCESS) {
        fprintf(stderr, "loadsa: could not allocate code\n"); return 1;
    }

    uint64_t pcfmt_address = (uint64_t)ptrauth_strip(
        dlsym(RTLD_DEFAULT, "pthread_create_from_mach_thread"),
        ptrauth_key_function_pointer);
    uint64_t pthread_create_address = (uint64_t)ptrauth_strip(
        dlsym(RTLD_DEFAULT, "pthread_create"), ptrauth_key_function_pointer);
    uint64_t dlopen_address = (uint64_t)ptrauth_strip(
        dlsym(RTLD_DEFAULT, "dlopen"), ptrauth_key_function_pointer);
    uint64_t dlerror_address = (uint64_t)ptrauth_strip(
        dlsym(RTLD_DEFAULT, "dlerror"), ptrauth_key_function_pointer);
    uint64_t errno_address = (uint64_t)ptrauth_strip(
        (void *)__error, ptrauth_key_function_pointer);
    memcpy(shell_code + OFF_PCFMT, &pcfmt_address, sizeof(uint64_t));
    memcpy(shell_code + OFF_PTHREAD_CREATE, &pthread_create_address, sizeof(uint64_t));
    memcpy(shell_code + OFF_DLOPEN, &dlopen_address, sizeof(uint64_t));
    memcpy(shell_code + OFF_DLERROR, &dlerror_address, sizeof(uint64_t));
    memcpy(shell_code + OFF_ERRNO, &errno_address, sizeof(uint64_t));
    memcpy(shell_code + OFF_SLOT, &stack, sizeof(uint64_t));
    memcpy(shell_code + OFF_PATH, payload_path, strlen(payload_path) + 1);

    if (mach_vm_write(task, code, (vm_address_t)shell_code, sizeof(shell_code)) != KERN_SUCCESS) {
        fprintf(stderr, "loadsa: could not write shellcode\n"); return 1;
    }
    if (vm_protect(task, code, sizeof(shell_code), 0, VM_PROT_EXECUTE | VM_PROT_READ) != KERN_SUCCESS) {
        fprintf(stderr, "loadsa: could not protect code\n"); return 1;
    }

    void *handle = dlopen("/usr/lib/system/libsystem_kernel.dylib", RTLD_GLOBAL | RTLD_LAZY);
    if (handle) {
        _thread_convert_thread_state = dlsym(handle, "thread_convert_thread_state");
        dlclose(handle);
    }
    if (!_thread_convert_thread_state) {
        fprintf(stderr, "loadsa: no thread_convert_thread_state symbol\n"); return 1;
    }

    arm_thread_state64_t thread_state = {}, machine_thread_state = {};
    thread_state_flavor_t thread_flavor = ARM_THREAD_STATE64;
    mach_msg_type_number_t thread_flavor_count = ARM_THREAD_STATE64_COUNT,
                           machine_flavor_count = ARM_THREAD_STATE64_COUNT;

    __darwin_arm_thread_state64_set_pc_fptr(thread_state,
        ptrauth_sign_unauthenticated((void *)code, ptrauth_key_asia, 0));
    __darwin_arm_thread_state64_set_sp(thread_state, stack + (stack_size / 2));

    kern_return_t error = thread_create(task, &thread);
    if (error != KERN_SUCCESS) {
        fprintf(stderr, "loadsa: could not create remote thread: %s\n", mach_error_string(error));
        return 1;
    }
    error = _thread_convert_thread_state(thread, 2, thread_flavor,
        (thread_state_t)&thread_state, thread_flavor_count,
        (thread_state_t)&machine_thread_state, &machine_flavor_count);
    if (error != KERN_SUCCESS) {
        fprintf(stderr, "loadsa: could not convert thread state: %s\n", mach_error_string(error));
        return 1;
    }

    // 14.4+ / 15+ rejects set_state+resume on a fresh thread; terminate and
    // respawn already running with the converted state instead
    if (NSProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 15) {
        thread_terminate(thread);
        error = thread_create_running(task, thread_flavor,
            (thread_state_t)&machine_thread_state, machine_flavor_count, &thread);
        if (error != KERN_SUCCESS) {
            fprintf(stderr, "loadsa: could not spawn remote thread: %s\n", mach_error_string(error));
            return 1;
        }
    } else {
        error = thread_set_state(thread, thread_flavor,
            (thread_state_t)&machine_thread_state, machine_flavor_count);
        if (error != KERN_SUCCESS) {
            fprintf(stderr, "loadsa: could not set thread state: %s\n", mach_error_string(error));
            return 1;
        }
        error = thread_resume(thread);
        if (error != KERN_SUCCESS) {
            fprintf(stderr, "loadsa: could not resume remote thread: %s\n", mach_error_string(error));
            return 1;
        }
    }

    usleep(10000);
    for (int i = 0; i < 10; ++i) {
        error = thread_get_state(thread, thread_flavor,
            (thread_state_t)&thread_state, &thread_flavor_count);
        if (error != KERN_SUCCESS) goto terminate;
        if (thread_state.__x[0] == 0x79616265) { result = 0; goto terminate; }
        usleep(20000);
    }
    fprintf(stderr, "loadsa: shellcode did not signal completion\n");

terminate:
    thread_terminate(thread);
    if (result == 0) result = reportResult(t, task, stack, stack_size, pid);
    return result;
}

int main(int argc, char **argv) {
    (void)argc; (void)argv;
    // experiment knob: the sudoers pin allows no arguments and sudo strips
    // the environment, so a path override for load experiments lives in a
    // file. write the file as the invoking user before the sudo run.
    char override[256];
    FILE *f = fopen("/tmp/spacetool-loadsa-payload", "r");
    if (f) {
        size_t n = fread(override, 1, sizeof override - 1, f);
        fclose(f);
        while (n && (override[n - 1] == '\n' || override[n - 1] == '\r')) n--;
        override[n] = 0;
        if (n) {
            payload_path = strdup(override);
            fprintf(stderr, "loadsa: payload path override: %s\n", payload_path);
        }
    }
    int failed = 0;
    for (size_t i = 0; i < sizeof targets / sizeof targets[0]; i++) failed |= inject(&targets[i]);
    return failed;
}
