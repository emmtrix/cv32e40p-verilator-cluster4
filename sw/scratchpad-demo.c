/*
 * scratchpad-demo.c – validates local and remote scratchpad access.
 *
 * Phase 1: Each core writes a pattern to its own (local) scratchpad.
 * Phase 2: Each core reads the *next* core's scratchpad (remote access)
 *          and verifies the pattern.
 * Phase 3: Core 0 collects the results and reports pass / fail.
 */

#include <stdio.h>
#include <stdint.h>
#include "cluster_sync.h"

static volatile uint32_t test_result;
static cl_barrier_t bar;

int main(void) {
    uint32_t hart = cl_read_mhartid();
    if (hart >= NUM_CORES)
        return 1;

    /* --- initialisation (core 0 only) --- */
    if (hart == 0u) {
        cl_barrier_init(&bar);
        test_result = 0u;
        cl_fence();
    }

    cl_barrier_wait(&bar);

    /* --- Phase 1: local scratchpad writes --- */
    volatile uint32_t *my_spm = SPM_PTR(hart);
    for (uint32_t i = 0; i < 8; i++)
        my_spm[i] = (hart << 16) | i;

    cl_fence();
    cl_barrier_wait(&bar);

    /* --- Phase 2: remote scratchpad reads --- */
    uint32_t neighbor = (hart + 1u) % NUM_CORES;
    volatile uint32_t *nb_spm = SPM_PTR(neighbor);

    for (uint32_t i = 0; i < 8; i++) {
        uint32_t expected = (neighbor << 16) | i;
        uint32_t got      = nb_spm[i];
        if (got != expected) {
            printf("Core %u: FAIL spm[%u][%u] got 0x%08x exp 0x%08x\n",
                   hart, neighbor, i, got, expected);
            test_result = 1u;
        }
    }

    cl_barrier_wait(&bar);

    /* --- Phase 3: report --- */
    if (hart == 0u) {
        if (test_result == 0u)
            puts("SCRATCHPAD DEMO PASS");
        else
            puts("SCRATCHPAD DEMO FAIL");
        return (int)test_result;
    }
    return 0;
}
