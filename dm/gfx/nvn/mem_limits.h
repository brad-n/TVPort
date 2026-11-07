// Upload staging and texture-creation limits derived from the memory a process on iOS/tvOS can still use (os_proc_available_memory at device setup).
// Pure arithmetic, so a CPU-only test covers it (dm/gfx/tests/t_mem_limits.c). The Mac does not call this and keeps the fixed defaults (32 MB block, 128 MB batch, recommendedMaxWorkingSetSize / 20).
//
// tvOS ends the app at about 2.1 GB of footprint, and the staging blocks are private GPU memory that counts against it. What the staging may hold, worst case, is 6 blocks
// (3 slots x primary + overflow) kept after a scene load, so the block size is chosen so that those 6 blocks stay near 1/16 of what is available:
//     up_block = largest power of two <= avail / 96, within [4 MB, 32 MB]            (1.9 GB available -> 16 MB, 96 MB held at worst = 5%; 1 GB -> 8 MB; 3 GB or more -> 32 MB, as on the Mac)
// One batch may add temporary blocks beyond the retained ones before it is split into another batch; a third of the retained worst case keeps that bounded:
//     up_batch = avail / 32, within [2 x up_block, 128 MB]                             (1.9 GB -> 59 MB)
// The texture creation budget (pool_budget) is compared with the GPU's total allocation, so it only needs a ceiling for small devices: avail / 16 (1.9 GB -> 118 MB); it never raises recommendedMaxWorkingSetSize / 20.
#pragma once
#include <stddef.h>
#include <stdint.h>

typedef struct { size_t up_block, up_batch; uint64_t pool_budget; } dm_mem_limits_t;

static inline void dm_mem_limits(uint64_t avail, uint64_t recommended, dm_mem_limits_t *o) {
    const uint64_t MB = 1024ull * 1024ull;
    (void)recommended;
    if (!avail) avail = 1024 * MB;   // os_proc_available_memory gave nothing (0 also means "at the limit"): assume a small device rather than the Mac's sizes
    uint64_t blk = 4 * MB;
    while (blk < 32 * MB && (blk << 1) <= avail / 96) blk <<= 1;
    uint64_t batch = avail / 32;
    if (batch < 2 * blk) batch = 2 * blk;
    if (batch > 128 * MB) batch = 128 * MB;
    o->up_block = (size_t)blk; o->up_batch = (size_t)batch; o->pool_budget = avail / 16;
}
