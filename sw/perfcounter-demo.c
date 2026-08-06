// SPDX-FileCopyrightText: 2026 emmtrix Technologies GmbH
// SPDX-License-Identifier: Apache-2.0

#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>

#include "cluster_sync.h"

#define NWORDS 128u
#define ROUNDS 256u
#define SPM_WORD_OFFSET 128u

static uint32_t run_load_sum(const volatile uint32_t *buf, uint32_t rounds) {
    uint32_t acc = 0u;

    for (uint32_t r = 0u; r < rounds; ++r) {
        for (uint32_t i = 0u; i < NWORDS; ++i) {
            acc += buf[i];
        }
    }

    return acc;
}

static uint64_t measure_cycles_load_sum(const volatile uint32_t *buf, uint32_t rounds, uint32_t *checksum) {
    cl_perf_mhpmcounter3_config(CL_HPM_EVENT_CYCLES);
    *checksum = run_load_sum(buf, rounds);
    cl_perf_mhpmcounter3_disable();
    return cl_read_mhpmcounter3_64();
}

int main(void) {
    uint32_t hart = cl_read_mhartid();
    if (hart != 0u) {
        return 0;
    }

    static volatile uint32_t shared_buf[NWORDS];
    volatile uint32_t *spm_buf = SPM_PTR(hart) + SPM_WORD_OFFSET;

    for (uint32_t i = 0u; i < NWORDS; ++i) {
        uint32_t v = i * 5u + 3u;
        shared_buf[i] = v;
        spm_buf[i] = v;
    }
    cl_fence();

    uint32_t shared_sum = 0u;
    uint32_t spm_sum = 0u;

    uint64_t shared_cycles = measure_cycles_load_sum(shared_buf, ROUNDS, &shared_sum);
    uint64_t spm_cycles = measure_cycles_load_sum(spm_buf, ROUNDS, &spm_sum);

    if (shared_sum != spm_sum) {
        printf("PERFCOUNTER DEMO FAIL checksum mismatch shared=%" PRIu32 " spm=%" PRIu32 "\n",
               shared_sum,
               spm_sum);
        return 1;
    }

    printf("PERFCOUNTER DEMO PASS hart=%" PRIu32
           " shared_cycles=%llu spm_cycles=%llu delta=%lld checksum=%" PRIu32 "\n",
           hart,
           (unsigned long long)shared_cycles,
           (unsigned long long)spm_cycles,
           (long long)shared_cycles - (long long)spm_cycles,
           shared_sum);

    return 0;
}
