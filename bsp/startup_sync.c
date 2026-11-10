// SPDX-FileCopyrightText: 2026 Embecosm Limited
// SPDX-License-Identifier: Apache-2.0

/*
 * Hart 0 alone clears .bss and runs __libc_init_array, so the other harts must
 * not enter main() until that's done.
 */

#include <stdint.h>

static volatile uint32_t g_crt0_ready = 0u;

void crt0_hart0_signal_ready(void) {
    __asm__ volatile("fence rw, rw" ::: "memory");
    g_crt0_ready = 1u;
    __asm__ volatile("fence rw, rw" ::: "memory");
}

void crt0_wait_ready(void) {
    while (g_crt0_ready == 0u) {
    }
    __asm__ volatile("fence rw, rw" ::: "memory");
}
