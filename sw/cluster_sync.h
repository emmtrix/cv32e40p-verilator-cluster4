// SPDX-FileCopyrightText: 2024 emmtrix Technologies GmbH
// SPDX-License-Identifier: Apache-2.0

#ifndef CLUSTER_SYNC_H
#define CLUSTER_SYNC_H

#include <stdint.h>

#ifndef NUM_CORES
#define NUM_CORES 4
#endif

/*
 * Scratchpad memory (SPM) address helpers.
 * SPM_SIZE must match the RTL parameter 2**SPM_ADDR_WIDTH (default 256 KiB).
 */
#define SPM_BASE_ADDR  0x18000000u
#define SPM_SIZE       262144u
#define SPM_ADDR(core_id)  (SPM_BASE_ADDR + (uint32_t)(core_id) * SPM_SIZE)
#define SPM_PTR(core_id)   ((volatile uint32_t *)SPM_ADDR(core_id))

/*
 * Minimal EU-style barrier peripheral addresses implemented by tb/mm_ram.sv.
 * These mirror the SDK usage pattern without depending on pulp-sdk headers.
 */
#define CL_EU_BASE_ADDR           0x15002000u
#define CL_EU_WAIT_BARRIER_ADDR   (CL_EU_BASE_ADDR + 0x0000u)
#define CL_EU_SET_BARRIER_ADDR    (CL_EU_BASE_ADDR + 0x0040u)
#define CL_EU_GPEVT_CLEAR_ADDR    (CL_EU_BASE_ADDR + 0x0084u)

/*
 * Per-core DMA MMIO aliases.
 * Write order: SRC, DST, SRC_STRIDE, DST_STRIDE, COUNT, LEN. Writing LEN
 * enqueues the memcpy task.
 */
#define CL_DMA_BASE_ADDR          0x15003000u
#define CL_DMA_SRC_ADDR           (CL_DMA_BASE_ADDR + 0x0000u)
#define CL_DMA_DST_ADDR           (CL_DMA_BASE_ADDR + 0x0004u)
#define CL_DMA_LEN_ADDR           (CL_DMA_BASE_ADDR + 0x0008u)
#define CL_DMA_WAIT_ADDR          (CL_DMA_BASE_ADDR + 0x000Cu)
#define CL_DMA_SRC_STRIDE_ADDR    (CL_DMA_BASE_ADDR + 0x0010u)
#define CL_DMA_DST_STRIDE_ADDR    (CL_DMA_BASE_ADDR + 0x0014u)
#define CL_DMA_COUNT_ADDR         (CL_DMA_BASE_ADDR + 0x0018u)

/* Event selector bits from CV32E40P perf counter docs. */
typedef enum {
    CL_MHPM_EVENT_CYCLES = 0,
    CL_MHPM_EVENT_INSTR = 1,
    CL_MHPM_EVENT_LD_STALL = 2,
    CL_MHPM_EVENT_JMP_STALL = 3,
    CL_MHPM_EVENT_IMISS = 4,
    CL_MHPM_EVENT_LD = 5,
    CL_MHPM_EVENT_ST = 6,
    CL_MHPM_EVENT_JUMP = 7,
    CL_MHPM_EVENT_BRANCH = 8,
    CL_MHPM_EVENT_BRANCH_TAKEN = 9,
    CL_MHPM_EVENT_COMP_INSTR = 10,
    CL_MHPM_EVENT_PIPE_STALL = 11
} cl_mhpm_event_t;

static inline uint32_t cl_read_mhartid(void) {
    uint32_t hart;
    __asm__ volatile ("csrr %0, mhartid" : "=r"(hart));
    return hart;
}

static inline void cl_fence(void) {
    __asm__ volatile ("fence rw, rw" ::: "memory");
}

static inline uint32_t cl_read_csr_mcountinhibit(void) {
    uint32_t val;
    __asm__ volatile ("csrr %0, mcountinhibit" : "=r"(val));
    return val;
}

static inline void cl_write_csr_mcountinhibit(uint32_t val) {
    __asm__ volatile ("csrw mcountinhibit, %0" :: "r"(val) : "memory");
}

static inline void cl_write_csr_mhpmcounter3(uint32_t val) {
    __asm__ volatile ("csrw mhpmcounter3, %0" :: "r"(val) : "memory");
}

static inline void cl_write_csr_mhpmcounter3h(uint32_t val) {
    __asm__ volatile ("csrw mhpmcounter3h, %0" :: "r"(val) : "memory");
}

static inline uint32_t cl_read_csr_mhpmcounter3(void) {
    uint32_t val;
    __asm__ volatile ("csrr %0, mhpmcounter3" : "=r"(val));
    return val;
}

static inline uint32_t cl_read_csr_mhpmcounter3h(void) {
    uint32_t val;
    __asm__ volatile ("csrr %0, mhpmcounter3h" : "=r"(val));
    return val;
}

static inline uint64_t cl_read_mhpmcounter3_64(void) {
    uint32_t hi0, lo, hi1;
    do {
        hi0 = cl_read_csr_mhpmcounter3h();
        lo = cl_read_csr_mhpmcounter3();
        hi1 = cl_read_csr_mhpmcounter3h();
    } while (hi0 != hi1);
    return ((uint64_t)hi1 << 32) | (uint64_t)lo;
}

static inline void cl_perf_mhpmcounter3_set_event(cl_mhpm_event_t event_bit) {
    uint32_t sel = (event_bit < 32u) ? (1u << event_bit) : 0u;
    __asm__ volatile ("csrw mhpmevent3, %0" :: "r"(sel) : "memory");
}

