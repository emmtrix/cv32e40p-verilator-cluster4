// SPDX-FileCopyrightText: 2026 emmtrix Technologies GmbH
// SPDX-License-Identifier: Apache-2.0

/*
 * icache-test.c - instruction-fetch contention benchmark.
 *
 * Runs a register-only compute loop (no data memory accesses) and measures
 * cycles and instruction-fetch stall cycles (mhpmcounter3, IMISS event):
 *
 *   1. solo:       only hart 0 runs the loop, the other harts sleep in a
 *                  barrier.
 *   2. concurrent: all harts run the same loop at the same time.
 *
 * Each measurement is preceded by an untimed warm-up run, so with
 * per-core instruction caches the timed run should see no fetch stalls and
 * the concurrent run should be as fast as the solo run.
 *
 * Prints one line per hart plus a summary; the pytest checks the numbers.
 */

#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>

#include "cluster_sync.h"

#define LOOP_ITERS 2000u

static cl_barrier_t bar;
static volatile uint32_t result_sum[NUM_CORES];
static volatile uint32_t result_cycles[NUM_CORES];
static volatile uint32_t result_imiss[NUM_CORES];
static volatile uint32_t solo_cycles;
static volatile uint32_t solo_imiss;
static volatile uint32_t solo_sum;

static inline uint32_t read_mcycle(void) {
    uint32_t cyc;
    __asm__ volatile ("csrr %0, mcycle" : "=r"(cyc));
    return cyc;
}

/* Register-only loop body: xorshift plus a few ALU ops. */
/* noipa: stop GCC from treating the loop as const and merging repeated calls. */
static __attribute__((noipa)) uint32_t compute_loop(uint32_t seed, uint32_t iters) {
    uint32_t x = seed;
    uint32_t acc = 0u;
    for (uint32_t i = 0u; i < iters; ++i) {
        x ^= x << 13;
        x ^= x >> 17;
        x ^= x << 5;
        acc += x ^ i;
        acc = (acc << 3) | (acc >> 29);
    }
    return acc;
}

/*
 * The timed sequence runs twice and only the second run is kept: the first
 * run brings everything inside the timed window (the loop and the code around
 * the call) into the instruction cache.
 */
static void measure(uint32_t *cycles, uint32_t *imiss, uint32_t *sum) {
    for (uint32_t run = 0u; run < 2u; ++run) {
        cl_perf_mhpmcounter3_config(CL_MHPM_EVENT_IMISS);
        uint32_t t0 = read_mcycle();
        *sum = compute_loop(0x12345678u, LOOP_ITERS);
        uint32_t t1 = read_mcycle();
        cl_perf_mhpmcounter3_disable();

        *cycles = t1 - t0;
        *imiss = cl_read_csr_mhpmcounter3();
    }
}

int main(void) {
    uint32_t hart = cl_read_mhartid();
    uint32_t cycles, imiss, sum;

    if (hart >= NUM_CORES) {
        return 1;
    }

    if (hart == 0u) {
        cl_barrier_init(&bar);
    }
    cl_barrier_wait(&bar);

    /* Phase 1: hart 0 alone. */
    if (hart == 0u) {
        measure(&cycles, &imiss, &sum);
        solo_cycles = cycles;
        solo_imiss = imiss;
        solo_sum = sum;
        cl_fence();
    }
    cl_barrier_wait(&bar);

    /* Phase 2: all harts at once. */
    measure(&cycles, &imiss, &sum);
    result_cycles[hart] = cycles;
    result_imiss[hart] = imiss;
    result_sum[hart] = sum;
    cl_fence();
    cl_barrier_wait(&bar);

    if (hart != 0u) {
        return 0;
    }

    uint32_t ok = 1u;
    uint32_t max_cycles = 0u;
    printf("ICACHE TEST solo cycles=%" PRIu32 " imiss=%" PRIu32 "\n", solo_cycles, solo_imiss);
    for (uint32_t i = 0u; i < NUM_CORES; ++i) {
        printf("ICACHE TEST hart=%" PRIu32 " cycles=%" PRIu32 " imiss=%" PRIu32 "\n",
               i, result_cycles[i], result_imiss[i]);
        if (result_sum[i] != solo_sum) {
            ok = 0u;
        }
        if (result_cycles[i] > max_cycles) {
            max_cycles = result_cycles[i];
        }
    }
    printf("ICACHE TEST solo_cycles=%" PRIu32 " max_concurrent_cycles=%" PRIu32 "\n",
           solo_cycles, max_cycles);

    if (!ok) {
        puts("ICACHE TEST FAIL checksum mismatch");
        return 1;
    }
    puts("ICACHE TEST PASS");
    return 0;
}
