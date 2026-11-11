// DM_GUEST_ZERO_PUNCH (nvn_mtl.m mtl_zero_punch, nvn_dirty.c nvn_dirty_punch_zero): all-0 dirty pages of a pool's memory, here a shared file mapping as the guest file is, go back to the file as
// holes only when exact. A round protects the pages; the next punches those still protected and still 0, so their blocks go and they read 0. A page written in between is kept (its write
// faulted and unprotected it), as is a non-zero page; a pool the GPU may reach (resident, or used by a submission not completed) and memory a sparse virtual pool maps elsewhere are left
// alone. A thread writing a page while rounds run never loses a write: a write waits while its page is checked and punched, and lands after
#include "../nvn/nvn_mtl.m"
#include <pthread.h>
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t *g_mod; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
void crash_install(void);
void nvn_phys_remap_note(uintptr_t lo, uintptr_t hi);
static int checks, failed;
#define CHECK(label, c) do { checks++; if (!(c)) { failed++; fprintf(stderr, "FAIL: %s (line %d)\n", label, __LINE__); } } while (0)
enum { MB = 1 << 20 };
static int g_fd; static uint8_t *g_m; static size_t g_pgz;
static int test_punch(uintptr_t a, size_t n) { fpunchhole_t ph = {0}; ph.fp_offset = (off_t)(a - (uintptr_t)g_m); ph.fp_length = (off_t)n; return fcntl(g_fd, F_PUNCHHOLE, &ph) == 0; }
static double blocks_mb(void) { struct stat st; fstat(g_fd, &st); return st.st_blocks * 512.0 / MB; }
static size_t round_(uint64_t lo, uint64_t hi) { uint64_t looked = 0; return mtl_zero_punch(lo, hi, &looked); }
static _Atomic int g_stop, g_lost; static _Atomic uint64_t g_writes;
static void *writer(void *arg) {   // writes a counter at the start of its page and reads it back, then makes the page all 0 again (a candidate), over and over
    volatile uint32_t *p = arg;
    for (uint32_t i = 1; !atomic_load(&g_stop); i++) {
        p[0] = i; for (volatile int s = 0; s < 200; s++) {} if (p[0] != i) atomic_fetch_add(&g_lost, 1);
        p[0] = 0; for (volatile int s = 0; s < 200; s++) {} if (p[0] != 0) atomic_fetch_add(&g_lost, 1);
        atomic_fetch_add(&g_writes, 1);
    }
    return NULL;
}
int main(void) { @autoreleasepool {
    crash_install(); mtl_init(); g_pgz = (size_t)getpagesize(); g_zp_punch = test_punch;
    char path[] = "/tmp/t_zero_punch_XXXXXX"; g_fd = mkstemp(path); if (g_fd < 0) abort(); unlink(path);
    const size_t SZ = 64 * MB; if (ftruncate(g_fd, (off_t)SZ)) abort();
    g_m = mmap(NULL, SZ, PROT_READ | PROT_WRITE, MAP_SHARED, g_fd, 0); if (g_m == MAP_FAILED) abort();
    uint64_t base = (uint64_t)(uintptr_t)g_m;
    memset(g_m, 0, SZ); memset(g_m + 10 * MB, 0x77, g_pgz); msync(g_m, SZ, MS_SYNC);   // every page written: blocks on the disk, all 0 but one page
    CHECK("the file holds its blocks", blocks_mb() > 60);
    mtl_pool_add(g_m, SZ); nvn_dirty_add_range(g_m, SZ);
    // Round 1 protects, punches nothing
    CHECK("round 1 punches nothing", round_(base, base + SZ) == 0);
    // A write after protection: faults, lands, keeps its page out of round 2
    g_m[20 * MB + 8] = 0x33;
    size_t got = round_(base, base + SZ);
    CHECK("round 2 punches every page still protected and 0", got == SZ - 2 * g_pgz);
    CHECK("the blocks are given back", blocks_mb() < 1);
    int zero = 1; for (size_t o = 0; o < SZ; o += 4096) if (o / g_pgz != 10 * MB / g_pgz && o / g_pgz != 20 * MB / g_pgz && g_m[o]) zero = 0;
    CHECK("punched pages read 0", zero);
    CHECK("the non-zero page is kept", g_m[10 * MB] == 0x77 && g_m[10 * MB + g_pgz - 1] == 0x77);
    CHECK("the page written between rounds is kept", g_m[20 * MB + 8] == 0x33);
    g_m[30 * MB] = 5; CHECK("a punched page takes a write", g_m[30 * MB] == 5);
    // A pool the GPU may reach is left alone: resident, then used by a submission not completed
    memset(g_m + 40 * MB, 0, 4 * MB); (void)round_(base + 40 * MB, base + 44 * MB);   // protected now
    void *mb = NULL; uint64_t mo = 0, gpu = 0; CHECK("the pool made resident", mtl_gpu_addr(base + 41 * MB, 64, &mb, &mo, &gpu));
    uint64_t sk0 = g_zp_skip_gpu; double b0 = blocks_mb();
    CHECK("a resident pool: nothing punched", round_(base + 40 * MB, base + 44 * MB) == 0 && g_zp_skip_gpu == sk0 + 1);
    pthread_mutex_lock(&g_mu); for (int i = 0; i < g_npool; i++) if (g_pools[i].key == g_m) { if (g_pools[i].res) { res_remove(g_pools[i].buf); g_pools[i].res = 0; g_pool_res_n--; } atomic_store(g_pools[i].used, g_done + 5); } pthread_mutex_unlock(&g_mu);
    CHECK("used by a submission not completed: nothing punched", round_(base + 40 * MB, base + 44 * MB) == 0 && g_zp_skip_gpu == sk0 + 2);
    pthread_mutex_lock(&g_mu); for (int i = 0; i < g_npool; i++) if (g_pools[i].key == g_m) atomic_store(g_pools[i].used, 0); pthread_mutex_unlock(&g_mu);
    CHECK("no block was given back meanwhile", blocks_mb() >= b0);
    // Memory a sparse virtual pool maps elsewhere is left alone
    nvn_phys_remap_note((uintptr_t)(g_m + 48 * MB), (uintptr_t)(g_m + 52 * MB));
    memset(g_m + 48 * MB, 0, 4 * MB);
    CHECK("remapped memory: nothing", round_(base + 48 * MB, base + 52 * MB) == 0 && round_(base + 48 * MB, base + 52 * MB) == 0 && g_zp_skip_remap == 2);
    CHECK("now the GPU is done: the protected zero pages go", round_(base + 40 * MB, base + 44 * MB) == 4 * MB);
    // A writer racing the rounds never loses a write
    uint8_t *page = g_m + 56 * MB;
    pthread_t th; pthread_create(&th, NULL, writer, page);
    uint64_t t0 = clock_gettime_nsec_np(CLOCK_MONOTONIC); size_t raced = 0; int rounds = 0;
    while (clock_gettime_nsec_np(CLOCK_MONOTONIC) - t0 < 1500000000ull) { raced += round_(base + 56 * MB, base + 56 * MB + g_pgz); rounds++; usleep((useconds_t)(arc4random_uniform(60))); }
    atomic_store(&g_stop, 1); pthread_join(th, NULL);
    CHECK("the writer ran", atomic_load(&g_writes) > 300);
    CHECK("pages were punched while it wrote", raced > 0);
    CHECK("no write was lost", atomic_load(&g_lost) == 0);
    fprintf(stderr, "race: %d rounds, %zu KB punched, %llu writer loops\n", rounds, raced >> 10, (unsigned long long)atomic_load(&g_writes));
    mtl_pool_del(g_m); nvn_dirty_remove_range(g_m); mtl_drain();
    printf("t_zero_punch: %d checks, %d failed\n", checks, failed); return failed != 0;
} }
