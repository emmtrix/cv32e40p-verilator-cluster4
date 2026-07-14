// SPDX-FileCopyrightText: 2026 emmtrix Technologies GmbH
// SPDX-License-Identifier: Apache-2.0

#include <stdio.h>
#include <stdint.h>
#include "cluster_sync.h"

#define DMA_ELEMS 128u
#define DMA_CHUNKS 4u

static volatile uint32_t src_buf[DMA_ELEMS];
static volatile uint32_t dst_buf[DMA_ELEMS];

int main(void) {
    const uint32_t chunk_elems = DMA_ELEMS / DMA_CHUNKS;
    uint32_t hart = cl_read_mhartid();

    if (hart != 0u) {
        return 1;
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
            puts("DMA DEMO FAIL (single)");
            return 1;
        }
    }

    for (uint32_t i = 0; i < DMA_ELEMS; i++) {
        dst_buf[i] = 0u;
    }
    cl_fence();

    for (uint32_t c = 0; c < DMA_CHUNKS; c++) {
        uint32_t off = c * chunk_elems;
        cl_dma_memcpy((void *)&dst_buf[off],
                      (const void *)&src_buf[off],
                      chunk_elems * sizeof(uint32_t));
    }
    cl_dma_wait();

    for (uint32_t i = 0; i < DMA_ELEMS; i++) {
        if (dst_buf[i] != src_buf[i]) {
            puts("DMA DEMO FAIL (queued)");
            return 1;
        }
    }

    puts("DMA DEMO PASS");
    return 0;
}
