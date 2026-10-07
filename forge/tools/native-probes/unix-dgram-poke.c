/* unix-dgram-poke — send one datagram to an ABSTRACT unix socket, to drive an OEM daemon's
 * message dispatcher yourself instead of waiting for whatever normally talks to it.
 *
 *   unix-dgram-poke <abstract-name> <msg-id> [size]      size defaults to 524
 *   unix-dgram-poke /tmp/ims/wms/wms_proxy 1 524
 *
 * Give the name WITHOUT the leading @: abstract sockets are sun_path[0] == '\0' followed by the
 * name, which is what the @ in /proc/net/unix is rendering.
 *
 * WHY. An OEM daemon is usually a select/recvfrom loop over a fixed-size struct whose first u32 is
 * a message id, dispatched through a jump table. Find the table (disassemble the loop; the bounds
 * check right before `br` gives you the valid range) and you can drive any branch on demand --
 * seconds per experiment instead of rebooting and hoping the OEM app is in the right state to send
 * the message you need. On the V20 this turned "SMS over IMS fails somewhere" into a controlled
 * A/B: message id 1 was the only caller of the QMI init path, and nothing else reached it.
 *
 * The payload is zeroed apart from the id, so fields the handler reads come through as 0. That is
 * enough to reach a branch; it is not enough to imitate a real caller, and a handler that reads a
 * status field will see "not ready" rather than whatever the real sender meant.
 *
 * Freestanding aarch64: raw syscalls, no libc, so it runs on any Android version and in recovery.
 * Build: tools/freestanding-arm64.sh, or any aarch64 gcc with -nostdlib -static -ffreestanding.
 */
#define SYS_socket  198
#define SYS_sendto  206
#define SYS_write    64
#define SYS_exit     93
#define AF_UNIX       1
#define SOCK_DGRAM    2

static long sc(long n,long a,long b,long c,long d,long e,long f){
    register long x8 __asm__("x8")=n,x0 __asm__("x0")=a,x1 __asm__("x1")=b,x2 __asm__("x2")=c,
                  x3 __asm__("x3")=d,x4 __asm__("x4")=e,x5 __asm__("x5")=f;
    __asm__ volatile("svc #0":"+r"(x0):"r"(x8),"r"(x1),"r"(x2),"r"(x3),"r"(x4),"r"(x5):"memory");
    return x0;
}
static void put(const char*s){long n=0;while(s[n])n++;sc(SYS_write,1,(long)s,n,0,0,0);}
static void putn(long v){char b[24];int i=22;b[23]=0;if(!v){put("0");return;}
    int neg=v<0;if(neg)v=-v;while(v&&i){b[i--]='0'+(v%10);v/=10;}if(neg)b[i--]='-';put(&b[i+1]);}
static unsigned pnum(const char*p){unsigned v=0;while(*p>='0'&&*p<='9')v=v*10+(*p++-'0');return v;}

void _start_c(long *sp){
    long argc=sp[0]; char **argv=(char**)&sp[1];
    if (argc < 3) { put("usage: unix-dgram-poke <abstract-name> <msg-id> [size]\n"); sc(SYS_exit,2,0,0,0,0,0); }
    const char *name = argv[1];
    unsigned id = pnum(argv[2]);
    unsigned size = (argc > 3) ? pnum(argv[3]) : 524;
    if (size < 4) size = 4;
    if (size > 4096) size = 4096;

    int fd = (int)sc(SYS_socket, AF_UNIX, SOCK_DGRAM, 0,0,0,0);
    if (fd < 0){ put("socket failed\n"); sc(SYS_exit,3,0,0,0,0,0); }

    char addr[110];                                   /* sockaddr_un: u16 family + 108 path */
    for (int i=0;i<110;i++) addr[i]=0;
    addr[0]=AF_UNIX; addr[1]=0;
    int n=0; while(name[n] && n < 106){ addr[2+1+n]=name[n]; n++; }   /* leading NUL = abstract */
    int addrlen = 2 + 1 + n;

    char msg[4096];
    for (unsigned i=0;i<size;i++) msg[i]=0;
    msg[0]=(char)(id&0xff); msg[1]=(char)((id>>8)&0xff);
    msg[2]=(char)((id>>16)&0xff); msg[3]=(char)((id>>24)&0xff);

    long r = sc(SYS_sendto, fd, (long)msg, size, 0, (long)addr, addrlen);
    if (r < 0){ put("sendto failed errno="); putn(-r); put(" (is the daemon running?)\n"); sc(SYS_exit,4,0,0,0,0,0); }
    put("sent id "); putn(id); put(" to @"); put(name); put(", "); putn(r); put(" bytes\n");
    sc(SYS_exit,0,0,0,0,0,0);
}
__asm__(".global _start\n_start:\n mov x0, sp\n b _start_c\n");
