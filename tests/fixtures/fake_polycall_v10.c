/*
 * Test fixture: a stand-in for a libpolycall 1.0 shared library, which has
 * the historical API but none of the binding ABI v1 symbols
 * (polycall_ffi_abi_version, polycall_peer_*, ...). Built as
 * libpolycall.so.1 by tests/loader-errors.sh to check that the binding fails
 * with a clear loader error instead of crashing. Never installed.
 */
#include <stddef.h>

typedef struct polycall_context *polycall_context_t;

const char *polycall_get_version(void) { return "1.0.0"; }
int polycall_init_with_config(polycall_context_t *ctx, const void *config)
{
    (void)config;
    if (ctx) *ctx = NULL;
    return 4; /* POLYCALL_ERROR */
}
void polycall_cleanup(polycall_context_t ctx) { (void)ctx; }
const char *polycall_get_last_error(polycall_context_t ctx) { (void)ctx; return "fixture"; }
