#include <stdio.h>
#include <stdint.h>
#include "cluster_sync.h"

static volatile uint32_t core_data[NUM_CORES];
static volatile uint32_t cluster_status;
static cl_barrier_t bar;

int main(void) {
    uint32_t hart = cl_read_mhartid();

    if (hart >= NUM_CORES) {
        return 1;
    }

    if (hart == 0u) {
        cl_barrier_init(&bar);
        cluster_status = 0u;
        cl_fence();
    }

    cl_barrier_wait(&bar);

    core_data[hart] = hart + 1u;
    cl_fence();

    cl_barrier_wait(&bar);

    if (hart == 0u) {
        uint32_t sum = 0u;
        for (uint32_t i = 0; i < NUM_CORES; i++) {
            sum += core_data[i];
        }

        if (sum == 10u) {
            puts("SHARED MEM DEMO PASS sum=10");
            cluster_status = 0u;
        } else {
            puts("SHARED MEM DEMO FAIL");
            cluster_status = 1u;
        }

        cl_fence();
        return (int)cluster_status;
    }

    return 0;
}
