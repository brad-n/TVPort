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
static int lg_cmp(const void *a, const void *b) { const lg_group *x = a, *y = b; return x->bytes < y->bytes ? 1 : x->bytes > y->bytes ? -1 : 0; }
static uint64_t g_lg_t0;
typedef struct { uintptr_t a, b; } lg_rng;   // a resident pool buffer's memory (lg_dump: distinct memory)
static int lg_rng_cmp(const void *x, const void *y) { uintptr_t a = ((const lg_rng *)x)->a, b = ((const lg_rng *)y)->a; return a < b ? -1 : a > b; }
// A shared texture's memory: its heap's, once per heap (an image family's descriptions share one), none for a view or a texture over a buffer (res_size), else its own allocation
static uint64_t lg_tex_bytes(id o, CFMutableSetRef heaps) {
    if (![o conformsToProtocol:@protocol(MTLTexture)]) return 0;
    id<MTLTexture> t = o; id<MTLHeap> h = t.heap;
    if (h) { if (CFSetContainsValue(heaps, (__bridge const void *)h)) return 0; CFSetAddValue(heaps, (__bridge const void *)h); return h.allocatedSize; }
    return res_size(o);
}
// How long an entry of the sharing table has gone without a lookup (g_alias_seen): 0 within ALIAS_IDLE submissions, 1 under a second, 2 under 10 s, 3 longer (or older than the ring)
static int lg_idle_class(uint64_t seen, uint64_t fence, uint64_t now) {
    if (seen && fence + 1 - seen < ALIAS_IDLE) return 0;
    if (!seen || fence + 1 - seen >= FENCE_NS) return 3;
    uint64_t t = g_fence_ns[seen % FENCE_NS], age = now > t ? now - t : 0;
    return age < 1000000000ull ? 1 : age < 10000000000ull ? 2 : 3;
}
// The sharing table (g_alias) by who keeps each texture: a live texture object (g_by_serial), a finalized one a replayed record still resolves (g_ghost), a pin, or nothing (unreferenced:
// kept only until its storage is taken over, its pool goes, or alias_sweep), the unreferenced by how long since a lookup found them; and the deferred-release queue's memory
static void lg_shared(void) { @autoreleasepool {
    const double M = 1048576.0;
    uint64_t n[4] = {0}, b[4] = {0}, in[4] = {0}, ib[4] = {0}; lg_group og[LG_GROUPS]; int nog = 0;   // n/b: held, ghost, pinned, unreferenced; in/ib: the unreferenced by lg_idle_class
    uint64_t now = clock_gettime_nsec_np(CLOCK_MONOTONIC), fence = atomic_load(&g_fence);
    CFMutableSetRef heaps = CFSetCreateMutable(NULL, 0, NULL);
    pthread_mutex_lock(&g_smu);
    for (uint32_t i = 0; i < g_alias.cap; i++) {
        void *v = g_alias.vals[i]; if (!v) continue;
        id o = (__bridge id)v; alias_key k; memcpy(&k, g_alias.keys + (size_t)i * g_alias.klen, sizeof k);
        uint64_t z = lg_tex_bytes(o, heaps); uintptr_t a = (uintptr_t)v;
        int st = serial_table_holds(v) ? 0 : g_ghost_held.n && nvn_hm_get(&g_ghost_held, &a) ? 1 : tex_object_pinned(o) ? 2 : 3;
        n[st]++; b[st] += z;
        if (st != 3) continue;
        int c = lg_idle_class((uint64_t)(uintptr_t)nvn_hm_get(&g_alias_seen, &k), fence, now); in[c]++; ib[c] += z;
        if ([o conformsToProtocol:@protocol(MTLTexture)]) { id<MTLTexture> t = o;
            lg_add(og, &nog, (uint64_t)MIN(t.width, 65535u) << 48 | (uint64_t)MIN(t.height, 65535u) << 32 | (uint64_t)MIN(t.arrayLength * t.depth, 255u) << 24 | ((uint32_t)t.pixelFormat & 0xffff), z); }
    }
    uint64_t swept_n = g_alias_swept, swept_b = g_alias_swept_b, taken = g_alias_taken;
    pthread_mutex_unlock(&g_smu);
    CFSetRemoveAllValues(heaps);
    uint64_t dq_n = 0, dq_b = 0, dr_n = 0;
    pthread_mutex_lock(&g_deferred_mu);
    for (NvDeferredRelease *d in g_deferred) { id o = d->object; if (!o) continue;
        if (d->keep_resident) { dr_n++; continue; }
        dq_n++; dq_b += [o conformsToProtocol:@protocol(MTLTexture)] ? lg_tex_bytes(o, heaps) : [o conformsToProtocol:@protocol(MTLAllocation)] ? ((id<MTLAllocation>)o).allocatedSize : 0; }
    pthread_mutex_unlock(&g_deferred_mu);
    CFRelease(heaps);
    MLOG("[ledger]   shared textures %llu, %.0f MB: held by live textures %llu, %.0f MB; by finalized ones (ghost ring) %llu, %.0f MB; pinned %llu, %.0f MB; unreferenced %llu, %.0f MB (looked up within %d submissions %llu, %.0f MB; under 1 s ago %llu, %.0f MB; 1-10 s %llu, %.0f MB; longer %llu, %.0f MB); taken over %llu, swept %llu (%.0f MB) so far",
         (unsigned long long)(n[0] + n[1] + n[2] + n[3]), (b[0] + b[1] + b[2] + b[3]) / M, (unsigned long long)n[0], b[0] / M, (unsigned long long)n[1], b[1] / M, (unsigned long long)n[2], b[2] / M, (unsigned long long)n[3], b[3] / M,
         ALIAS_IDLE, (unsigned long long)in[0], ib[0] / M, (unsigned long long)in[1], ib[1] / M, (unsigned long long)in[2], ib[2] / M, (unsigned long long)in[3], ib[3] / M, (unsigned long long)taken, (unsigned long long)swept_n, swept_b / M);
    qsort(og, nog, sizeof og[0], lg_cmp);
    for (int i = 0; i < nog && i < 5; i++) { char fb[16]; uint64_t k = og[i].key;
        MLOG("[ledger]   unreferenced shared textures %llux%llu x%llu %s: %u, %.0f MB", (unsigned long long)(k >> 48), (unsigned long long)(k >> 32 & 0xffff), (unsigned long long)(k >> 24 & 0xff), lg_fmt((uint32_t)(k & 0xffff), fb, sizeof fb), og[i].n, og[i].bytes / M); }
    MLOG("[ledger]   deferred-release queue: %llu objects to free, %.0f MB; %llu references to drop", (unsigned long long)dq_n, dq_b / M, (unsigned long long)dr_n);
} }
static void lg_dump(void) { @autoreleasepool {
    const double M = 1048576.0;
    uint64_t total = g_dev.currentAllocatedSize, rb = 0; unsigned robjs = 0;
    lg_group rt[LG_GROUPS], sm[LG_GROUPS]; int nrt = 0, nsm = 0;
    uint64_t rt_n = 0, rt_b = 0, st_n[3] = {0}, st_b[3] = {0}, buf_n = 0, buf_b = 0, heap_n = 0, heap_b = 0, other_n = 0, other_b = 0;   // st: ASTC, BC, other sampled
    uint64_t ob_n = 0, ob_b = 0, hk_n[4] = {0}, hk_b[4] = {0};   // ob: textures over buffers and the memory of those buffers the set does not hold (once each); hk: heaps by label (dm.rt, dm.image, dm.sparse, other)
    pthread_mutex_lock(&g_res_mu); NSArray *live = g_res_objects.allObjects; pthread_mutex_unlock(&g_res_mu);
    CFMutableSetRef inset = CFSetCreateMutable(NULL, 0, NULL), obufs = CFSetCreateMutable(NULL, 0, NULL);
    for (id a in live) CFSetAddValue(inset, (__bridge const void *)a);
    for (id a in live) {
        robjs++;
        if ([a conformsToProtocol:@protocol(MTLTexture)] && (((id<MTLTexture>)a).buffer || ((id<MTLTexture>)a).parentTexture)) {   // its memory is its buffer's or parent's (res_size): the 8 MB "UI text targets"
            id<MTLBuffer> ub = ((id<MTLTexture>)a).buffer; if (!ub) continue;
            ob_n++;
            if (!CFSetContainsValue(inset, (__bridge const void *)ub) && !CFSetContainsValue(obufs, (__bridge const void *)ub)) { CFSetAddValue(obufs, (__bridge const void *)ub); ob_b += ub.allocatedSize; rb += ub.allocatedSize; }
            continue; }
        uint64_t sz = ((id<MTLAllocation>)a).allocatedSize; rb += sz;
        if ([a conformsToProtocol:@protocol(MTLTexture)]) { id<MTLTexture> t = a;
            uint32_t f = (uint32_t)t.pixelFormat;
            if (t.usage & MTLTextureUsageRenderTarget) { rt_n++; rt_b += sz; lg_add(rt, &nrt, (uint64_t)MIN(t.width, 65535u) << 48 | (uint64_t)MIN(t.height, 65535u) << 32 | (uint64_t)MIN(t.arrayLength * t.depth, 255u) << 24 | (uint64_t)MIN(t.sampleCount, 255u) << 16 | (f & 0xffff), sz); }
            else { int c = f >= 186 && f <= 225 ? 0 : f >= 130 && f <= 153 ? 1 : 2; st_n[c]++; st_b[c] += sz; lg_add(sm, &nsm, f, sz); } }
        else if ([a conformsToProtocol:@protocol(MTLBuffer)]) { buf_n++; buf_b += sz; }
        else if ([a conformsToProtocol:@protocol(MTLHeap)]) { heap_n++; heap_b += sz; NSString *l = ((id<MTLHeap>)a).label;
            int k = [l isEqualToString:@"dm.rt"] ? 0 : [l isEqualToString:@"dm.image"] ? 1 : [l isEqualToString:@"dm.sparse"] ? 2 : 3; hk_n[k]++; hk_b[k] += sz; }
        else { other_n++; other_b += sz; }
    }
    CFRelease(inset); CFRelease(obufs);
    // The chunks of a large pool overlap (BIG_MIN), and a replaced chunk stays in the set beside the longer one (g_old_res): the resident pool buffers' lengths count shared pages more than once,
    // and the residency budget counts those lengths. distinct_b is the memory they cover
    uint64_t pool_n = 0, pool_b = 0, poolres_n = 0, poolres_b = 0, dead_n = 0, dead_b = 0, oldres_n = 0, oldres_b = 0, distinct_b = 0, pin_n = 0, pin_b = 0, pin_big = 0, pin_old = 0;   // pin: textures made on the buffer (pool_pin_buf); pin_big: chunks of a large pool among them
    @autoreleasepool { pthread_mutex_lock(&g_mu);
        lg_rng *rr = malloc((size_t)(g_npool + g_n_old_res + 1) * sizeof *rr); int nr = 0;
        for (int i = 0; i < g_npool; i++) { uint64_t n = g_pools[i].hi - g_pools[i].lo; pool_n++; pool_b += n; if (g_pools[i].res && g_pools[i].buf) { uint64_t l = g_pools[i].buf.length; poolres_n++; poolres_b += l; if (rr) rr[nr++] = (lg_rng){g_pools[i].base, g_pools[i].base + l}; }
            if (g_pools[i].pin) { pin_n++; pin_b += g_pools[i].buf.length; pin_big += g_pools[i].unk != 1 || g_pools[i].end != g_pools[i].hi; } }
        for (int k = 0; k < g_n_old_res; k++) { id<MTLBuffer> b = g_old_res[k].buf; uintptr_t a = (uintptr_t)b.contents; oldres_n++; oldres_b += b.length; pin_old += g_old_res[k].pin != 0; if (rr) rr[nr++] = (lg_rng){a, a + b.length}; }
        for (id<MTLBuffer> b in g_dead_pools) { dead_n++; dead_b += b.length; }
        pthread_mutex_unlock(&g_mu);
        if (rr) { qsort(rr, (size_t)nr, sizeof *rr, lg_rng_cmp); uintptr_t end = 0; for (int i = 0; i < nr; i++) { uintptr_t a = rr[i].a > end ? rr[i].a : end; if (rr[i].b > a) distinct_b += rr[i].b - a; if (rr[i].b > end) end = rr[i].b; } free(rr); } }
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
    MLOG("[ledger]   buffers in the set %llu, %.0f MB (of them resident pool buffers %llu, %.0f MB, and replaced chunks %llu, %.0f MB: %.0f MB of distinct memory); heaps %llu, %.0f MB; other objects %llu, %.0f MB",
         (unsigned long long)buf_n, buf_b / M, (unsigned long long)poolres_n, poolres_b / M, (unsigned long long)oldres_n, oldres_b / M, distinct_b / M, (unsigned long long)heap_n, heap_b / M, (unsigned long long)other_n, other_b / M);
    MLOG("[ledger]   heaps by kind: recycled render targets %llu, %.0f MB; image families %llu, %.0f MB; sparse tiles %llu, %.0f MB; other %llu, %.0f MB; textures over buffers %llu (their memory is the buffers'; buffers outside the set %.0f MB)",
         (unsigned long long)hk_n[0], hk_b[0] / M, (unsigned long long)hk_n[1], hk_b[1] / M, (unsigned long long)hk_n[2], hk_b[2] / M, (unsigned long long)hk_n[3], hk_b[3] / M, (unsigned long long)ob_n, ob_b / M);
    MLOG("[ledger]   memory pools registered %llu, %.0f MB (resident %llu, %.0f MB; pinned by a texture made on the buffer %llu, %.0f MB, of them large-pool chunks %llu, and replaced chunks %llu); pool buffers freed but alive %llu, %.0f MB; recycled heaps waiting (RH) %u, %.0f MB; upload staging kept %llu blocks, %.0f MB",
         (unsigned long long)pool_n, pool_b / M, (unsigned long long)poolres_n, poolres_b / M, (unsigned long long)pin_n, pin_b / M, (unsigned long long)pin_big, (unsigned long long)pin_old, (unsigned long long)dead_n, dead_b / M, rh_n, rh_b / M, (unsigned long long)up_n, up_b / M);
    qsort(rt, nrt, sizeof rt[0], lg_cmp); qsort(sm, nsm, sizeof sm[0], lg_cmp);
    for (int i = 0; i < nrt && i < 8; i++) { char fb[16]; uint64_t k = rt[i].key;
        MLOG("[ledger]   render targets %llux%llu x%llu %s%s: %u, %.0f MB", (unsigned long long)(k >> 48), (unsigned long long)(k >> 32 & 0xffff), (unsigned long long)(k >> 24 & 0xff), lg_fmt((uint32_t)(k & 0xffff), fb, sizeof fb), (k >> 16 & 0xff) > 1 ? " (multisampled)" : "", rt[i].n, rt[i].bytes / M); }
    for (int i = 0; i < nsm && i < 6; i++) { char fb[16]; MLOG("[ledger]   sampled textures %s: %u, %.0f MB", lg_fmt((uint32_t)sm[i].key, fb, sizeof fb), sm[i].n, sm[i].bytes / M); }
    lg_shared();
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
