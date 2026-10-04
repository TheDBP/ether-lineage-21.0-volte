/* Freestanding arm64 QMUX probe: allocate a WDS client as a direct QMI client
 * via the MSM IPC router (AF_MSM_IPC); <node> picks the server node (modem = 0), send START_NETWORK_INTERFACE with a chosen TLV set,
 * print the QMI result/error and call-end reason, then stop the call and release.
 *
 * usage: qmi-sni <node> <apn> <3gpp-profile> [v4|v6] [epc|umts|none] [calltype] [keep] [sub] [muxN]
 */
typedef unsigned long u64; typedef unsigned int u32; typedef unsigned short u16; typedef unsigned char u8;
static long sc(long n, long a, long b, long c, long d, long e, long f) {
  register long x8 __asm__("x8") = n; register long x0 __asm__("x0") = a; register long x1 __asm__("x1") = b;
  register long x2 __asm__("x2") = c; register long x3 __asm__("x3") = d; register long x4 __asm__("x4") = e; register long x5 __asm__("x5") = f;
  __asm__ volatile("svc #0" : "+r"(x0) : "r"(x8), "r"(x1), "r"(x2), "r"(x3), "r"(x4), "r"(x5) : "memory", "cc");
  return x0;
}
static long sys_socket(long d, long t){ return sc(198,d,t,0,0,0,0); }
static long sys_ioctl(int fd, long req, void *a){ return sc(29,fd,req,(long)a,0,0,0); }
static long sys_sendto(int fd, const void *b, long n, void *to, long tl){ return sc(206,fd,(long)b,n,0,(long)to,tl); }
static long sys_recvfrom(int fd, void *b, long n){ return sc(207,fd,(long)b,n,0,0,0); }
struct ipc_addr { u16 family; u8 pad0[2]; u8 addrtype; u8 pad[3]; u32 a; u32 b; u8 reserved; u8 pad2[3]; };   /* sockaddr_msm_ipc, 20 bytes */
struct lookup { u32 service, instance; int in_array, found; u32 mask; struct { u32 node, port, service, instance; } srv[8]; };
static long sys_write(int fd, const void *b, long n){ return sc(64,fd,(long)b,n,0,0,0); }
static struct ipc_addr dst;
static long sys_close(int fd){ return sc(57,fd,0,0,0,0,0); }
static void sys_exit(int c){ sc(93,c,0,0,0,0,0); for(;;){} }
struct pollfd { int fd; short events, revents; };
struct ts { long s, ns; };
static long sys_poll(struct pollfd *p, long n, long ms){ struct ts t={ms/1000,(ms%1000)*1000000L}; return sc(73,(long)p,n,(long)&t,0,8,0); }
static long slen(const char *s){ long n=0; while(s[n]) n++; return n; }
static void out(const char *s){ sys_write(1,s,slen(s)); }
static void outhex(u32 v, int digits){ char b[12]; b[0]='0'; b[1]='x'; for(int i=digits-1;i>=0;i--){ int d=v&15; b[2+i]= d<10?'0'+d:'a'+d-10; v>>=4;} b[2+digits]=0; out(b); }
static void outdec(long v){ char b[24]; int i=23; b[i]=0; int neg=v<0; if(neg) v=-v; if(!v) b[--i]='0'; while(v){ b[--i]='0'+v%10; v/=10;} if(neg) b[--i]='-'; out(b+i); }
static int streq(const char *a, const char *b){ while(*a&&*a==*b){a++;b++;} return *a==*b; }
static int atoi_(const char *s){ int v=0; while(*s>='0'&&*s<='9'){ v=v*10+(*s-'0'); s++;} return v; }

static u8 buf[4096];
static u16 txn = 1;

