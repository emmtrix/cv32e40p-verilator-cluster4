#include <stdio.h>
#include <stdint.h>
#include "cluster_sync.h"

#define SLOW_HART 1u
#define SLOW_DELAY_ITERS 200000u

static volatile uint32_t cluster_status;
static volatile uint32_t passed[NUM_CORES];
static cl_barrier_t bar;

static void slow_delay(void) {
    for (volatile uint32_t i = 0u; i < SLOW_DELAY_ITERS; i++) {
        __asm__ volatile ("nop");
    }
}

int main(void) {
    uint32_t hart = cl_read_mhartid();

    if (hart >= NUM_CORES) {
        return 1;
    }

    if (hart == 0u) {
        cl_barrier_init(&bar);
        for (uint32_t i = 0; i < NUM_CORES; i++) {
            passed[i] = 0u;
        }
        cluster_status = 0u;
        cl_fence();
    }

    cl_barrier_wait(&bar);

    if (hart == SLOW_HART) {
        slow_delay();
    }

    passed[hart] = 1u;
    cl_fence();

    cl_barrier_wait(&bar);

    if (hart == 0u) {
        uint32_t ok = 1u;
        for (uint32_t i = 0; i < NUM_CORES; i++) {
            if (passed[i] != 1u) {
                ok = 0u;
                break;
            }
        }

        if (ok != 0u) {
            puts("BARRIER SKEW DEMO PASS");
            cluster_status = 0u;
        } else {
            puts("BARRIER SKEW DEMO FAIL");
            cluster_status = 1u;
        }

        cl_fence();
        return (int)cluster_status;
    }

    return 0;
}
