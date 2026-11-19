#include "SandboxBridge.h"
#include <sandbox.h>

// Keep the deprecated C interface behind a small, correctly typed C bridge.
int airbag_sandbox_init(const char *profile, uint64_t flags, char **errorbuf) {
    return sandbox_init(profile, flags, errorbuf);
}
void airbag_sandbox_free_error(char *errorbuf) {
    sandbox_free_error(errorbuf);
}
