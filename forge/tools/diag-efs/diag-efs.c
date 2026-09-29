// diag-efs — read modem EFS/NV item files over /dev/diag.
//
//   diag-efs buildid                 sanity check: the modem's build id
//   diag-efs hello                   EFS2 handshake
//   diag-efs read /nv/item_files/... read an NV item file, hex + decimal
//   diag-efs raw 4b130000....        send an arbitrary diag payload, print replies
//
// WHY A CUSTOM TOOL
//
// The value we want lives in the modem's EFS, not on the filesystem. The only route to it is the
// DIAG protocol over /dev/diag, and nothing on the device speaks it. Three details make this
// awkward enough to be worth writing down, all confirmed against this kernel's
// drivers/char/diag rather than assumed:
//
//   1. Requests are written as [u32 USER_SPACE_DATA_TYPE][HDLC frame]. diagchar_write() hands the
//      payload to diag_process_hdlc(), so the framing is ours to do: CRC-16/X-25, 0x7d/0x7e
//      escaping, 0x7e terminator.
//   2. Replies from the MODEM only reach userspace when logging_mode == MEMORY_DEVICE_MODE.
//      diagchar_read() otherwise clears the ready flag and drops the data -- the read simply
//      returns nothing and it looks like the modem never answered. So switch the mode, and put it
//      back on the way out.
//   3. In that mode the reply stream is interleaved with the whole device's diag logging, laid out
//      as [u32 type][u32 num_data] then [u32 len][payload] per record. So every read has to be
//      filtered for the reply to the command we sent, not just taken as the answer.
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <time.h>
#include <unistd.h>

#define USER_SPACE_DATA_TYPE      0x00000020
#define DIAG_IOCTL_SWITCH_LOGGING 7
#define USB_MODE                  1
#define MEMORY_DEVICE_MODE        2
#define UART_MODE                 4

#define DIAG_SUBSYS_CMD 0x4b
#define SUBSYS_FS       0x13
#define EFS2_HELLO 0
#define EFS2_OPEN  2
#define EFS2_CLOSE 3
#define EFS2_READ  4
#define EFS2_WRITE 5
#define EFS2_UNLINK 8
#define EFS2_OPENDIR  11
#define EFS2_READDIR  12
#define EFS2_CLOSEDIR 13

static int g_fd = -1;

/* CRC-16/X-25, as the diag HDLC layer uses: reflected 0x1021, init and final xor 0xffff. */
static uint16_t crc16(const uint8_t *p, size_t n) {
    uint16_t crc = 0xffff;
    for (size_t i = 0; i < n; i++) {
        crc ^= p[i];
        for (int b = 0; b < 8; b++)
            crc = (crc & 1) ? (crc >> 1) ^ 0x8408 : crc >> 1;
    }
    return ~crc;
}

static size_t hdlc_encode(const uint8_t *in, size_t n, uint8_t *out) {
    uint16_t crc = crc16(in, n);
    uint8_t tail[2] = { (uint8_t)(crc & 0xff), (uint8_t)(crc >> 8) };
    size_t o = 0;
    for (size_t i = 0; i < n + 2; i++) {
        uint8_t c = i < n ? in[i] : tail[i - n];
        if (c == 0x7e || c == 0x7d) { out[o++] = 0x7d; out[o++] = c ^ 0x20; }
        else out[o++] = c;
    }
    out[o++] = 0x7e;
    return o;
}

static size_t hdlc_decode(const uint8_t *in, size_t n, uint8_t *out, size_t cap) {
    size_t o = 0;
    for (size_t i = 0; i < n && o < cap; i++) {
        if (in[i] == 0x7e) break;
        if (in[i] == 0x7d && i + 1 < n) out[o++] = in[++i] ^ 0x20;
        else out[o++] = in[i];
    }
    return o >= 2 ? o - 2 : o;   /* drop the trailing crc */
}

static int diag_send(const uint8_t *pkt, size_t n) {
    uint8_t buf[16384];
    uint32_t type = USER_SPACE_DATA_TYPE;
    memcpy(buf, &type, 4);
    size_t enc = hdlc_encode(pkt, n, buf + 4);
    ssize_t w = write(g_fd, buf, 4 + enc);
    if (w < 0) { perror("write /dev/diag"); return -1; }
    return 0;
}

