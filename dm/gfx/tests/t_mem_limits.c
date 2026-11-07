// Memory-derived upload staging / texture budget limits (nvn/mem_limits.h): CPU-only.
#include <stdio.h>
#include "../nvn/mem_limits.h"
static int checks, fails;
#define CHECK(c, msg) do { checks++; if (!(c)) { fails++; fprintf(stderr, "FAIL: %s\n", msg); } } while (0)
#define MB(x) ((uint64_t)(x) * 1024ull * 1024ull)
int main(void) {
    dm_mem_limits_t l;
    dm_mem_limits(MB(1900), MB(3000), &l);   // Apple TV at launch
    CHECK(l.up_block == MB(16), "1.9 GB -> 16 MB blocks");
    CHECK(l.up_batch == MB(1900) / 32 && l.up_batch >= 2 * l.up_block, "1.9 GB -> batch about 59 MB");
    CHECK(l.pool_budget == MB(1900) / 16, "1.9 GB -> pool ceiling avail/16");
    dm_mem_limits(MB(1024), 0, &l);
    CHECK(l.up_block == MB(8), "1 GB -> 8 MB blocks");
    dm_mem_limits(MB(3500), 0, &l);
    CHECK(l.up_block == MB(32) && l.up_batch == MB(3500) / 32, "3.5 GB -> the Mac block size");
    dm_mem_limits(MB(100000), 0, &l);
    CHECK(l.up_block == MB(32) && l.up_batch == MB(128), "huge memory clamps to the Mac defaults");
    dm_mem_limits(MB(100), 0, &l);
    CHECK(l.up_block == MB(4) && l.up_batch >= MB(8), "tiny memory floors at 4 MB blocks, batch holds two");
    dm_mem_limits(0, 0, &l);
    CHECK(l.up_block == MB(8) && l.up_batch > 0, "0 available is treated as a small device");
    for (uint64_t a = MB(64); a <= MB(8192); a += MB(37)) {
        dm_mem_limits(a, 0, &l);
        CHECK((l.up_block & (l.up_block - 1)) == 0 && l.up_block >= MB(4) && l.up_block <= MB(32), "block is a power of two in [4,32] MB");
        CHECK(l.up_batch >= 2 * l.up_block && l.up_batch <= MB(128), "batch in [2 blocks, 128 MB]");
        if (a >= MB(384)) CHECK(l.up_block * 6 <= a / 8, "worst-case retained staging stays within 1/8 of available");
    }
    if (fails) { fprintf(stderr, "t_mem_limits: %d of %d failed\n", fails, checks); return 1; }
    printf("t_mem_limits: %d checks passed\n", checks);
    return 0;
}
