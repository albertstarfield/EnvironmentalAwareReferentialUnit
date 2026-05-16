#include <stdio.h>
#include <sys/mman.h>
#include <fcntl.h>
#include <errno.h>
#include <string.h>
#include <unistd.h>

int main() {
    const char *name = "/test_shm_c";
    int fd = shm_open(name, O_RDWR | O_CREAT, 0666);
    if (fd < 0) {
        printf("shm_open create failed: %s (errno %d)\n", strerror(errno), errno);
        return 1;
    }
    ftruncate(fd, 1024);
    printf("shm_open create success! fd=%d. Waiting 10s...\n", fd);
    sleep(10);
    shm_unlink(name);
    return 0;
}
