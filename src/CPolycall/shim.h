#ifndef SWIFT_POLYCALL_SHIM_H
#define SWIFT_POLYCALL_SHIM_H

/* The installed public header of the Polycall core. `pkg-config --cflags
 * polycall` adds -I<prefix>/include/polycall, so this resolves to the real
 * binding ABI v1 declarations -- no copied or generated stubs. */
#include <polycall.h>

#endif
