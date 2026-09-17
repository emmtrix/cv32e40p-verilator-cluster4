// SPDX-FileCopyrightText: 2026 emmtrix Technologies GmbH
// SPDX-License-Identifier: Apache-2.0

#include <stdio.h>
#include <stdint.h>
#include "cluster_sync.h"

/* Source is a SRC_ROWS x SRC_COLS matrix; we DMA a WIN_ROWS x WIN_COLS
 * sub-window out of it into a packed destination matrix. */
#define SRC_ROWS        16u
#define SRC_COLS        16u
#define WIN_ROWS        4u
#define WIN_COLS        6u
#define WIN_ROW_OFFSET  5u
#define WIN_COL_OFFSET  3u

static volatile uint32_t src_buf[SRC_ROWS][SRC_COLS];
static volatile uint32_t dst_buf[WIN_ROWS][WIN_COLS];

int main(void) {
    uint32_t hart = cl_read_mhartid();

    if (hart != 0u) {
        return 1;
    }

    for (uint32_t r = 0; r < SRC_ROWS; r++) {
        for (uint32_t c = 0; c < SRC_COLS; c++) {
            uint32_t i = r * SRC_COLS + c;
            src_buf[r][c] = 0x5A000000u ^ (i * 0x1021u) ^ (i << 8);
        }
    }
    for (uint32_t r = 0; r < WIN_ROWS; r++) {
        for (uint32_t c = 0; c < WIN_COLS; c++) {
            dst_buf[r][c] = 0u;
        }
    }
    cl_fence();

    /* Each window row is contiguous (WIN_COLS elements); consecutive rows are
     * SRC_COLS elements apart in the source but packed tightly in the dest. */
    cl_dma_memcpy_strided((void *)dst_buf,
                           (const void *)&src_buf[WIN_ROW_OFFSET][WIN_COL_OFFSET],
                           sizeof(dst_buf[0]),
                           sizeof(src_buf[0]),
                           WIN_ROWS);
    cl_dma_wait();

    for (uint32_t r = 0; r < WIN_ROWS; r++) {
        for (uint32_t c = 0; c < WIN_COLS; c++) {
            if (dst_buf[r][c] != src_buf[WIN_ROW_OFFSET + r][WIN_COL_OFFSET + c]) {
                puts("STRIDED DMA DEMO FAIL");
                return 1;
            }
        }
    }

    puts("STRIDED DMA DEMO PASS");
    return 0;
}