/* build + send one QMUX request; returns bytes written */
static long send_req(int fd, u8 svc, u8 cid, u16 msg, const u8 *tlvs, u16 tlvlen) {
  u8 *p = buf; (void)svc; (void)cid;
  *p++ = 0x00; *p++ = txn & 0xff; *p++ = txn >> 8; txn++;
  *p++ = msg & 0xff; *p++ = msg >> 8; *p++ = tlvlen & 0xff; *p++ = tlvlen >> 8;
  for (int i = 0; i < tlvlen; i++) *p++ = tlvs[i];
  return sys_sendto(fd, buf, p - buf, &dst, sizeof dst);
}
/* read frames until one matches svc/cid/msg (response); returns pointer to TLVs and sets *tlen, or 0 on timeout */
static u8 *recv_resp(int fd, u8 svc, u8 cid, u16 msg, int *tlen, int ms) {
  for (int tries = 0; tries < 20; tries++) {
    struct pollfd pf = { fd, 1, 0 };
    if (sys_poll(&pf, 1, ms) <= 0) return 0;
    long n = sys_recvfrom(fd, buf, sizeof buf);
    if (n < 7) continue; (void)svc; (void)cid;
    u8 *s = buf; u8 type = s[0]; s += 3;
    u16 m = s[0] | (s[1] << 8); u16 l = s[2] | (s[3] << 8);
    if (!(type & 0x02) || m != msg) { out("  (skipped frame type "); outhex(type,2); out(" msg "); outhex(m,4); out(")\n"); continue; }
    *tlen = l; return s + 4;
  }
  return 0;
}
static u8 *find_tlv(u8 *t, int tlen, u8 type, int *vlen) {
  int i = 0; while (i + 3 <= tlen) { u8 ty = t[i]; u16 l = t[i+1] | (t[i+2] << 8); if (ty == type) { *vlen = l; return t + i + 3; } i += 3 + l; }
  return 0;
}
static void print_result(u8 *t, int tlen) {
  int vl; u8 *v = find_tlv(t, tlen, 0x02, &vl);
  if (v && vl >= 4) { out("  result="); outdec(v[0] | (v[1] << 8)); out(" error="); outdec(v[2] | (v[3] << 8)); out("\n"); }
  else out("  (no result TLV)\n");
}

