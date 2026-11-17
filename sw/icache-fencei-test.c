// SPDX-FileCopyrightText: 2026 emmtrix Technologies GmbH
// SPDX-License-Identifier: Apache-2.0

/*
 * icache-fencei-test.c - instruction cache coherence via fence.i.
 *
 * All harts run concurrently. Each hart generates tiny functions
 * ("li a0, imm; ret") in shared RAM, executes them, rewrites them through
 * different paths and checks which version executes:
 *
 *   store       : own stores + fence.i            -> new code must run
 *   stale       : own stores, no fence            -> old code still cached
 *   plain fence : own stores + fence rw,rw        -> old code still cached
 *                 (FENCE does not order instruction fetch)
 *   dma         : DMA writes the code + fence.i   -> new code must run
 *   remote      : the next hart writes the code,
 *                 barrier, then fence.i           -> new code must run
 *   evict       : EVICT_FUNCS functions that map to the same cache set
 *                 (4 KiB apart) called round-robin, one of them straddling
 *                 a cache line boundary; repeated after rewriting all of
 *                 them + fence.i
 *
 * The stale results depend on the instruction cache being present, so they
 * are printed (STALE ... observed=...) and checked by the pytest, which knows
 * the cache configuration. Everything else must hold with and without cache.
 */

#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>

#include "cluster_sync.h"

#define BUF_WORDS   1024u   /* 4 KiB per buffer: equal cache set index */
#define EVICT_FUNCS 5u
#define RET_INSN    0x00008067u /* jalr x0, 0(ra) */

typedef uint32_t (*fn_t)(void);

static cl_barrier_t bar;
static volatile uint32_t code[NUM_CORES][EVICT_FUNCS + 1u][BUF_WORDS] __attribute__((aligned(4096)));
static volatile uint32_t dma_src[NUM_CORES][4] __attribute__((aligned(16)));
static volatile uint32_t fails[NUM_CORES];
static volatile uint32_t stale_nofence[NUM_CORES];
static volatile uint32_t stale_fence[NUM_CORES];

static inline void fence_i(void) {
    __asm__ volatile ("fence.i" ::: "memory");
}

/* addi a0, x0, imm */
static inline uint32_t li_a0(uint32_t imm) {
    return ((imm & 0xFFFu) << 20) | (10u << 7) | 0x13u;
}

/* Offset (in words) of the function inside buffer `idx`. Buffer 1 places
 * its entry in the last word of a 16-byte line so "li" and "ret" sit in
 * different lines. */
static inline uint32_t entry_word(uint32_t idx) {
    return (idx == 1u) ? 3u : 0u;
}

static inline volatile uint32_t *entry(uint32_t hart, uint32_t idx) {
    return &code[hart][idx][entry_word(idx)];
}

static void write_fn(volatile uint32_t *p, uint32_t imm) {
    p[0] = li_a0(imm);
    p[1] = RET_INSN;
}

static inline uint32_t call_fn(volatile uint32_t *p) {
    return ((fn_t)(uintptr_t)p)();
}

static void check(uint32_t hart, const char *what, uint32_t got, uint32_t want) {
    if (got != want) {
        printf("ICACHE FENCEI FAIL hart=%" PRIu32 " %s got=%" PRIu32 " want=%" PRIu32 "\n",
               hart, what, got, want);
        fails[hart]++;
    }
}

static uint32_t imm_for(uint32_t hart, uint32_t step) {
    return 100u * (hart + 1u) + step;
}

int main(void) {
    uint32_t hart = cl_read_mhartid();
    if (hart >= NUM_CORES) {
        return 1;
    }

    if (hart == 0u) {
        cl_barrier_init(&bar);
    }
    cl_barrier_wait(&bar);

    volatile uint32_t *f = entry(hart, 0);

    /* store: initial code, then a rewrite, each followed by fence.i. */
    write_fn(f, imm_for(hart, 1));
    fence_i();
    check(hart, "store-initial", call_fn(f), imm_for(hart, 1));
    check(hart, "store-initial-again", call_fn(f), imm_for(hart, 1));

    write_fn(f, imm_for(hart, 2));
    fence_i();
    check(hart, "store-rewrite", call_fn(f), imm_for(hart, 2));

    /* stale: rewrite without any fence. The line is cached, so the old
     * code is expected to run when the cache is enabled. */
    write_fn(f, imm_for(hart, 3));
    stale_nofence[hart] = call_fn(f);

    /* plain fence does not invalidate the instruction cache. */
    write_fn(f, imm_for(hart, 4));
    cl_fence();
    stale_fence[hart] = call_fn(f);

    fence_i();
    check(hart, "store-after-stale", call_fn(f), imm_for(hart, 4));

    /* dma: copy new code into the cached function, then fence.i. */
    dma_src[hart][0] = li_a0(imm_for(hart, 5));
    dma_src[hart][1] = RET_INSN;
    cl_dma_memcpy((void *)f, (const void *)dma_src[hart], 8u);
    cl_dma_wait();
    fence_i();
    check(hart, "dma", call_fn(f), imm_for(hart, 5));

    /* remote: the next hart rewrites our function. */
    uint32_t next = (hart + 1u) % NUM_CORES;
    cl_barrier_wait(&bar);
    write_fn(entry(next, 0), imm_for(next, 6));
    cl_fence();
    cl_barrier_wait(&bar);
    fence_i();
    check(hart, "remote", call_fn(f), imm_for(hart, 6));

    /* evict: more same-set functions than ways, called round-robin. */
    for (uint32_t i = 1u; i <= EVICT_FUNCS; ++i) {
        write_fn(entry(hart, i), imm_for(hart, 10u + i));
    }
    fence_i();
    for (uint32_t round = 0u; round < 4u; ++round) {
        for (uint32_t i = 1u; i <= EVICT_FUNCS; ++i) {
            check(hart, "evict", call_fn(entry(hart, i)), imm_for(hart, 10u + i));
        }
    }
    for (uint32_t i = 1u; i <= EVICT_FUNCS; ++i) {
        write_fn(entry(hart, i), imm_for(hart, 20u + i));
    }
    fence_i();
    for (uint32_t round = 0u; round < 4u; ++round) {
        for (uint32_t i = EVICT_FUNCS; i >= 1u; --i) {
            check(hart, "evict-rewrite", call_fn(entry(hart, i)), imm_for(hart, 20u + i));
        }
    }

    cl_fence();
    cl_barrier_wait(&bar);

    if (hart != 0u) {
        return 0;
    }

    uint32_t total_fails = 0u;
    for (uint32_t i = 0u; i < NUM_CORES; ++i) {
        printf("ICACHE FENCEI STALE hart=%" PRIu32 " nofence_observed=%" PRIu32
               " old=%" PRIu32 " new=%" PRIu32 "\n",
               i, stale_nofence[i], imm_for(i, 2), imm_for(i, 3));
        printf("ICACHE FENCEI STALE hart=%" PRIu32 " plainfence_observed=%" PRIu32
               " old=%" PRIu32 " new=%" PRIu32 "\n",
               i, stale_fence[i], imm_for(i, 2), imm_for(i, 4));
        total_fails += fails[i];
    }

    if (total_fails != 0u) {
        printf("ICACHE FENCEI TEST FAIL fails=%" PRIu32 "\n", total_fails);
        return 1;
    }
    puts("ICACHE FENCEI TEST PASS");
    return 0;
}
