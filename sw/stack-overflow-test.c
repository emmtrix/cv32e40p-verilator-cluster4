// SPDX-FileCopyrightText: 2026 emmtrix Technologies GmbH
// SPDX-License-Identifier: Apache-2.0

/*
 * stack-overflow-test.c - checks the per-core scratchpad stack layout.
 *
 * Hart 1 verifies that its stack pointer lies inside the stack region at the
 * start of its own scratchpad, then recurses without bound. Once the stack
 * grows below SPM_ADDR(1) it runs into the unmapped guard gap that follows
 * core 0's scratchpad, and the testbench stops with an UNMAPPED WRITE error.
 *
 * This test is expected to FAIL the simulation; tests/test_verilator.py
 * checks for the guard-gap error message. Hart 0 spins so that it cannot end
 * the simulation with a successful exit first.
 */

#include <stdio.h>
#include <stdint.h>
#include <inttypes.h>
#include "cluster_sync.h"

#define OVERFLOW_HART 1u

static uint32_t read_sp(void) {
    uint32_t sp;
    __asm__ volatile ("mv %0, sp" : "=r"(sp));
    return sp;
}

/* Each frame holds a volatile buffer that is used after the recursive call,
   so the compiler can neither elide the frame nor turn this into a loop. */
static uint32_t recurse(uint32_t depth) {
    volatile uint32_t frame[16];
    frame[depth & 15u] = depth;
    return recurse(depth + 1u) + frame[depth & 15u];
}

int main(void) {
    uint32_t hart = cl_read_mhartid();

    if (hart == 0u) {
        for (;;) {}
    }
    if (hart != OVERFLOW_HART)
        return 0;

    uint32_t sp = read_sp();
    uint32_t lo = SPM_ADDR(hart);
    uint32_t hi = SPM_DATA_ADDR(hart);
    if (sp <= lo || sp > hi) {
        printf("STACK CHECK FAIL sp=0x%08" PRIx32 " expected (0x%08" PRIx32 ", 0x%08" PRIx32 "]\n",
               sp, lo, hi);
        return 1;
    }
    printf("STACK CHECK PASS sp=0x%08" PRIx32 " stack=[0x%08" PRIx32 ", 0x%08" PRIx32 ")\n",
           sp, lo, hi);
    printf("STACK OVERFLOW START\n");

    return (int)recurse(0u);
}
