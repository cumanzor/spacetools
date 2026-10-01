// shellcode v2 for loadsa, written as real assembly so the encodings are
// assembler-verified, then extracted into loadsa.m's shell_code array.
// v1 (yabai's) proved the entry stub ran but discarded both the
// pthread_create_from_mach_thread and the dlopen result; this version has
// the pthread stub store dlopen's handle and dlerror's message pointer into
// a result slot (patched at _result_slot) that the loader reads back.
// slot = {dlopen handle, dlerror message pointer, errno}.
.text
.globl _entry
_entry:
    sub    sp, sp, #0x30
    stp    x29, x30, [sp, #0x20]
    add    x29, sp, #0x20
    stur   w0, [x29, #-0x4]
    str    x1, [sp, #0x10]
    add    x0, sp, #0x8          // pthread_t out-slot (entry_sp - 0x28)
    mov    x8, #0
    str    x8, [sp, #0x8]        // pre-zero it: 0 == pcfmt failed
    mov    x1, x8
    adr    x2, _stub
    paciza x2                    // start must be an IA-signed C pointer
    mov    x3, x8
    adr    x9, _pcfmt_slot
    ldr    x9, [x9]
    blr    x9                    // pthread_create_from_mach_thread(&pth, 0, stub, 0)
    movz   x0, #0x6265
    movk   x0, #0x7961, lsl #16  // 0x79616265: "stub ran" magic, loader polls x0
Lspin:
    adr    x9, Lspin
    br     x9                    // spin until the loader terminates this thread
    ldp    x29, x30, [sp, #0x20]
    add    sp, sp, #0x30
    ret
    .p2align 3
_pcfmt_slot:
    .quad  0                     // +88: pthread_create_from_mach_thread

.globl _stub
_stub:
    pacibsp
    sub    sp, sp, #0x30
    stp    x29, x30, [sp, #0x20]
    add    x29, sp, #0x20
    stp    x19, x20, [sp]        // callee-saved; the pthread body may hold live values
    adr    x19, _result_slot
    ldr    x19, [x19]            // x19 = result slot address (patched by the loader)
    mov    x1, #1                // RTLD_LAZY
    adr    x0, _path
    adr    x9, _dlopen_slot
    ldr    x9, [x9]
    blr    x9                    // dlopen(path, RTLD_LAZY); x0 = handle or NULL
    mov    x20, x0              // save the handle across dlerror
    adr    x9, _dlerror_slot
    ldr    x9, [x9]
    blr    x9                    // dlerror(); x0 = message pointer or NULL
    str    x20, [x19]            // slot[0] = dlopen handle
    str    x0, [x19, #8]         // slot[1] = dlerror message pointer
    adr    x9, __error_slot
    ldr    x9, [x9]
    blr    x9                    // __error(); x0 = &errno
    ldr    w9, [x0]              // errno (dyld's dlopen path leaves it from open/stat)
    str    x9, [x19, #0x10]      // slot[2] = errno
    dmb    ish                   // slot fully visible before the loader polls
    ldp    x19, x20, [sp]
    ldp    x29, x30, [sp, #0x20]
    add    sp, sp, #0x30
    retab
    .p2align 3
_dlopen_slot:
    .quad  0                     // +184: dlopen
_dlerror_slot:
    .quad  0
__error_slot:
    .quad  0                     // __error (errno TLS)
_result_slot:
    .quad  0                     // address of the 24-byte result slot
    .p2align 3
_path:
    .space 96                    // +208: payload path, 96 bytes
