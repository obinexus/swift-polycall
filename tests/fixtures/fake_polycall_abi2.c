/*
 * Test fixture: a library that exports every binding ABI v1 symbol but reports
 * polycall_ffi_abi_version() == 2, i.e. an incompatible future ABI. Built as
 * libpolycall.so.1 by tests/loader-errors.sh to check that the binding refuses
 * it with a clear error. Every other function fails with POLYCALL_E_INTERNAL.
 * Never installed.
 */
#include <stddef.h>
#include <stdint.h>
#include <string.h>

#define E_INTERNAL (-18)

int polycall_ffi_abi_version(void) { return 2; }
int polycall_ffi_version(char *buf, int len)
{
    static const char v[] = "9.0.0-abi2-fixture";
    if (len < 0) return -1;
    if (buf && len > 0) {
        size_t n = (size_t)len - 1 < sizeof v - 1 ? (size_t)len - 1 : sizeof v - 1;
        memcpy(buf, v, n);
        buf[n] = '\0';
    }
    return (int)(sizeof v - 1);
}
const char *polycall_strerror(int status) { (void)status; return "POLYCALL_E_INTERNAL: fixture"; }
int polycall_last_error(char *buf, size_t cap) { if (buf && cap) buf[0] = '\0'; return 0; }
const char *polycall_get_version(void) { return "9.0.0-abi2-fixture"; }
int polycall_ffi_run_config(const char *p, int run) { (void)p; (void)run; return E_INTERNAL; }
int polycall_ffi_describe(const char *p, char *b, int l) { (void)p; (void)b; (void)l; return E_INTERNAL; }
int polycall_call(const char *e, const char *s, const char *o, const char *i, uint32_t t,
                  char *out, size_t cap, size_t *len)
{ (void)e; (void)s; (void)o; (void)i; (void)t; (void)out; (void)cap; (void)len; return E_INTERNAL; }
int polycall_peer_open(const char *n, const char *b, const char *a, int32_t *h)
{ (void)n; (void)b; (void)a; if (h) *h = 0; return E_INTERNAL; }
int polycall_peer_close(int32_t h) { (void)h; return E_INTERNAL; }
int polycall_peer_endpoint(int32_t h, char *b, size_t c) { (void)h; (void)b; (void)c; return E_INTERNAL; }
int polycall_peer_node_id(int32_t h, char *b, size_t c) { (void)h; (void)b; (void)c; return E_INTERNAL; }
int polycall_peer_register(int32_t h, const char *p, const char *e) { (void)h; (void)p; (void)e; return E_INTERNAL; }
int polycall_peer_unregister(int32_t h, const char *p) { (void)h; (void)p; return E_INTERNAL; }
int polycall_peer_list(int32_t h, char *b, size_t c, size_t *l) { (void)h; (void)b; (void)c; (void)l; return E_INTERNAL; }
int polycall_peer_ping(int32_t h, const char *p, uint32_t t) { (void)h; (void)p; (void)t; return E_INTERNAL; }
int polycall_peer_send(int32_t h, const char *p, const void *d, size_t n, const char *m, uint32_t t)
{ (void)h; (void)p; (void)d; (void)n; (void)m; (void)t; return E_INTERNAL; }
int polycall_peer_recv(int32_t h, uint32_t t, char *s, size_t sc, char *m, size_t mc,
                       void *p, size_t pc, size_t *pl)
{ (void)h; (void)t; (void)s; (void)sc; (void)m; (void)mc; (void)p; (void)pc; (void)pl; return E_INTERNAL; }
int polycall_peer_cancel(int32_t h) { (void)h; return E_INTERNAL; }
int polycall_peer_health(int32_t h, char *b, size_t c, size_t *l) { (void)h; (void)b; (void)c; (void)l; return E_INTERNAL; }
