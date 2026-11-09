// DM_NVN_LEDGER=<seconds> (included by nvn_mtl.m; off by default): every <seconds> a thread logs where the graphics ledger (Metal's currentAllocatedSize) goes, in `[ledger]` lines:
// render targets by size and format, sampled textures (ASTC, BC and other, with the largest formats), buffers (pool buffers resident, other buffers), heaps, the recycled render-target heaps
// waiting (RH), the upload staging blocks kept, pool buffers freed but alive, and what is not in the residency set. It reads the residency set (g_res_objects, the same view as
// "GPU allocated by kind", which needs DM_NVN_ALLOCPROF and prints Metal's format numbers) and the pool table, under their locks for one copy of each, so a run's log tells which kind
// holds the memory when it nears the working set limit (the Apple TV's 1.55 GB at Link's house). Read-only: nothing here changes what the host allocates, keeps or frees
enum { LG_GROUPS = 96 };
typedef struct { uint64_t key; uint32_t n; uint64_t bytes; } lg_group;
static void lg_add(lg_group *g, int *ng, uint64_t key, uint64_t bytes) {
    int i = 0; while (i < *ng && g[i].key != key) i++;
    if (i == *ng) { if (*ng == LG_GROUPS) return; g[i].key = key; g[i].n = 0; g[i].bytes = 0; (*ng)++; }
    g[i].n++; g[i].bytes += bytes;
}
static const char *lg_fmt(uint32_t f, char *buf, size_t n) {
    switch (f) {
    case 10: return "R8"; case 25: return "RG8"; case 55: return "R16F"; case 65: return "RG16F"; case 70: return "RGBA8"; case 71: return "RGBA8s"; case 80: return "BGRA8";
    case 81: return "BGRA8s"; case 90: return "RGB10A2"; case 92: return "RG11B10F"; case 105: return "R32F"; case 115: return "RGBA16F"; case 125: return "RG32F"; case 124: return "RGBA16";
    case 252: return "D32F"; case 253: return "S8"; case 260: return "D32FS8";
    default: if (f >= 186 && f <= 225) snprintf(buf, n, "ASTC%u", f); else if (f >= 130 && f <= 153) snprintf(buf, n, "BC%u", f); else snprintf(buf, n, "fmt%u", f); return buf; }
}
static int lg_ucmp(const void *a, const void *b) { uintptr_t x = *(const uintptr_t *)a, y = *(const uintptr_t *)b; return x < y ? -1 : x > y; }   // macbench: pool buffer pointers
static int lg_cmp(const void *a, const void *b) { const lg_group *x = a, *y = b; return x->bytes < y->bytes ? 1 : x->bytes > y->bytes ? -1 : 0; }
static uint64_t g_lg_t0;
static void lg_dump(void) { @autoreleasepool {
    const double M = 1048576.0;
    uint64_t total = g_dev.currentAllocatedSize, rb = 0; unsigned robjs = 0;
    lg_group rt[LG_GROUPS], sm[LG_GROUPS]; int nrt = 0, nsm = 0;
    uint64_t rt_n = 0, rt_b = 0, st_n[3] = {0}, st_b[3] = {0}, buf_n = 0, buf_b = 0, heap_n = 0, heap_b = 0, other_n = 0, other_b = 0;   // st: ASTC, BC, other sampled
    pthread_mutex_lock(&g_res_mu); NSArray *live = g_res_objects.allObjects; pthread_mutex_unlock(&g_res_mu);
    for (id a in live) {
        uint64_t sz = ((id<MTLAllocation>)a).allocatedSize; rb += sz; robjs++;
        if ([a conformsToProtocol:@protocol(MTLTexture)]) { id<MTLTexture> t = a; if (t.parentTexture) continue;
            uint32_t f = (uint32_t)t.pixelFormat;
            if (t.usage & MTLTextureUsageRenderTarget) { rt_n++; rt_b += sz; lg_add(rt, &nrt, (uint64_t)MIN(t.width, 65535u) << 48 | (uint64_t)MIN(t.height, 65535u) << 32 | (uint64_t)MIN(t.arrayLength * t.depth, 255u) << 24 | (uint64_t)MIN(t.sampleCount, 255u) << 16 | (f & 0xffff), sz); }
            else { int c = f >= 186 && f <= 225 ? 0 : f >= 130 && f <= 153 ? 1 : 2; st_n[c]++; st_b[c] += sz; lg_add(sm, &nsm, f, sz); } }
        else if ([a conformsToProtocol:@protocol(MTLBuffer)]) { buf_n++; buf_b += sz; }
        else if ([a conformsToProtocol:@protocol(MTLHeap)]) { heap_n++; heap_b += sz; }
        else { other_n++; other_b += sz; }
    }
    uint64_t pool_n = 0, pool_b = 0, poolres_n = 0, poolres_b = 0, dead_n = 0, dead_b = 0;
    @autoreleasepool { pthread_mutex_lock(&g_mu);
        for (int i = 0; i < g_npool; i++) { uint64_t n = g_pools[i].hi - g_pools[i].lo; pool_n++; pool_b += n; if (g_pools[i].res && g_pools[i].buf) { poolres_n++; poolres_b += g_pools[i].buf.length; } }
        for (id<MTLBuffer> b in g_dead_pools) { dead_n++; dead_b += b.length; }
        pthread_mutex_unlock(&g_mu); }
    os_unfair_lock_lock(&g_rh_lk); unsigned rh_n = g_rh_n; uint64_t rh_b = g_rh_bytes; os_unfair_lock_unlock(&g_rh_lk);
    uint64_t up_b = 0, up_n = 0; for (unsigned s = 0; s < 3; s++) { if (g_up_slot_blk[s]) { up_b += g_up_slot_blk[s].length; up_n++; } if (g_up_slot_over[s]) { up_b += g_up_slot_over[s].length; up_n++; } }
    char avail[32] = "n/a";
#if TARGET_OS_IPHONE
    snprintf(avail, sizeof avail, "%llu MB", (unsigned long long)(os_proc_available_memory() >> 20));
#endif
    uint64_t secs = (clock_gettime_nsec_np(CLOCK_MONOTONIC) - g_lg_t0) / 1000000000ull;
    MLOG("[ledger] +%llus frame %llu: GPU allocated %.0f MB (recommended working set %.0f MB; process headroom %s); in the residency set %u objects, %.0f MB; allocated but not in it %.0f MB",
         (unsigned long long)secs, (unsigned long long)atomic_load(&g_cur_frame), total / M, g_dev.recommendedMaxWorkingSetSize / M, avail, robjs, rb / M, total > rb ? (total - rb) / M : 0.0);
    MLOG("[ledger]   render targets %llu textures, %.0f MB; sampled textures %llu, %.0f MB (ASTC %llu / %.0f MB, BC %llu / %.0f MB, other %llu / %.0f MB)",
         (unsigned long long)rt_n, rt_b / M, (unsigned long long)(st_n[0] + st_n[1] + st_n[2]), (st_b[0] + st_b[1] + st_b[2]) / M, (unsigned long long)st_n[0], st_b[0] / M, (unsigned long long)st_n[1], st_b[1] / M, (unsigned long long)st_n[2], st_b[2] / M);
    MLOG("[ledger]   buffers in the set %llu, %.0f MB (of them resident pool buffers %llu, %.0f MB); heaps %llu, %.0f MB; other objects %llu, %.0f MB",
         (unsigned long long)buf_n, buf_b / M, (unsigned long long)poolres_n, poolres_b / M, (unsigned long long)heap_n, heap_b / M, (unsigned long long)other_n, other_b / M);
    MLOG("[ledger]   memory pools registered %llu, %.0f MB (resident %llu, %.0f MB); pool buffers freed but alive %llu, %.0f MB; recycled heaps waiting (RH) %u, %.0f MB; upload staging kept %llu blocks, %.0f MB",
         (unsigned long long)pool_n, pool_b / M, (unsigned long long)poolres_n, poolres_b / M, (unsigned long long)dead_n, dead_b / M, rh_n, rh_b / M, (unsigned long long)up_n, up_b / M);
    qsort(rt, nrt, sizeof rt[0], lg_cmp); qsort(sm, nsm, sizeof sm[0], lg_cmp);
    for (int i = 0; i < nrt && i < 8; i++) { char fb[16]; uint64_t k = rt[i].key;
        MLOG("[ledger]   render targets %llux%llu x%llu %s%s: %u, %.0f MB", (unsigned long long)(k >> 48), (unsigned long long)(k >> 32 & 0xffff), (unsigned long long)(k >> 24 & 0xff), lg_fmt((uint32_t)(k & 0xffff), fb, sizeof fb), (k >> 16 & 0xff) > 1 ? " (multisampled)" : "", rt[i].n, rt[i].bytes / M); }
    for (int i = 0; i < nsm && i < 6; i++) { char fb[16]; MLOG("[ledger]   sampled textures %s: %u, %.0f MB", lg_fmt((uint32_t)sm[i].key, fb, sizeof fb), sm[i].n, sm[i].bytes / M); }
    {   // macbench (measurement only): the residency set's buffers that are not memory pools, and its heaps, by power-of-two size class; the host's own fixed consumers by count
        uintptr_t *pb; int npb = 0;
        pthread_mutex_lock(&g_mu); pb = malloc(sizeof *pb * (size_t)(g_npool + 1));
        for (int i = 0; i < g_npool; i++) if (g_pools[i].buf) pb[npb++] = (uintptr_t)(__bridge void *)g_pools[i].buf;
        pthread_mutex_unlock(&g_mu);
        qsort(pb, (size_t)npb, sizeof *pb, lg_ucmp);
        uint64_t bn[48] = {0}, bb[48] = {0}, hn[48] = {0}, hb[48] = {0};
        for (id a in live) {
            int isb = [a conformsToProtocol:@protocol(MTLBuffer)], ish = !isb && [a conformsToProtocol:@protocol(MTLHeap)];
            if (!isb && !ish) continue;
            uintptr_t p = (uintptr_t)(__bridge void *)a;
            if (isb && bsearch(&p, pb, (size_t)npb, sizeof *pb, lg_ucmp)) continue;
            uint64_t sz = ((id<MTLAllocation>)a).allocatedSize; int k = sz ? 63 - __builtin_clzll(sz) : 0; if (k > 47) k = 47;
            if (isb) { bn[k]++; bb[k] += sz; } else { hn[k]++; hb[k] += sz; }
        }
        free(pb);
        for (int w = 0; w < 2; w++) { char line[1400]; int o = 0; line[0] = 0; uint64_t *n = w ? hn : bn, *b = w ? hb : bb;
            for (int k = 47; k >= 0 && o < 1300; k--) if (n[k]) o += snprintf(line + o, sizeof line - o, " >=%llu %s: %llu, %.1f MB;", (unsigned long long)(k >= 20 ? 1ull << (k - 20) : k >= 10 ? 1ull << (k - 10) : 0), k >= 20 ? "MB" : "KB", (unsigned long long)n[k], b[k] / M);
            MLOG("[ledger]   macbench %s by size:%s", w ? "heaps in the set" : "non-pool buffers in the set", line); }
        MLOG("[ledger]   macbench: c1 banks %lu x %u MB, per-frame arenas %lu, sparse tile heaps %lu, uniform shadow buffer %.0f MB, upload block %.0f MB",
             (unsigned long)g_c1_banks.count, C1_BANK_SIZE >> 20, (unsigned long)g_arenas.count, (unsigned long)g_sp_heaps.count, g_ubs_size / M, g_up_block_size / M);
    }
} }
static void *lg_thread(void *arg) {
    double sec = *(double *)arg; pthread_setname_np("dm-ledger");
    for (;;) { usleep((useconds_t)(sec * 1e6)); lg_dump(); }
    return NULL;
}
// Started by the first call (the frame hook's memory readout); DM_NVN_LEDGER=<seconds>, nothing when unset or 0
static void ledger_poke(void) {
    static dispatch_once_t once; static double sec;
    dispatch_once(&once, ^{ const char *e = getenv("DM_NVN_LEDGER"); sec = e && *e ? atof(e) : 0;
        if (sec < 1) return;
        g_lg_t0 = clock_gettime_nsec_np(CLOCK_MONOTONIC); pthread_t t; pthread_attr_t at; pthread_attr_init(&at); pthread_attr_setdetachstate(&at, PTHREAD_CREATE_DETACHED);
        if (pthread_create(&t, &at, lg_thread, &sec)) MLOG("[ledger] thread not started"); else MLOG("[ledger] every %.0f s (DM_NVN_LEDGER)", sec); });
}
