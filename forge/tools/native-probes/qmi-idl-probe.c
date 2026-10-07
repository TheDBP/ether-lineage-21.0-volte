/* qmi-idl-probe — find out whether a QMI service object can be obtained on THIS build, and at
 * which IDL version. Build with tools/android-cc.sh; run with the vendor libs on the path:
 *
 *   adb shell 'LD_LIBRARY_PATH=/vendor/lib64:/system/lib64 /data/local/tmp/qmi-idl-probe wms'
 *   ... [maj min tool]      also try qmi_client_init_instance with that version
 *
 * WHY THIS EXISTS. Every generated QTI IDL ships <svc>_get_service_object_internal_v01(major,
 * minor, tool), and it returns NULL unless all three match the library exactly. An OEM binary
 * built against an older vendor tree therefore gets a NULL service object on a newer ROM, and
 * every downstream symptom is an absence: the QMI client comes back -1 with qmi_err_code 0, no
 * IPC-router denial, no SELinux denial, no library log line -- because no QMI transaction ever
 * happened. That reads like a permission or transport problem and is neither.
 *
 * Seen on the LG V20: libimswms asks for WMS (1,24,6); the 24.0 ROM's libqmiservices.so accepts
 * only (1,35,6). Putting the stock libqmiservices.so ahead of the ROM's on that one daemon's
 * library path fixed it -- correct rather than a hack, because the modem is the stock one and the
 * stock IDL is its matching encoder.
 *
 * The scan is the useful half: it tells you the version the ROM will accept, so you can decide
 * between shipping the stock IDL library and rebuilding the caller.
 */
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <dlfcn.h>

typedef void *(*get_svc_t)(int, int, int);
typedef int   (*init_inst_t)(void *, int, void *, void *, void *, unsigned, void **);

int main(int argc, char **argv) {
    const char *svc = (argc > 1) ? argv[1] : "wms";
    char sym[128];
    snprintf(sym, sizeof sym, "%s_get_service_object_internal_v01", svc);

    void *svcs = dlopen("libqmiservices.so", RTLD_NOW);
    if (!svcs) { printf("FAIL dlopen libqmiservices.so: %s\n", dlerror()); return 1; }
    get_svc_t get_svc = (get_svc_t)dlsym(svcs, sym);
    if (!get_svc) { printf("FAIL dlsym %s -- wrong service name?\n", sym); return 1; }
    printf("ok   %s resolved\n", sym);

    if (argc >= 5) {                       /* explicit version: also try a client init */
        int maj = atoi(argv[2]), min = atoi(argv[3]), tool = atoi(argv[4]);
        void *obj = get_svc(maj, min, tool);
        printf("%s  (%d,%d,%d) -> %p\n", obj ? "ok  " : "FAIL", maj, min, tool, obj);
        if (!obj) return 2;
        void *cci = dlopen("libqmi_cci.so", RTLD_NOW);
        if (!cci) { printf("FAIL dlopen libqmi_cci.so: %s\n", dlerror()); return 1; }
        init_inst_t init_inst = (init_inst_t)dlsym(cci, "qmi_client_init_instance");
        if (!init_inst) { printf("FAIL dlsym qmi_client_init_instance\n"); return 1; }
        char os_params[96]; memset(os_params, 0, sizeof os_params);
        void *client = 0;
        int rc = init_inst(obj, 0xffff /* INSTANCE_ANY */, 0, 0, os_params, 10000, &client);
        printf("%s  qmi_client_init_instance rc=%d client=%p\n", rc ? "FAIL" : "PASS", rc, client);
        return rc ? 3 : 0;
    }

    int found = 0;
    for (int maj = 0; maj < 4; maj++)
        for (int min = 0; min < 512; min++)
            for (int tool = 0; tool < 24; tool++) {
                void *o = get_svc(maj, min, tool);
                if (o) {
                    printf("ACCEPTED (%d,%d,%d) -> %p\n", maj, min, tool, o);
                    if (++found > 8) return 0;
                }
            }
    if (!found) printf("no (major,minor,tool) accepted in 0-3 / 0-511 / 0-23 -- widen the loops if the\n       service is known to exist; some IDLs carry a minor well above this\n");
    return found ? 0 : 4;
}
