#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

int main(int argc, char **argv) {
    if (argc != 5) return 64;
    int result;
    if (!strcmp(argv[1], "hardlink")) result = link(argv[2], argv[3]);
    else if (!strcmp(argv[1], "symlink")) result = symlink(argv[2], argv[3]);
    else if (!strcmp(argv[1], "rename")) result = rename(argv[2], argv[3]);
    else return 64;
    int error = errno;
    if (!strcmp(argv[4], "allowed") && result == 0) return 0;
    if (!strcmp(argv[4], "denied") && result == -1 && (error == EPERM || error == EACCES)) return 0;
    fprintf(stderr, "%s: result=%d errno=%d (%s), expected %s\n", argv[1], result, error, strerror(error), argv[4]);
    return 1;
}
