// The command allocator a submission takes (DM_NVN_ALLOC_FIT, on by default): a submission of a known size (learned from the allocator it once grew) takes the smallest free allocator
// that holds it, else the largest free one; any other the smallest free one, so the small submissions stay on the small allocators; the largest free allocator is made again empty when it
// holds over 4 MB and over a quarter more than any remembered submission takes; busy allocators are never taken. Then real submissions run through the choice, across frames, and complete
#include "../nvn/nvn_mtl.m"
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t *g_mod; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int checks, failed;
#define CHECK(c, label) do { checks++; if (!(c)) { failed++; fprintf(stderr, "FAIL: %s (line %d)\n", label, __LINE__); } } while (0)
#define MB (1ull << 20)
int main(void) { @autoreleasepool {
    uint64_t sz[8] = {2 * MB, 16 * MB, 1 * MB, 70 * MB, 8 * MB, 0, 0, 0}; uint8_t fr[8] = {1, 1, 1, 1, 1, 0, 0, 0};
    CHECK(alloc_choose(sz, fr, 5, 0) == 2, "a small submission takes the smallest free allocator");
    CHECK(alloc_choose(sz, fr, 5, 12 * MB) == 1, "a known 12 MB one the smallest free that holds it (16 MB, not 70)");
    CHECK(alloc_choose(sz, fr, 5, 8 * MB) == 4, "exactly its size holds it");
    CHECK(alloc_choose(sz, fr, 5, 100 * MB) == 3, "one that nothing holds the largest free");
    fr[2] = 0; CHECK(alloc_choose(sz, fr, 5, 0) == 0, "a busy allocator is never taken");
    fr[1] = 0; CHECK(alloc_choose(sz, fr, 5, 12 * MB) == 3, "with the 16 MB one busy, the 70 MB one");
    uint8_t none[8] = {0}; CHECK(alloc_choose(sz, none, 5, 0) == -1 && alloc_choose(sz, none, 5, MB) == -1, "none free: none");
    uint8_t all[8] = {1, 1, 1, 1, 1, 0, 0, 0};
    CHECK(alloc_trim_victim(sz, all, 5, 16 * MB) == 3, "the 70 MB one is made again when the remembered submissions take 16 MB");
    CHECK(alloc_trim_victim(sz, all, 5, 60 * MB) == -1, "not when one takes 60 MB (a quarter more is 75)");
    uint64_t small[8] = {1 * MB, 3 * MB, 2 * MB}; CHECK(alloc_trim_victim(small, all, 3, 0) == -1, "nor at 4 MB or less");
    uint8_t busy[8] = {1, 1, 1, 0, 1}; CHECK(alloc_trim_victim(sz, busy, 5, 0) == 1, "a busy allocator is never made again: the largest free one");
    // real submissions through the choice, frame after frame: they complete; a frame's first submission takes an allocator, noted with its place (0), and the others share it
    // (upstream fd8188c9: the submissions of one frame share an allocator)
    mtl_init();
    CHECK(alloc_fit_on(), "on by default");
    for (uint64_t f = 1; f <= 40; f++) {
        atomic_store(&g_cur_frame, f); int first = -1;
        for (int k = 0; k < 4; k++) { mtl_sub_begin(); if (!k) first = g_alloc_cur;
            CHECK(g_alloc_cur >= 0 && g_alloc_cur < g_alloc_n && g_alloc_ordof[g_alloc_cur] == 0, "the frame's allocator is noted with the place of the submission that took it");
            CHECK(g_alloc_cur == first, "the frame's later submissions share its allocator");
            uint64_t fence = mtl_sub_commit(); if (k == 3 || f == 40) CHECK(mtl_wait(fence, 5000000000ull), "the submissions complete"); }
    }
    CHECK(g_alloc_n >= 1 && g_alloc_n <= ALLOC_MAX, "within the allocator cap");
    printf("t_alloc_fit: %d checks, %d failed\n", checks, failed);
    return failed != 0;
} }
