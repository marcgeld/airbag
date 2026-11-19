#include <arpa/inet.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

int main(int argc, char **argv) {
    if (argc != 5) return 64;
    int type;
    if (!strcmp(argv[1], "tcp")) type = SOCK_STREAM;
    else if (!strcmp(argv[1], "udp")) type = SOCK_DGRAM;
    else return 64;
    struct sockaddr_in address = {0};
    address.sin_len = sizeof(address);
    address.sin_family = AF_INET;
    address.sin_port = htons((unsigned short)strtoul(argv[2], NULL, 10));
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    int fd = socket(AF_INET, type, 0);
    int result = fd < 0 ? -1 : connect(fd, (struct sockaddr *)&address, sizeof(address));
    if (result == 0) result = send(fd, argv[3], strlen(argv[3]), 0) < 0 ? -1 : 0;
    int error = errno;
    if (fd >= 0) close(fd);
    if (!strcmp(argv[4], "allowed") && result == 0) return 0;
    if (!strcmp(argv[4], "denied") && result < 0 && (error == EPERM || error == EACCES)) return 0;
    fprintf(stderr, "%s expected %s: result=%d errno=%d (%s)\n", argv[1], argv[4], result, error, strerror(error));
    return 1;
}