static inline void cl_perf_mhpmcounter3_reset(void) {
    cl_write_csr_mhpmcounter3(0u);
    cl_write_csr_mhpmcounter3h(0u);
}

static inline void cl_perf_mhpmcounter3_enable(void) {
    uint32_t inhibit = cl_read_csr_mcountinhibit();
    inhibit &= ~(1u << 3);
    cl_write_csr_mcountinhibit(inhibit);
}

static inline void cl_perf_mhpmcounter3_disable(void) {
    uint32_t inhibit = cl_read_csr_mcountinhibit();
    inhibit |= (1u << 3);
    cl_write_csr_mcountinhibit(inhibit);
}

static inline void cl_perf_mhpmcounter3_config(cl_mhpm_event_t event_bit) {
    cl_perf_mhpmcounter3_disable();
    cl_perf_mhpmcounter3_set_event(event_bit);
    cl_perf_mhpmcounter3_reset();
    cl_perf_mhpmcounter3_enable();
}

static inline void cl_mmio_write(uint32_t addr, uint32_t value) {
    *(volatile uint32_t *)addr = value;
}

static inline uint32_t cl_mmio_read(uint32_t addr) {
    return *(volatile uint32_t *)addr;
}

typedef struct {
    volatile uint32_t barrier_id;
    volatile uint32_t initialized;
} cl_barrier_t;

static inline void cl_barrier_setup(uint32_t barrier_id, uint32_t num_threads, uint32_t trigger_mask) {
    uint32_t cfg = (num_threads << 16) | trigger_mask;
    cl_mmio_write(CL_EU_SET_BARRIER_ADDR + (barrier_id << 2), cfg);
}

static inline void cl_barrier_notify(uint32_t barrier_id) {
    cl_mmio_write(CL_EU_WAIT_BARRIER_ADDR, barrier_id);
}

static inline void cl_evt_wait(void) {
    /*
     * Set mie[30] (EU barrier fast IRQ) so the core's irq_wu_ctrl fires when
     * the EU asserts irq_i[30].  mstatus.MIE stays 0, so the interrupt is
     * never *taken* (no ISR jump), but WFI exits as soon as the bit is pending.
     * Clear mie[30] again before returning so we leave no stray enables behind.
     */
    uint32_t eu_irq_mask = (1u << 30u);
    __asm__ volatile (
        "csrs mie, %0\n\t"
        "wfi\n\t"
        "csrc mie, %0"
        : : "r"(eu_irq_mask) : "memory"
    );
}

static inline void cl_gpevt_clear(uint32_t barrier_id) {
    cl_mmio_write(CL_EU_GPEVT_CLEAR_ADDR, barrier_id);
}

static inline void cl_dma_memcpy(void *dst, const void *src, uint32_t len_bytes) {
    cl_mmio_write(CL_DMA_SRC_ADDR, (uint32_t)(uintptr_t)src);
    cl_mmio_write(CL_DMA_DST_ADDR, (uint32_t)(uintptr_t)dst);
    cl_mmio_write(CL_DMA_SRC_STRIDE_ADDR, len_bytes);
    cl_mmio_write(CL_DMA_DST_STRIDE_ADDR, len_bytes);
    cl_mmio_write(CL_DMA_COUNT_ADDR, 1u);
    cl_mmio_write(CL_DMA_LEN_ADDR, len_bytes);
}

/*
 * Strided copy: copies `count` chunks of `chunk_bytes`, advancing src by
 * `src_stride_bytes` and dst by `dst_stride_bytes` between chunks. Setting
 * dst_stride_bytes == chunk_bytes packs the dst (gather); setting
 * src_stride_bytes == chunk_bytes packs the src (scatter). A count of 0
 * copies nothing; count of 1 behaves like a single cl_dma_memcpy.
 */
static inline void cl_dma_memcpy_strided(void *dst, const void *src,
                                          uint32_t chunk_bytes,
                                          uint32_t src_stride_bytes,
                                          uint32_t dst_stride_bytes,
                                          uint32_t count) {
    cl_mmio_write(CL_DMA_SRC_ADDR, (uint32_t)(uintptr_t)src);
    cl_mmio_write(CL_DMA_DST_ADDR, (uint32_t)(uintptr_t)dst);
    cl_mmio_write(CL_DMA_SRC_STRIDE_ADDR, src_stride_bytes);
    cl_mmio_write(CL_DMA_DST_STRIDE_ADDR, dst_stride_bytes);
    cl_mmio_write(CL_DMA_COUNT_ADDR, count);
    cl_mmio_write(CL_DMA_LEN_ADDR, chunk_bytes);
}

static inline void cl_dma_wait(void) {
    (void)cl_mmio_read(CL_DMA_WAIT_ADDR);
}

static inline void cl_barrier_init(cl_barrier_t *bar) {
    uint32_t all_cores_mask = (NUM_CORES >= 32u) ? 0xFFFFFFFFu : ((1u << NUM_CORES) - 1u);
    bar->barrier_id = 0u;
    cl_barrier_setup(bar->barrier_id, NUM_CORES, all_cores_mask);
    cl_fence();
    bar->initialized = 1u;
    cl_fence();
}

static inline void cl_barrier_wait(cl_barrier_t *bar) {
    while (bar->initialized == 0u) {}
    cl_fence();
    cl_barrier_notify(bar->barrier_id);
    cl_evt_wait();
    cl_gpevt_clear(bar->barrier_id);
    cl_fence();
}

#endif
