// loadsa - injects the spacetoosa payload into the Dock.
// Runs as root: task_for_pid on the Dock, write a small shellcode stub that
// spawns a proper pthread calling dlopen on the payload, then run it via a
// converted arm64e thread state. Ported from yabai's src/osax/loader.m (MIT);
// the arm64e injection path there is based on work by Jeremy Legendre.
// Needs the csrutil relaxations from SA-PLAN.md plus the
// -arm64e_preview_abi boot-arg (this loader and the payload are arm64e).
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

kern_return_t (*_thread_convert_thread_state)(thread_act_t thread, int direction, thread_state_flavor_t flavor, thread_state_t in_state, mach_msg_type_number_t in_stateCnt, thread_state_t out_state, mach_msg_type_number_t *out_stateCnt);

static const char *payload_path =
    "/Library/ScriptingAdditions/spacetools.osax/Contents/MacOS/spacetoosa";

// entry: call pthread_create_from_mach_thread(stub, path), set x0 to the
// magic and spin until the loader polls it. stub: dlopen(payload_path, 1).
// patch offsets: +88 pthread_create_from_mach_thread, +160 dlopen,
// +168 payload_path (same as yabai's loader).
static char shell_code[] =
"\xFF\xC3\x00\xD1"                 // sub        sp, sp, #0x30
"\xFD\x7B\x02\xA9"                 // stp        x29, x30, [sp, #0x20]
"\xFD\x83\x00\x91"                 // add        x29, sp, #0x20
"\xA0\xC3\x1F\xB8"                 // stur       w0, [x29, #-0x4]
"\xE1\x0B\x00\xF9"                 // str        x1, [sp, #0x10]
"\xE0\x23\x00\x91"                 // add        x0, sp, #0x8
"\x08\x00\x80\xD2"                 // mov        x8, #0
"\xE8\x07\x00\xF9"                 // str        x8, [sp, #0x8]
"\xE1\x03\x08\xAA"                 // mov        x1, x8
"\xE2\x01\x00\x10"                 // adr        x2, #0x3C
"\xE2\x23\xC1\xDA"                 // paciza     x2
"\xE3\x03\x08\xAA"                 // mov        x3, x8
"\x49\x01\x00\x10"                 // adr        x9, #0x28 ; pthread_create_from_mach_thread
"\x29\x01\x40\xF9"                 // ldr        x9, [x9]
"\x20\x01\x3F\xD6"                 // blr        x9
"\xA0\x4C\x8C\xD2"                 // movz       x0, #0x6265
"\x20\x2C\xAF\xF2"                 // movk       x0, #0x7961, lsl #16
"\x09\x00\x00\x10"                 // adr        x9, #0
"\x20\x01\x1F\xD6"                 // br         x9
"\xFD\x7B\x42\xA9"                 // ldp        x29, x30, [sp, #0x20]
"\xFF\xC3\x00\x91"                 // add        sp, sp, #0x30
"\xC0\x03\x5F\xD6"                 // ret
"\x00\x00\x00\x00\x00\x00\x00\x00" //
"\x7F\x23\x03\xD5"                 // pacibsp
"\xFF\xC3\x00\xD1"                 // sub        sp, sp, #0x30
"\xFD\x7B\x02\xA9"                 // stp        x29, x30, [sp, #0x20]
"\xFD\x83\x00\x91"                 // add        x29, sp, #0x20
"\xA0\xC3\x1F\xB8"                 // stur       w0, [x29, #-0x4]
"\xE1\x0B\x00\xF9"                 // str        x1, [sp, #0x10]
"\x21\x00\x80\xD2"                 // mov        x1, #1
"\x60\x01\x00\x10"                 // adr        x0, #0x2c ; payload_path
"\x09\x01\x00\x10"                 // adr        x9, #0x20 ; dlopen
"\x29\x01\x40\xF9"                 // ldr        x9, [x9]
"\x20\x01\x3F\xD6"                 // blr        x9
"\x09\x00\x80\x52"                 // mov        w9, #0
"\xE0\x03\x09\xAA"                 // mov        x0, x9
"\xFD\x7B\x42\xA9"                 // ldp        x29, x30, [sp, #0x20]
"\xFF\xC3\x00\x91"                 // add        sp, sp, #0x30
"\xFF\x0F\x5F\xD6"                 // retab
"\x00\x00\x00\x00\x00\x00\x00\x00" //
"\x00\x00\x00\x00\x00\x00\x00\x00" // payload_path
"\x00\x00\x00\x00\x00\x00\x00\x00"
"\x00\x00\x00\x00\x00\x00\x00\x00"
"\x00\x00\x00\x00\x00\x00\x00\x00"
"\x00\x00\x00\x00\x00\x00\x00\x00"
"\x00\x00\x00\x00\x00\x00\x00\x00"
"\x00\x00\x00\x00\x00\x00\x00\x00"
"\x00\x00\x00\x00\x00\x00\x00\x00"
"\x00\x00\x00\x00\x00\x00\x00\x00"
"\x00\x00\x00\x00\x00\x00\x00\x00"
"\x00\x00\x00\x00\x00\x00\x00\x00"
"\x00\x00\x00\x00\x00\x00\x00\x00";

