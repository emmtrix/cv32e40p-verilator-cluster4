// SPDX-FileCopyrightText: 2026 emmtrix Technologies GmbH
// SPDX-License-Identifier: Apache-2.0

/*
 * spm-stress-test.c - reproduces a suspected local-scratchpad access issue
 * using only plain C reads/writes (no stack-pointer relocation). Core 0
 * issues consecutive, unrolled stores/loads to its own local scratchpad to
 * mimic the back-to-back traffic a C stack's function prologues generate.
 */

#include <stdio.h>
#include <stdint.h>
#include "cluster_sync.h"

static volatile uint32_t ram_buf[8];

int main(void) {
    uint32_t hart = cl_read_mhartid();
    if (hart != 0u)
        return 0;

    volatile uint32_t *p = SPM_PTR(0);

    printf("[SPM-STRESS] phase 1: back-to-back unrolled stores\n");
    p[0]  = 0x11111111u;
    p[1]  = 0x22222222u;
    p[2]  = 0x33333333u;
    p[3]  = 0x44444444u;
    p[4]  = 0x55555555u;
    p[5]  = 0x66666666u;
    p[6]  = 0x77777777u;
    p[7]  = 0x88888888u;
    printf("[SPM-STRESS] phase 1 done\n");

    printf("[SPM-STRESS] phase 2: back-to-back unrolled loads\n");
    uint32_t a0 = p[0];
    uint32_t a1 = p[1];
    uint32_t a2 = p[2];
    uint32_t a3 = p[3];
    uint32_t a4 = p[4];
    uint32_t a5 = p[5];
    uint32_t a6 = p[6];
    uint32_t a7 = p[7];
    printf("[SPM-STRESS] phase 2 done\n");
    printf("a0=0x%08lx a1=0x%08lx a2=0x%08lx a3=0x%08lx\n",
           (unsigned long)a0, (unsigned long)a1, (unsigned long)a2, (unsigned long)a3);
    printf("a4=0x%08lx a5=0x%08lx a6=0x%08lx a7=0x%08lx\n",
           (unsigned long)a4, (unsigned long)a5, (unsigned long)a6, (unsigned long)a7);

    printf("[RAM-STRESS] phase 1: back-to-back unrolled stores to shared ram\n");
    ram_buf[0] = 0x11111111u;
    ram_buf[1] = 0x22222222u;
    ram_buf[2] = 0x33333333u;
    ram_buf[3] = 0x44444444u;
    ram_buf[4] = 0x55555555u;
    ram_buf[5] = 0x66666666u;
    ram_buf[6] = 0x77777777u;
    ram_buf[7] = 0x88888888u;
    printf("[RAM-STRESS] phase 2: back-to-back unrolled loads from shared ram\n");
    uint32_t r0 = ram_buf[0];
    uint32_t r1 = ram_buf[1];
    uint32_t r2 = ram_buf[2];
    uint32_t r3 = ram_buf[3];
    uint32_t r4 = ram_buf[4];
    uint32_t r5 = ram_buf[5];
    uint32_t r6 = ram_buf[6];
    uint32_t r7 = ram_buf[7];
    printf("r0=0x%08lx r1=0x%08lx r2=0x%08lx r3=0x%08lx\n",
           (unsigned long)r0, (unsigned long)r1, (unsigned long)r2, (unsigned long)r3);
    printf("r4=0x%08lx r5=0x%08lx r6=0x%08lx r7=0x%08lx\n",
           (unsigned long)r4, (unsigned long)r5, (unsigned long)r6, (unsigned long)r7);

    printf("[SPM-STRESS] phase 3: immediate read-after-write same address\n");
    p[0] = 0xDEADBEEFu;
    uint32_t raw = p[0];
    printf("[SPM-STRESS] phase 3 done raw=0x%08lx\n", (unsigned long)raw);

    int fail = 0;
    if (a0 != 0x11111111u) fail = 1;
    if (a1 != 0x22222222u) fail = 1;
    if (a2 != 0x33333333u) fail = 1;
    if (a3 != 0x44444444u) fail = 1;
    if (a4 != 0x55555555u) fail = 1;
    if (a5 != 0x66666666u) fail = 1;
    if (a6 != 0x77777777u) fail = 1;
    if (a7 != 0x88888888u) fail = 1;
    if (raw != 0xDEADBEEFu) fail = 1;
    if (r0 != 0x11111111u) fail = 1;
    if (r1 != 0x22222222u) fail = 1;
    if (r2 != 0x33333333u) fail = 1;
    if (r3 != 0x44444444u) fail = 1;
    if (r4 != 0x55555555u) fail = 1;
    if (r5 != 0x66666666u) fail = 1;
    if (r6 != 0x77777777u) fail = 1;
    if (r7 != 0x88888888u) fail = 1;

    if (fail) {
        printf("SPM STRESS TEST FAIL\n");
        return 1;
    }

    printf("SPM STRESS TEST PASS\n");
    return 0;
}
