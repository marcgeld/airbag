#include <stdint.h>
int airbag_sandbox_init(const char *profile, uint64_t flags, char **errorbuf);
void airbag_sandbox_free_error(char *errorbuf);