/* Collect the reply whose first bytes match want[0..wantn). Skips interleaved log records.
 *
 * The blocking read is interrupted with an alarm rather than guarded with poll(): this driver
 * implements no .poll, so poll() reports the fd ready unconditionally and the following read()
 * then parks forever in diagchar_read()'s wait_event_interruptible. That wait IS interruptible,
 * so a SIGALRM with no SA_RESTART turns it into EINTR, which is the only timeout available here. */
static void on_alrm(int sig) { (void)sig; }

static int diag_recv(const uint8_t *want, size_t wantn, uint8_t *out, size_t cap, int secs) {
    static uint8_t buf[131072], dec[131072];
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = on_alrm;          /* deliberately no SA_RESTART */
    sigaction(SIGALRM, &sa, NULL);

    time_t deadline = time(NULL) + secs;
    while (time(NULL) < deadline) {
        alarm(1);
        ssize_t r = read(g_fd, buf, sizeof(buf));
        alarm(0);
        if (r < 0) {
            if (errno == EINTR) continue;
            perror("read /dev/diag");
            return -1;
        }
        if (r < (ssize_t)8) continue;
        uint32_t type, num;
        memcpy(&type, buf, 4);
        memcpy(&num, buf + 4, 4);
        if (type != USER_SPACE_DATA_TYPE) continue;
        size_t off = 8;
        for (uint32_t i = 0; i < num && off + 4 <= (size_t)r; i++) {
            uint32_t len;
            memcpy(&len, buf + off, 4);
            off += 4;
            if (len == 0 || off + len > (size_t)r) break;
            size_t dn = hdlc_decode(buf + off, len, dec, sizeof(dec));
            off += len;
            if (dn >= wantn && memcmp(dec, want, wantn) == 0) {
                size_t cp = dn < cap ? dn : cap;
                memcpy(out, dec, cp);
                return (int)cp;
            }
        }
    }
    return -1;
}

/* Dump anything that looks like a reply to a command rather than log traffic: a subsystem reply
 * (0x4b), or one of diag's error answers -- BAD_CMD 0x13, BAD_PARM 0x14, BAD_LEN 0x15, BAD_MODE
 * 0x18. An unsupported subsystem command comes back as one of the errors, NOT as 0x4b, so a filter
 * that only accepts 0x4b reports "no reply" and hides the real answer. */
static int diag_probe(int secs) {
    static uint8_t buf[131072], dec[131072];
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = on_alrm;
    sigaction(SIGALRM, &sa, NULL);
    int seen = 0;
    time_t deadline = time(NULL) + secs;
    while (time(NULL) < deadline) {
        alarm(1);
        ssize_t r = read(g_fd, buf, sizeof(buf));
        alarm(0);
        if (r < 0) { if (errno == EINTR) continue; return seen; }
        if (r < (ssize_t)8) continue;
        uint32_t type, num;
        memcpy(&type, buf, 4);
        memcpy(&num, buf + 4, 4);
        if (type != USER_SPACE_DATA_TYPE) continue;
        size_t off = 8;
        for (uint32_t i = 0; i < num && off + 4 <= (size_t)r; i++) {
            uint32_t len;
            memcpy(&len, buf + off, 4);
            off += 4;
            if (len == 0 || off + len > (size_t)r) break;
            size_t dn = hdlc_decode(buf + off, len, dec, sizeof(dec));
            off += len;
            if (dn < 1) continue;
            uint8_t c = dec[0];
            if (c == 0x4b || c == 0x13 || c == 0x14 || c == 0x15 || c == 0x18) {
                printf("  reply cmd=0x%02x len=%zu: ", c, dn);
                for (size_t k = 0; k < dn && k < 64; k++) printf("%02x", dec[k]);
                printf("\n");
                seen++;
            }
        }
    }
    return seen;
}

static void hexdump(const uint8_t *p, size_t n) {
    for (size_t i = 0; i < n; i++) printf("%02x", p[i]);
    printf("\n");
}

static int efs_hdr(uint8_t *p, uint16_t cmd) {
    p[0] = DIAG_SUBSYS_CMD; p[1] = SUBSYS_FS;
    p[2] = cmd & 0xff; p[3] = cmd >> 8;
    return 4;
}

