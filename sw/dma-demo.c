// SPDX-FileCopyrightText: 2026 emmtrix Technologies GmbH
// SPDX-License-Identifier: Apache-2.0

#include <stdio.h>
#include <stdint.h>
#include "cluster_sync.h"

#define DMA_ELEMS 128u

static volatile uint32_t src_buf[DMA_ELEMS];
static volatile uint32_t dst_buf[DMA_ELEMS];

int main(void) {
    uint32_t hart = cl_read_mhartid();

    if (hart >= NUM_CORES) {
        return 1;
    }
    if (hart != 0u) {
        while (1) {
            __asm__ volatile ("wfi");
        }
    }

    for (uint32_t i = 0; i < DMA_ELEMS; i++) {
        src_buf[i] = 0xA5000000u ^ (i * 0x1021u) ^ (i << 8);
        dst_buf[i] = 0u;
    }
    cl_fence();

    cl_dma_memcpy((void *)dst_buf, (const void *)src_buf, DMA_ELEMS * sizeof(uint32_t));
    cl_dma_wait();

    for (uint32_t i = 0; i < DMA_ELEMS; i++) {
        if (dst_buf[i] != src_buf[i]) {
            puts("DMA DEMO FAIL");
            return 1;
        }
    }

    puts("DMA DEMO PASS");
    return 0;
}