static pid_t get_dock_pid(void) {
    NSArray *list = [NSRunningApplication
        runningApplicationsWithBundleIdentifier:@"com.apple.dock"];
    if (list.count == 1 && [list[0] isFinishedLaunching])
        return [list[0] processIdentifier];
    return 0;
}

// sudo resets USER to root; the socket belongs to the invoking user
static int payloadActive(void) {
    const char *user = getenv("SUDO_USER") ?: getenv("USER");
    if (!user) return 0;
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return 0;
    struct timeval tv = { .tv_sec = 0, .tv_usec = 250000 };
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
    struct sockaddr_un a;
    memset(&a, 0, sizeof a);
    a.sun_family = AF_UNIX;
    snprintf(a.sun_path, sizeof a.sun_path, "/tmp/spacetool-sa_%s.socket", user);
    if (connect(fd, (struct sockaddr *)&a, sizeof a) < 0) { close(fd); return 0; }
    uint8_t op = 1, rep[5];   // OP_HELLO
    int alive = write(fd, &op, 1) == 1 && read(fd, rep, sizeof rep) == (ssize_t)sizeof rep;
    close(fd);
    return alive;
}

int main(int argc, char **argv) {
    (void)argc; (void)argv;
    int result = 1;
    mach_port_t task = 0;
    thread_act_t thread = 0;
    mach_vm_address_t code = 0, stack = 0;
    vm_size_t stack_size = 16 * 1024;
    uint64_t stack_contents = 0x00000000CAFEBABE;
    pid_t pid = get_dock_pid();

    if (!pid) { fprintf(stderr, "loadsa: could not locate Dock pid\n"); return 1; }
    if (payloadActive()) {
        fprintf(stderr, "loadsa: payload already active in Dock (pid %d)\n", pid);
        return 0;
    }
    if (task_for_pid(mach_task_self(), pid, &task) != KERN_SUCCESS) {
        fprintf(stderr, "loadsa: no task port for Dock (pid %d). run as root"
                        " with Debugging Restrictions disabled\n", pid);
        return 1;
    }
    if (mach_vm_allocate(task, &stack, stack_size, VM_FLAGS_ANYWHERE) != KERN_SUCCESS) {
        fprintf(stderr, "loadsa: could not allocate stack\n"); return 1;
    }
    if (mach_vm_write(task, stack, (vm_address_t)&stack_contents, sizeof(uint64_t)) != KERN_SUCCESS) {
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
    uint64_t dlopen_address = (uint64_t)ptrauth_strip(
        dlsym(RTLD_DEFAULT, "dlopen"), ptrauth_key_function_pointer);
    memcpy(shell_code + 88, &pcfmt_address, sizeof(uint64_t));
    memcpy(shell_code + 160, &dlopen_address, sizeof(uint64_t));
    memcpy(shell_code + 168, payload_path, strlen(payload_path));

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
    if (result == 0) fprintf(stderr, "loadsa: payload injected into Dock (pid %d)\n", pid);
    return result;
}
