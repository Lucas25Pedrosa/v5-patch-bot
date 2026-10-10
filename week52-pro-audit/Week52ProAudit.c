// Week52ProAudit 0.1
// Authorized security PoC for 52 Week Challenge 5.1.1.
// Scope: Economy.app main executable only, with an exact byte-signature guard.
//
// The PoC demonstrates whether the app's local Pro predicate is a sufficient
// authorization gate. It does not forge receipts, alter RevenueCat servers,
// or perform StoreKit transactions.

typedef unsigned long usize;
typedef unsigned char u8;
typedef int bool32;

extern const void *_dyld_get_image_header(unsigned int image_index);
extern const char *_dyld_get_image_name(unsigned int image_index);
extern void *dlsym(void *handle, const char *symbol);

#define RTLD_DEFAULT ((void *)-2L)
#define TARGET_OFFSET ((usize)0x23E3AC)

typedef void (*MSHookFunction_t)(void *symbol, void *replace, void **result);
typedef int (*DobbyHook_t)(void *address, void *replace_call, void **origin_call);

__attribute__((used))
static const char kAuditMarker[] = "Week52 Pro Audit 0.1 | 5.1.1 | gate+0x23E3AC";

static usize cstrlen(const char *s) {
    usize n = 0;
    if (!s) return 0;
    while (s[n]) n++;
    return n;
}

static int ends_with(const char *s, const char *suffix) {
    usize a = cstrlen(s), b = cstrlen(suffix);
    if (b > a) return 0;
    for (usize i = 0; i < b; i++) {
        if (s[a - b + i] != suffix[i]) return 0;
    }
    return 1;
}

static int bytes_equal(const volatile u8 *p, const u8 *expected, usize n) {
    for (usize i = 0; i < n; i++) {
        if (p[i] != expected[i]) return 0;
    }
    return 1;
}

// The analyzed Swift predicate returns Bool in w0. Returning C int 1 places
// the same true value in w0 while ignoring the original Swift context.
__attribute__((noinline))
static bool32 force_pro_gate(void) {
    return 1;
}

__attribute__((constructor))
static void Week52ProAuditInit(void) {
    const char *main_image = _dyld_get_image_name(0);
    if (!main_image || !ends_with(main_image, "/Economy.app/Economy")) return;

    // Original first 16 bytes at Economy + 0x23E3AC in 5.1.1 build 1.
    // If an update changes the function, the tweak deliberately does nothing.
    const u8 expected[16] = {
        0xff, 0x03, 0x01, 0xd1,
        0xf6, 0x57, 0x01, 0xa9,
        0xf4, 0x4f, 0x02, 0xa9,
        0xfd, 0x7b, 0x03, 0xa9
    };

    const u8 *base = (const u8 *)_dyld_get_image_header(0);
    if (!base) return;

    void *target = (void *)(base + TARGET_OFFSET);
    if (!bytes_equal((const volatile u8 *)target, expected, sizeof(expected))) return;

    // The Injector's zx-compat layer already carries CydiaSubstrate. Resolve
    // it at runtime so this dylib has no hard load-command dependency on it.
    MSHookFunction_t substrate = (MSHookFunction_t)dlsym(RTLD_DEFAULT, "MSHookFunction");
    if (substrate) {
        substrate(target, (void *)&force_pro_gate, (void **)0);
        return;
    }

    // Optional fallback for test environments that provide Dobby instead.
    DobbyHook_t dobby = (DobbyHook_t)dlsym(RTLD_DEFAULT, "DobbyHook");
    if (dobby) {
        (void)dobby(target, (void *)&force_pro_gate, (void **)0);
    }
}
