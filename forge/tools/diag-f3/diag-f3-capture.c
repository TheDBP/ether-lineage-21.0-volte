/* Freestanding arm64 DIAG F3 dumper: open /dev/diag, switch to memory-device logging for the modem,
 * enable all message masks (0x7D/5), and write the raw stream entries to a file for host-side parsing.
 *
 * usage: diag-f3-capture <seconds> <outfile>
 */
typedef unsigned long u64; typedef unsigned int u32; typedef unsigned short u16; typedef unsigned char u8;
static long sc(long n, long a, long b, long c, long d, long e, long f) {
  register long x8 __asm__("x8") = n; register long x0 __asm__("x0") = a; register long x1 __asm__("x1") = b;
  register long x2 __asm__("x2") = c; register long x3 __asm__("x3") = d; register long x4 __asm__("x4") = e; register long x5 __asm__("x5") = f;
  __asm__ volatile("svc #0" : "+r"(x0) : "r"(x8), "r"(x1), "r"(x2), "r"(x3), "r"(x4), "r"(x5) : "memory", "cc");
  return x0;
}
static long sys_openat(const char *p, long flags, long mode){ return sc(56,-100,(long)p,flags,mode,0,0); }
static long sys_read(int fd, void *b, long n){ return sc(63,fd,(long)b,n,0,0,0); }
static long sys_write(int fd, const void *b, long n){ return sc(64,fd,(long)b,n,0,0,0); }
static long sys_close(int fd){ return sc(57,fd,0,0,0,0,0); }
static long sys_ioctl(int fd, long req, void *a){ return sc(29,fd,req,(long)a,0,0,0); }
static void sys_exit(int c){ sc(93,c,0,0,0,0,0); for(;;){} }
struct pollfd { int fd; short events, revents; };
struct ts { long s, ns; };
static long sys_poll(struct pollfd *p, long n, long ms){ struct ts t={ms/1000,(ms%1000)*1000000L}; return sc(73,(long)p,n,(long)&t,0,8,0); }
static long sys_clock_gettime(struct ts *t){ return sc(113,1,(long)t,0,0,0,0); }   /* CLOCK_MONOTONIC */
static long slen(const char *s){ long n=0; while(s[n]) n++; return n; }
static void out(const char *s){ sys_write(1,s,slen(s)); }
static void outdec(long v){ char b[24]; int i=23; b[i]=0; int neg=v<0; if(neg) v=-v; if(!v) b[--i]='0'; while(v){ b[--i]='0'+v%10; v/=10;} if(neg) b[--i]='-'; out(b+i); }
static int atoi_(const char *s){ int v=0; while(*s>='0'&&*s<='9'){ v=v*10+(*s-'0'); s++;} return v; }

/* CRC-16/CCITT as used by DIAG HDLC (reflected, poly 0x8408, init 0xffff, final ~) */
static u16 crc16(const u8 *d, int n) {
  u16 c = 0xffff;
  for (int i = 0; i < n; i++) { c ^= d[i]; for (int k = 0; k < 8; k++) c = (c & 1) ? (c >> 1) ^ 0x8408 : c >> 1; }
  return ~c;
}
/* HDLC-frame a diag request and write it as USER_SPACE_DATA_TYPE */
static long diag_cmd(int fd, const u8 *req, int n) {
  u8 w[4 + 2 * 64 + 4]; int p = 0;
  w[p++] = 0x20; w[p++] = 0; w[p++] = 0; w[p++] = 0;             /* USER_SPACE_DATA_TYPE */
  u16 c = crc16(req, n); u8 tmp[66]; int tn = 0;
  for (int i = 0; i < n; i++) tmp[tn++] = req[i];
  tmp[tn++] = c & 0xff; tmp[tn++] = c >> 8;
  for (int i = 0; i < tn; i++) { if (tmp[i] == 0x7e || tmp[i] == 0x7d) { w[p++] = 0x7d; w[p++] = tmp[i] ^ 0x20; } else w[p++] = tmp[i]; }
  w[p++] = 0x7e;
  return sys_write(fd, w, p);
}
struct mode_param { u32 req_mode, peripheral_mask, pd_mask; u8 mode_param; } __attribute__((packed));
static u8 rb[65536];

void _start_c(long *sp) {
  int argc = (int)sp[0]; char **argv = (char **)(sp + 1);
  if (argc < 3) { out("usage: diag-f3-capture <seconds> <outfile>\n"); sys_exit(2); }
  long secs = atoi_(argv[1]);
  int fd = (int)sys_openat("/dev/diag", 02, 0);               /* O_RDWR */
  if (fd < 0) { out("open /dev/diag failed: "); outdec(fd); out("\n"); sys_exit(1); }
  int of = (int)sys_openat(argv[2], 01 | 0100 | 01000, 0644);   /* O_WRONLY|O_CREAT|O_TRUNC */
  if (of < 0) { out("open outfile failed: "); outdec(of); out("\n"); sys_exit(1); }
  struct mode_param mp = { 2, 0x0003, 0, 0 };                  /* MEMORY_DEVICE_MODE, APSS|MPSS */
  long r = sys_ioctl(fd, 7, &mp);                              /* DIAG_IOCTL_SWITCH_LOGGING */
  out("switch_logging="); outdec(r); out("\n");
  static const u8 allmsg[8] = { 0x7d, 0x05, 0x00, 0x00, 0xff, 0xff, 0xff, 0xff };   /* MSG_EXT set all rt masks */
  r = diag_cmd(fd, allmsg, 8); out("set_all_msg_masks write="); outdec(r); out("\n");
  struct ts t0, t; sys_clock_gettime(&t0);
  long total = 0, reads = 0;
  for (;;) {
    sys_clock_gettime(&t); if (t.s - t0.s >= secs) break;
    struct pollfd pf = { fd, 1, 0 };
    long pr = sys_poll(&pf, 1, 1000); if (pr <= 0) continue;
    long n = sys_read(fd, rb, sizeof rb); if (n <= 8) continue;
    reads++;
    u32 type = rb[0] | (rb[1] << 8) | (rb[2] << 16) | ((u32)rb[3] << 24);
    if (type != 0x20) continue;                                 /* only USER_SPACE_DATA_TYPE */
    u32 num = rb[4] | (rb[5] << 8) | (rb[6] << 16) | ((u32)rb[7] << 24); long p = 8;
    for (u32 i = 0; i < num && p + 4 <= n; i++) {
      u32 len = rb[p] | (rb[p+1] << 8) | (rb[p+2] << 16) | ((u32)rb[p+3] << 24); p += 4;
      if (len > (u32)(n - p)) break;
      sys_write(of, rb + p, len); total += len; p += len;
    }
  }
  static const u8 nomsg[8] = { 0x7d, 0x05, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 };
  diag_cmd(fd, nomsg, 8);
  struct mode_param usb = { 1, 0x0003, 0, 0 }; sys_ioctl(fd, 7, &usb);   /* back to USB mode */
  out("reads="); outdec(reads); out(" bytes="); outdec(total); out("\n");
  sys_close(of); sys_close(fd); sys_exit(0);
}
__asm__(".globl _start\n_start:\n mov x0, sp\n bl _start_c\n");