static int do_hello(uint8_t *rsp, size_t cap) {
    uint8_t req[64];
    int n = efs_hdr(req, EFS2_HELLO);
    uint32_t f[11] = { 1024, 1024, 1024, 1024, 1024, 1024, 1, 1, 1, 0, 0 };
    memcpy(req + n, f, sizeof(f)); n += sizeof(f);
    if (diag_send(req, n) < 0) return -1;
    return diag_recv(req, 4, rsp, cap, 4);
}

int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "usage: diag-efs buildid|hello|read <path>|raw <hex>\n"); return 2; }

    g_fd = open("/dev/diag", O_RDWR);
    if (g_fd < 0) { perror("open /dev/diag"); return 1; }
    /* Ask for UART_MODE, not MEMORY_DEVICE_MODE, even though memory-device is what we need.
     *
     * diag_switch_logging() sets mask_check = 1 when the requested mode is MEMORY_DEVICE_MODE, and
     * mask_request_validate() then rejects every command outside a small whitelist -- for
     * DIAG_SUBSYS_FS (0x13) it permits only HELLO (0) and QUERY (1), so OPEN/READ/CLOSE fail in the
     * kernel with EFAULT and never reach the modem. Requesting UART_MODE takes the branch that sets
     * mask_check = 0 and then forces logging_mode = MEMORY_DEVICE_MODE anyway, which is exactly the
     * combination we want. UART_MODE is preferable to SOCKET_MODE/CALLBACK_MODE, which have the
     * same effect but first record the caller in driver->socket_process / callback_process. */
    int mode = UART_MODE;
    if (ioctl(g_fd, DIAG_IOCTL_SWITCH_LOGGING, &mode) < 0)
        perror("warn: SWITCH_LOGGING");

    int rc = 1;
    uint8_t rsp[65536];

    if (!strcmp(argv[1], "buildid")) {
        /* 0x7c: extended build id. We already know what it should say, so this proves the
           transport before anything depends on struct layouts being right. */
        uint8_t req[1] = { 0x7c };
        if (diag_send(req, 1) == 0) {
            int n = diag_recv(req, 1, rsp, sizeof(rsp), 4);
            if (n > 0) {
                printf("build id reply (%d bytes): ", n); hexdump(rsp, n);
                printf("strings: ");
                for (int i = 0; i < n; i++) putchar(rsp[i] >= 32 && rsp[i] < 127 ? rsp[i] : '.');
                printf("\n");
                rc = 0;
            } else fprintf(stderr, "no reply to build id\n");
        }
    } else if (!strcmp(argv[1], "hello")) {
        int n = do_hello(rsp, sizeof(rsp));
        if (n > 0) { printf("efs2 hello reply (%d bytes): ", n); hexdump(rsp, n); rc = 0; }
        else fprintf(stderr, "no reply to efs2 hello\n");
    } else if (!strcmp(argv[1], "probe") && argc > 2) {
        size_t n = strlen(argv[2]) / 2;
        uint8_t *req = malloc(n);
        for (size_t i = 0; i < n; i++) sscanf(argv[2] + 2 * i, "%2hhx", &req[i]);
        printf("sent %zu bytes\n", n);
        if (diag_send(req, n) == 0) {
            int seen = diag_probe(4);
            printf("%d reply record(s)\n", seen);
            rc = seen > 0 ? 0 : 1;
        }
    } else if (!strcmp(argv[1], "raw") && argc > 2) {
        size_t n = strlen(argv[2]) / 2;
        uint8_t *req = malloc(n);
        for (size_t i = 0; i < n; i++) sscanf(argv[2] + 2 * i, "%2hhx", &req[i]);
        if (diag_send(req, n) == 0) {
            int m = diag_recv(req, n < 4 ? n : 4, rsp, sizeof(rsp), 4);
            if (m > 0) {
                printf("reply (%d bytes): ", m); hexdump(rsp, m);
                printf("strings: ");
                for (int i = 0; i < m; i++) putchar(rsp[i] >= 32 && rsp[i] < 127 ? rsp[i] : '.');
                printf("\n");
                rc = 0;
            } else fprintf(stderr, "no matching reply\n");
        }
    } else if (!strcmp(argv[1], "read") && argc > 2) {
        do_hello(rsp, sizeof(rsp));                      /* some builds want it first */
        uint8_t req[512];
        int n = efs_hdr(req, EFS2_OPEN);
        int32_t oflag = 0, fmode = 0;
        memcpy(req + n, &oflag, 4); n += 4;
        memcpy(req + n, &fmode, 4); n += 4;
        size_t pl = strlen(argv[2]) + 1;
        memcpy(req + n, argv[2], pl); n += pl;
        if (diag_send(req, n) < 0) goto out;
        int m = diag_recv(req, 4, rsp, sizeof(rsp), 4);
        if (m < 12) { fprintf(stderr, "open: no reply\n"); goto out; }
        int32_t fd, eno;
        memcpy(&fd, rsp + 4, 4); memcpy(&eno, rsp + 8, 4);
        printf("open fd=%d errno=%d  (raw: ", fd, eno); hexdump(rsp, m);
        if (fd < 0 || eno != 0) goto out;

        uint8_t rreq[32];
        n = efs_hdr(rreq, EFS2_READ);
        /* EFS files here run to a few hundred bytes; 256 silently truncated the interesting ones.
         * Overridable so a larger item can be pulled without a rebuild. */
        uint32_t nbyte = argc > 3 ? (uint32_t)strtoul(argv[3], NULL, 0) : 2048;
        int32_t off = 0;
        memcpy(rreq + n, &fd, 4); n += 4;
        memcpy(rreq + n, &nbyte, 4); n += 4;
        memcpy(rreq + n, &off, 4); n += 4;
        if (diag_send(rreq, n) < 0) goto out;
        m = diag_recv(rreq, 4, rsp, sizeof(rsp), 4);
        if (m < 20) { fprintf(stderr, "read: no reply\n"); goto out; }
        int32_t nread, rerr;
        memcpy(&nread, rsp + 12, 4); memcpy(&rerr, rsp + 16, 4);
        printf("read bytes=%d errno=%d\n", nread, rerr);
        printf("raw reply: "); hexdump(rsp, m);
        if (nread > 0 && 20 + nread <= m) {
            printf("value hex: "); hexdump(rsp + 20, nread);
            printf("text: ");
            for (int i = 0; i < nread; i++)
                putchar((rsp[20+i] >= 32 && rsp[20+i] < 127) || rsp[20+i] == 10 ? rsp[20+i] : '.');
            printf("\n");
            if (nread <= 8) {
                uint64_t v = 0;
                for (int i = 0; i < nread; i++) v |= (uint64_t)rsp[20 + i] << (8 * i);
                printf("value dec (LE): %llu\n", (unsigned long long)v);
            }
            rc = 0;
        }
        uint8_t creq[16];
        n = efs_hdr(creq, EFS2_CLOSE);
        memcpy(creq + n, &fd, 4); n += 4;
        diag_send(creq, n);
        diag_recv(creq, 4, rsp, sizeof(rsp), 2);
    } else if (!strcmp(argv[1], "ls") && argc > 2) {
        do_hello(rsp, sizeof(rsp));
        uint8_t req[512];
        int n = efs_hdr(req, EFS2_OPENDIR);
        size_t pl = strlen(argv[2]) + 1;
        memcpy(req + n, argv[2], pl); n += pl;
        if (diag_send(req, n) < 0) goto out;
        int m = diag_recv(req, 4, rsp, sizeof(rsp), 4);
        if (m < 12) { fprintf(stderr, "opendir: no reply\n"); goto out; }
        uint32_t dirp; int32_t eno;
        memcpy(&dirp, rsp + 4, 4); memcpy(&eno, rsp + 8, 4);
        printf("opendir dirp=%u errno=%d\n", dirp, eno);
        if (eno != 0) goto out;
        /* The numeric fields of a readdir reply are not worth trusting blind, but the entry name is
         * the last thing in the packet, so take the trailing NUL-terminated string instead of
         * indexing at a guessed offset. */
        for (int32_t seq = 1; seq < 300; seq++) {
            uint8_t rq[32];
            int k = efs_hdr(rq, EFS2_READDIR);
            memcpy(rq + k, &dirp, 4); k += 4;
            memcpy(rq + k, &seq, 4);  k += 4;
            if (diag_send(rq, k) < 0) break;
            int r = diag_recv(rq, 4, rsp, sizeof(rsp), 3);
            if (r < 16) break;
            int32_t derr; memcpy(&derr, rsp + 12, 4);
            int start = -1;
            for (int i = 16; i < r; i++) {
                if (rsp[i] >= 32 && rsp[i] < 127) { start = i; break; }
            }
            if (start < 0) { printf("  (end at seq %d, errno=%d)\n", seq, derr); break; }
            printf("  %s\n", (char *)(rsp + start));
            rc = 0;
        }
        uint8_t cq[16];
        n = efs_hdr(cq, EFS2_CLOSEDIR);
        memcpy(cq + n, &dirp, 4); n += 4;
        diag_send(cq, n);
        diag_recv(cq, 4, rsp, sizeof(rsp), 2);
    } else if (!strcmp(argv[1], "write") && argc > 3) {
        /* oflag/mode are EFS2's own, not the host's. Overridable so the values can be probed
         * without a rebuild; the defaults are write+create+truncate and 0644. */
        int32_t oflag = argc > 4 ? (int32_t)strtol(argv[4], NULL, 0) : 0x0301;
        int32_t fmode = argc > 5 ? (int32_t)strtol(argv[5], NULL, 0) : 0644;
        size_t dn = strlen(argv[3]) / 2;
        uint8_t data[1024];
        if (dn > sizeof(data)) { fprintf(stderr, "too much data\n"); goto out; }
        for (size_t i = 0; i < dn; i++) sscanf(argv[3] + 2 * i, "%2hhx", &data[i]);

        do_hello(rsp, sizeof(rsp));
        uint8_t req[512];
        int n = efs_hdr(req, EFS2_OPEN);
        memcpy(req + n, &oflag, 4); n += 4;
        memcpy(req + n, &fmode, 4); n += 4;
        size_t pl = strlen(argv[2]) + 1;
        memcpy(req + n, argv[2], pl); n += pl;
        if (diag_send(req, n) < 0) goto out;
        int m = diag_recv(req, 4, rsp, sizeof(rsp), 4);
        if (m < 12) { fprintf(stderr, "open: no reply\n"); goto out; }
        int32_t fd, eno;
        memcpy(&fd, rsp + 4, 4); memcpy(&eno, rsp + 8, 4);
        printf("open(oflag=0x%x mode=0%o) fd=%d errno=%d\n", oflag, fmode, fd, eno);
        if (eno != 0) { rc = 1; goto out; }

        uint8_t wreq[1200];
        n = efs_hdr(wreq, EFS2_WRITE);
        uint32_t off = 0;
        memcpy(wreq + n, &fd, 4); n += 4;
        memcpy(wreq + n, &off, 4); n += 4;
        memcpy(wreq + n, data, dn); n += dn;
        if (diag_send(wreq, n) < 0) goto out;
        m = diag_recv(wreq, 4, rsp, sizeof(rsp), 4);
        if (m < 16) { fprintf(stderr, "write: no reply\n"); goto out; }
        printf("write raw reply: "); hexdump(rsp, m);
        uint32_t wrote; int32_t werr;
        memcpy(&wrote, rsp + 12, 4);
        memcpy(&werr, rsp + 16, 4);
        printf("wrote=%u errno=%d\n", wrote, werr);
        if (werr == 0 && wrote == dn) rc = 0;

        uint8_t creq[16];
        n = efs_hdr(creq, EFS2_CLOSE);
        memcpy(creq + n, &fd, 4); n += 4;
        diag_send(creq, n);
        diag_recv(creq, 4, rsp, sizeof(rsp), 2);
    } else if (!strcmp(argv[1], "rm") && argc > 2) {
        do_hello(rsp, sizeof(rsp));
        uint8_t req[512];
        int n = efs_hdr(req, EFS2_UNLINK);
        size_t pl = strlen(argv[2]) + 1;
        memcpy(req + n, argv[2], pl); n += pl;
        if (diag_send(req, n) < 0) goto out;
        int m = diag_recv(req, 4, rsp, sizeof(rsp), 4);
        if (m < 8) { fprintf(stderr, "unlink: no reply\n"); goto out; }
        int32_t eno; memcpy(&eno, rsp + 4, 4);
        printf("unlink errno=%d\n", eno);
        rc = eno == 0 ? 0 : 1;
    } else {
        fprintf(stderr, "unknown subcommand\n"); rc = 2;
    }

out:
    mode = USB_MODE;
    ioctl(g_fd, DIAG_IOCTL_SWITCH_LOGGING, &mode);
    close(g_fd);
    return rc;
}
