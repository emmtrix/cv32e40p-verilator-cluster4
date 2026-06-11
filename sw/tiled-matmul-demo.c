// SPDX-FileCopyrightText: 2024 emmtrix Technologies GmbH
// SPDX-License-Identifier: Apache-2.0

#include <stdio.h>
#include <stdint.h>
#include "cluster_sync.h"

#define N 8
#define TILE 2

static volatile int32_t mat_a[N][N];
static volatile int32_t mat_b[N][N];
static volatile int32_t mat_c[N][N];
static volatile uint32_t cluster_status;
static cl_barrier_t bar;

int main(void) {
    uint32_t hart = cl_read_mhartid();

    if (hart >= NUM_CORES) {
        return 1;
    }

    if (hart == 0u) {
        cl_barrier_init(&bar);

        for (uint32_t i = 0; i < N; i++) {
            for (uint32_t j = 0; j < N; j++) {
                mat_a[i][j] = (int32_t)(i + j + 1u);
                mat_b[i][j] = (int32_t)((i == j) ? 2 : 1);
                mat_c[i][j] = 0;
            }
        }
        cluster_status = 0u;
        cl_fence();
    }

    cl_barrier_wait(&bar);

    for (uint32_t ii = hart * TILE; ii < N; ii += NUM_CORES * TILE) {
        uint32_t i_max = (ii + TILE < N) ? (ii + TILE) : N;
        for (uint32_t jj = 0; jj < N; jj += TILE) {
            uint32_t j_max = (jj + TILE < N) ? (jj + TILE) : N;
            for (uint32_t kk = 0; kk < N; kk += TILE) {
                uint32_t k_max = (kk + TILE < N) ? (kk + TILE) : N;
                for (uint32_t i = ii; i < i_max; i++) {
                    for (uint32_t j = jj; j < j_max; j++) {
                        int32_t acc = mat_c[i][j];
                        for (uint32_t k = kk; k < k_max; k++) {
                            acc += mat_a[i][k] * mat_b[k][j];
                        }
                        mat_c[i][j] = acc;
                    }
                }
            }
        }
    }

    cl_fence();
    cl_barrier_wait(&bar);

    if (hart == 0u) {
        int fail = 0;
        for (uint32_t i = 0; i < N; i++) {
            for (uint32_t j = 0; j < N; j++) {
                int32_t ref = 0;
                for (uint32_t k = 0; k < N; k++) {
                    ref += mat_a[i][k] * mat_b[k][j];
                }
                if (mat_c[i][j] != ref) {
                    fail = 1;
                }
            }
        }

        if (!fail) {
            puts("TILED MATMUL DEMO PASS");
            cluster_status = 0u;
        } else {
            puts("TILED MATMUL DEMO FAIL");
            cluster_status = 1u;
        }

        cl_fence();
        return (int)cluster_status;
    }

    return 0;
}
