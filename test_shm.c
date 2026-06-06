#include <stdio.h>
#include <fcntl.h>
#include <sys/mman.h>
#include <unistd.h>
#include <errno.h>

int main() {
    int fd = shm_open("/earu_v2_stats_shm", O_CREAT | O_RDWR, 0666);
    if (fd < 0) {
        perror("shm_open");
        return 1;
    }
    printf("shm_open success, fd=%d\n", fd);
    
    // We don't know the exact size, but it's small, let's say 4096.
    int ret = ftruncate(fd, 4096);
    if (ret < 0) {
        perror("ftruncate");
        return 1;
    }
    printf("ftruncate success\n");
    
    void *addr = mmap(NULL, 4096, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (addr == MAP_FAILED) {
        perror("mmap");
        return 1;
    }
    printf("mmap success\n");
    
    return 0;
}
