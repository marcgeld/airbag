#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static const char *outside_path, *inside_path, *link_path;
static atomic_int stop_worker, replacements, worker_error;

static void *replace_links(void *unused) {
    (void)unused;
    char temporary[PATH_MAX];
    if (snprintf(temporary, sizeof(temporary), "%s.next", link_path) >= (int)sizeof(temporary)) {
        atomic_store(&worker_error, 1);
        return NULL;
    }
    int toggle = 0;
    while (!atomic_load(&stop_worker)) {
        if (symlink(toggle ? outside_path : inside_path, temporary) != 0 || rename(temporary, link_path) != 0) {
            atomic_store(&worker_error, errno);
            break;
        }
        toggle = !toggle;
        atomic_fetch_add(&replacements, 1);
    }
    unlink(temporary);
    return NULL;
}

int main(int argc, char **argv) {
    if (argc != 5) return 64;
    outside_path = argv[2]; inside_path = argv[3]; link_path = argv[4];
    int flags = !strcmp(argv[1], "read") ? O_RDONLY : O_WRONLY;
    struct stat outside, inside;
    if (stat(outside_path, &outside) || stat(inside_path, &inside)) return 1;
    pthread_t worker;
    if (pthread_create(&worker, NULL, replace_links, NULL)) return 1;
    int allowed = 0, denied = 0, escaped = 0, error = 0;
    for (int i = 0; i < 30000 && !escaped && !error; i++) {
        int fd = open(link_path, flags);
        if (fd < 0) {
            if (errno == EPERM || errno == EACCES) denied++;
            else error = errno;
            continue;
        }
        struct stat opened;
        if (fstat(fd, &opened)) error = errno;
        else if (opened.st_dev == outside.st_dev && opened.st_ino == outside.st_ino) escaped = 1;
        else if (opened.st_dev == inside.st_dev && opened.st_ino == inside.st_ino) allowed++;
        else error = EINVAL;
        // Never read or modify an outside file even if the test discovers an escape.
        close(fd);
    }
    atomic_store(&stop_worker, 1);
    pthread_join(worker, NULL);
    printf("symlink race %s: inside=%d denied=%d replacements=%d escape=%d\n",
           argv[1], allowed, denied, atomic_load(&replacements), escaped);
    if (escaped || error || atomic_load(&worker_error) || !allowed || !denied || !atomic_load(&replacements)) {
        fprintf(stderr, "Race verification failed: error=%d worker_error=%d\n", error, atomic_load(&worker_error));
        return 1;
    }
    return 0;
}
