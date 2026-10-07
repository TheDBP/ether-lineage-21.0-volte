/* run-as-gid — run a command with a chosen gid and supplementary groups.
 *
 *   run-as-gid <gid> <g1,g2,...> <prog> [args...]
 *   run-as-gid 1001 1001,1000,3004,3005 /data/local/tmp/some-oem-daemon
 *
 * WHY. Android has no setpriv, and several things are gated on GID rather than uid or SELinux --
 * the MSM IPC router checks sec_config's per-service GID list, and an OEM daemon that stock runs
 * as `group radio system net_admin net_raw` behaves differently from the same binary under a root
 * adb shell. Without this the only way to test that is to ship an init.rc and reflash, which is a
 * build per experiment. Keeps uid 0 deliberately: the point is to vary ONE thing.
 *
 * Freestanding aarch64: raw syscalls, no libc. Build: tools/freestanding-arm64.sh. */
#define SYS_setgid     144
#define SYS_setgroups  159
#define SYS_execve     221
#define SYS_write       64
#define SYS_exit        93

static long sc(long n, long a, long b, long c) {
    register long x8 __asm__("x8") = n, x0 __asm__("x0") = a, x1 __asm__("x1") = b, x2 __asm__("x2") = c;
    __asm__ volatile("svc #0" : "+r"(x0) : "r"(x8), "r"(x1), "r"(x2) : "memory");
    return x0;
}
static void put(const char *s){ long n=0; while(s[n]) n++; sc(SYS_write,2,(long)s,n); }
static int atoi_(const char *s){ int v=0; while(*s>='0'&&*s<='9') v=v*10+(*s++-'0'); return v; }

void _start_c(long *sp) {
    long argc = sp[0];
    char **argv = (char **)&sp[1];
    char **envp = argv + argc + 1;
    if (argc < 4) { put("usage: run-as-gid <gid> <g1,g2,...> <prog> [args]\n"); sc(SYS_exit,2,0,0); }

    int gid = atoi_(argv[1]);
    unsigned int groups[16]; int ng = 0;
    for (char *p = argv[2]; *p && ng < 16; ) {
        groups[ng++] = (unsigned)atoi_(p);
        while (*p && *p != ',') p++;
        if (*p == ',') p++;
    }
    if (sc(SYS_setgroups, ng, (long)groups, 0) < 0) { put("setgroups failed\n"); sc(SYS_exit,3,0,0); }
    if (sc(SYS_setgid, gid, 0, 0) < 0)              { put("setgid failed\n");    sc(SYS_exit,4,0,0); }
    sc(SYS_execve, (long)argv[3], (long)&argv[3], (long)envp);
    put("execve failed\n"); sc(SYS_exit,5,0,0);
}
__asm__(".global _start\n_start:\n mov x0, sp\n b _start_c\n");
