// SPDX-FileCopyrightText: 2024 emmtrix Technologies GmbH
// SPDX-License-Identifier: Apache-2.0

#include <stdio.h>
#include <stdint.h>
#include "cluster_sync.h"

#define N_ELEMS 64

static volatile uint32_t in_data[N_ELEMS];
static volatile uint32_t partial_sum[NUM_CORES];
static volatile uint32_t cluster_status;
static cl_barrier_t bar;

int main(void) {
    uint32_t hart = cl_read_mhartid();

    if (hart >= NUM_CORES) {
        return 1;
    }

    if (hart == 0u) {
        cl_barrier_init(&bar);
        for (uint32_t i = 0; i < NUM_CORES; i++) {
            partial_sum[i] = 0u;
        }
        for (uint32_t i = 0; i < N_ELEMS; i++) {
            in_data[i] = i + 1u;
        }
        cluster_status = 0u;
        cl_fence();
    }

    cl_barrier_wait(&bar);

    {
        uint32_t chunk = N_ELEMS / NUM_CORES;
        uint32_t start = hart * chunk;
        uint32_t end = (hart == (NUM_CORES - 1u)) ? N_ELEMS : (start + chunk);
        uint32_t sum = 0u;
        for (uint32_t i = start; i < end; i++) {
            sum += in_data[i];
        }
        partial_sum[hart] = sum;
        cl_fence();
    }

    cl_barrier_wait(&bar);

    if (hart == 0u) {
        uint32_t expected = (N_ELEMS * (N_ELEMS + 1u)) / 2u;
        uint32_t sum = 0u;
        for (uint32_t i = 0; i < NUM_CORES; i++) {
            sum += partial_sum[i];
        }

        if (sum == expected) {
            puts("REDUCTION DEMO PASS");
            cluster_status = 0u;
        } else {
            puts("REDUCTION DEMO FAIL");
            cluster_status = 1u;
        }
        cl_fence();
        return (int)cluster_status;
    }

    return 0;
}
