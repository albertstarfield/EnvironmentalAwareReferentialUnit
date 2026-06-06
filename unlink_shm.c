#include <stdio.h>
#include <sys/mman.h>

int main() {
    shm_unlink("/earu_v2_stats_shm");
    shm_unlink("/earu_v2_weather_shm");
    shm_unlink("/earu_v2_ml_shm");
    printf("SHMs unlinked\n");
    return 0;
}