void _start_c(long *sp) {
  int argc = (int)sp[0]; char **argv = (char **)(sp + 1);
  if (argc >= 3 && (streq(argv[1], "q") || streq(argv[1], "qi"))) {   /* raw mode: q|qi <svc> <msgid-hex> [tlv hex bytes...]; qi also waits for indications */
    int want_ind = argv[1][1] == 'i';
    int svc = atoi_(argv[2]); u32 msg = 0; for (const char *h = argv[3]; *h; h++) { int d = (*h >= 'a') ? *h - 'a' + 10 : (*h >= 'A') ? *h - 'A' + 10 : *h - '0'; msg = msg * 16 + d; }
    u8 tl2[512]; int n = 0;
    for (int i = 4; i < argc; i++) { u32 v = 0; for (const char *h = argv[i]; *h; h++) { int d = (*h >= 'a') ? *h - 'a' + 10 : (*h >= 'A') ? *h - 'A' + 10 : *h - '0'; v = v * 16 + d; } tl2[n++] = (u8)v; }
    int fd = (int)sys_socket(27, 2);
    struct lookup lk; for (int i = 0; i < (int)sizeof lk; i++) ((u8 *)&lk)[i] = 0;
    lk.service = svc; lk.instance = 0; lk.in_array = 8; lk.mask = 0;
    long r = sys_ioctl(fd, 0xC014C302L, &lk);
    if (r < 0 || lk.found <= 0) { out("lookup failed\n"); sys_exit(1); }
    int pick = 0; for (int i = 0; i < lk.found && i < 8; i++) if (lk.srv[i].node == 0) { pick = i; break; }
    dst.family = 27; dst.addrtype = 2; dst.a = lk.srv[pick].node; dst.b = lk.srv[pick].port;
    out("svc "); outdec(svc); out(" node "); outdec(dst.a); out(" port "); outhex(dst.b, 4); out(" msg "); outhex(msg, 4); out("\n");
    int tl; send_req(fd, (u8)svc, 0, (u16)msg, tl2, (u16)n);
    u8 *t = recv_resp(fd, (u8)svc, 0, (u16)msg, &tl, 10000);
    if (!t) { out("no response\n"); sys_exit(3); }
    print_result(t, tl);
    int i = 0; while (i + 3 <= tl) { u8 ty = t[i]; u16 l = t[i+1] | (t[i+2] << 8); out("  tlv "); outhex(ty, 2); out(" len "); outdec(l); out(":"); for (int k = 0; k < l && i + 3 + k < tl; k++) { out(" "); outhex(t[i+3+k], 2); } out("\n"); i += 3 + l; }
    for (int w = 0; want_ind && w < 8; w++) {                      /* print any indications arriving within ~6 s */
      struct pollfd pf = { fd, 1, 0 };
      if (sys_poll(&pf, 1, 6000) <= 0) break;
      long n2 = sys_recvfrom(fd, buf, sizeof buf); if (n2 < 7) continue;
      u8 *s = buf + 3; u16 m = s[0] | (s[1] << 8); u16 l2 = s[2] | (s[3] << 8); u8 *t2 = s + 4;
      out("  ind type "); outhex(buf[0], 2); out(" msg "); outhex(m, 4); out("\n");
      int j = 0; while (j + 3 <= l2) { u8 ty = t2[j]; u16 l = t2[j+1] | (t2[j+2] << 8); out("    tlv "); outhex(ty, 2); out(" len "); outdec(l); out(":"); for (int k = 0; k < l && j + 3 + k < l2; k++) { out(" "); outhex(t2[j+3+k], 2); } out("\n"); j += 3 + l; }
    }
    sys_exit(0);
  }
  if (argc < 4) { out("usage: qmi-sni <node> <apn> <profile> [v4|v6|v4v6] [epc|umts|none] [calltype] [keep] [sub] [muxN]\n"); sys_exit(2); }
  const char *dev = argv[1], *apn = argv[2]; int prof = atoi_(argv[3]);
  u8 ipfam = 4; const char *tech = "none"; int calltype = 0, keep = 0, mux = -1, sub = 0;
  for (int i = 4; i < argc; i++) {
    if (streq(argv[i], "v6")) ipfam = 6; else if (streq(argv[i], "v4v6")) ipfam = 8; else if (streq(argv[i], "v4")) ipfam = 4;
    else if (streq(argv[i], "epc") || streq(argv[i], "umts") || streq(argv[i], "none")) tech = argv[i];
    else if (streq(argv[i], "calltype")) calltype = 1; else if (streq(argv[i], "keep")) keep = 1;
    else if (streq(argv[i], "sub")) sub = 1;
    else if (argv[i][0] == 'm' && argv[i][1] == 'u' && argv[i][2] == 'x') mux = atoi_(argv[i] + 3);   /* muxN: BIND_MUX_DATA_PORT ep{4,1} mux_id N */
  }
  int fd = (int)sys_socket(27, 2);                 /* AF_MSM_IPC, SOCK_DGRAM */
  if (fd < 0) { out("socket failed: "); outdec(fd); out("\n"); sys_exit(1); }
  struct lookup lk; for (int i = 0; i < (int)sizeof lk; i++) ((u8 *)&lk)[i] = 0;
  lk.service = 1; lk.instance = 0; lk.in_array = 8; lk.mask = 0;   /* WDS, any instance */
  long r = sys_ioctl(fd, 0xC014C302L, &lk);                       /* IPC_ROUTER_IOCTL_LOOKUP_SERVER */
  if (r < 0 || lk.found <= 0) { out("lookup failed r="); outdec(r); out(" found="); outdec(lk.found); out("\n"); sys_exit(1); }
  int pick = -1;
  for (int i = 0; i < lk.found && i < 8; i++) {
    out("  WDS server node="); outdec(lk.srv[i].node); out(" port="); outhex(lk.srv[i].port, 8); out(" instance="); outhex(lk.srv[i].instance, 4); out("\n");
    if (pick < 0 && lk.srv[i].node == (u32)atoi_(dev)) pick = i;
  }
  if (pick < 0) pick = 0;
  dst.family = 27; dst.addrtype = 2; dst.a = lk.srv[pick].node; dst.b = lk.srv[pick].port;
  out("  using node "); outdec(dst.a); out("\n");
  u8 cid = 0; int tl, vl; u8 *t, *v;

  if (sub) {                                       /* WDS_BIND_SUBSCRIPTION 0x00AF: TLV 0x01 u32 1 (primary) */
    u8 tb[7] = { 0x01, 4, 0, 1, 0, 0, 0 };
    send_req(fd, 1, cid, 0x00AF, tb, 7); t = recv_resp(fd, 1, cid, 0x00AF, &tl, 10000);
    out("BIND_SUBSCRIPTION: "); if (t) print_result(t, tl); else out("no response\n");
  }
  if (mux >= 0) {                                  /* WDS_BIND_MUX_DATA_PORT 0x00A2: 0x10 ep_id{type u32, id u32}, 0x11 mux_id u8 */
    u8 tb[15] = { 0x10, 8, 0, 4, 0, 0, 0, 1, 0, 0, 0, 0x11, 1, 0, (u8)mux };
    send_req(fd, 1, cid, 0x00A2, tb, 15); t = recv_resp(fd, 1, cid, 0x00A2, &tl, 10000);
    out("BIND_MUX_DATA_PORT mux="); outdec(mux); out(": "); if (t) print_result(t, tl); else out("no response\n");
  }

  /* WDS START_NETWORK_INTERFACE */
  u8 tl2[256]; int n = 0; int al = (int)slen(apn);
  tl2[n++] = 0x14; tl2[n++] = al & 0xff; tl2[n++] = al >> 8; for (int i = 0; i < al; i++) tl2[n++] = apn[i];
  tl2[n++] = 0x31; tl2[n++] = 1; tl2[n++] = 0; tl2[n++] = (u8)prof;                 /* 3GPP profile index */
  tl2[n++] = 0x19; tl2[n++] = 1; tl2[n++] = 0; tl2[n++] = ipfam;                     /* IP family preference */
  if (streq(tech, "epc"))  { tl2[n++] = 0x34; tl2[n++] = 2; tl2[n++] = 0; tl2[n++] = 0x80; tl2[n++] = 0x88; }   /* ext tech pref EPC (-30592) */
  if (streq(tech, "umts")) { tl2[n++] = 0x34; tl2[n++] = 2; tl2[n++] = 0; tl2[n++] = 0x04; tl2[n++] = 0x80; }   /* ext tech pref UMTS (-32764) */
  if (calltype)            { tl2[n++] = 0x35; tl2[n++] = 1; tl2[n++] = 0; tl2[n++] = 0x01; }                     /* call type EMBEDDED */
  out("SNI apn="); out(apn); out(" profile="); outdec(prof); out(" ipfam="); outdec(ipfam); out(" tech="); out(tech); out(calltype ? " calltype" : ""); out("\n");
  send_req(fd, 1, cid, 0x0020, tl2, (u16)n);
  t = recv_resp(fd, 1, cid, 0x0020, &tl, 60000);
  u32 handle = 0;
  if (!t) out("  SNI: no response within 60 s\n");
  else {
    print_result(t, tl);
    v = find_tlv(t, tl, 0x01, &vl); if (v && vl >= 4) { handle = v[0] | (v[1] << 8) | (v[2] << 16) | ((u32)v[3] << 24); out("  pkt_data_handle="); outhex(handle, 8); out("\n"); }
    v = find_tlv(t, tl, 0x10, &vl); if (v && vl >= 2) { out("  call_end_reason="); outdec(v[0] | (v[1] << 8)); out("\n"); }
    v = find_tlv(t, tl, 0x11, &vl); if (v && vl >= 4) { out("  verbose_call_end type="); outdec(v[0] | (v[1] << 8)); out(" reason="); outdec(v[2] | (v[3] << 8)); out("\n"); }
  }
  if (handle && !keep) {
    u8 t3[7] = { 0x01, 4, 0, handle & 0xff, (handle >> 8) & 0xff, (handle >> 16) & 0xff, handle >> 24 };
    send_req(fd, 1, cid, 0x0021, t3, 7);
    t = recv_resp(fd, 1, cid, 0x0021, &tl, 10000);
    out("STOP_NETWORK_INTERFACE:\n"); if (t) print_result(t, tl); else out("  no response\n");
  }
  sys_close(fd); sys_exit(handle ? 0 : 3);
}
__asm__(".globl _start\n_start:\n mov x0, sp\n bl _start_c\n");
