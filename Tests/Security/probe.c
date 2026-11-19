#include <sys/socket.h>
#include <netinet/in.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <stdio.h>
#include <string.h>

int main(int argc, char **argv) {
    if (argc != 4) return 64;
    int rc;
    if (!strcmp(argv[1], "write")) {
        rc = open(argv[2], O_WRONLY | O_CREAT | O_TRUNC, 0600);
    } else if (!strcmp(argv[1], "read")) {
        int fd = open(argv[2], O_RDONLY);
        if (fd < 0) rc = -1;
        else {
            char byte;
            rc = (int)read(fd, &byte, 1);
            int saved = errno;
            close(fd);
            errno = saved;
        }
    } else if (!strcmp(argv[1], "network")) {
        int fd = socket(AF_INET, SOCK_DGRAM, 0);
        if (fd < 0) rc = -1;
        else {
            struct sockaddr_in addr = {0};
            addr.sin_len = sizeof(addr);
            addr.sin_family = AF_INET;
            addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
            rc = bind(fd, (struct sockaddr *)&addr, sizeof(addr));
            int saved = errno;
            close(fd);
            errno = saved;
        }
    } else return 64;
    int saved = errno;
    if (!strcmp(argv[1], "write") && rc >= 0) close(rc);
    if (!strcmp(argv[3], "allowed")) {
        if (rc >= 0) return 0;
        fprintf(stderr, "Expected allowed %s on %s: %s\n", argv[1], argv[2], strerror(saved));
        return 1;
    }
    if (rc == -1 && (saved == EPERM || saved == EACCES)) return 0;
    fprintf(stderr, "Expected permission denial; rc=%d errno=%d\n", rc, saved);
    return 1;
}
