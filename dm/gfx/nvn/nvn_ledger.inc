#include <malloc/malloc.h>   // malloc_zone_statistics (the host malloc line)
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
    case 10: return "R8"; case 20: return "R16"; case 25: return "R16F"; case 30: return "RG8"; case 53: return "R32U"; case 55: return "R32F"; case 60: return "RG16"; case 65: return "RG16F";
    case 70: return "RGBA8"; case 71: return "RGBA8s"; case 72: return "RGBA8sn"; case 80: return "BGRA8"; case 81: return "BGRA8s"; case 90: return "RGB10A2"; case 92: return "RG11B10F"; case 93: return "RGB9E5";
    case 105: return "RG32F"; case 110: return "RGBA16"; case 115: return "RGBA16F"; case 123: return "RGBA32U"; case 124: return "RGBA32I"; case 125: return "RGBA32F";
    case 250: return "D16"; case 252: return "D32F"; case 253: return "S8"; case 260: return "D32FS8";
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
    if (rr_mode() == 2) MLOG("[ledger]   render targets dead by overwrite (DM_NVN_RT_RETIRE=log, kept): %llu, %.0f MB would go now; %llu storages, %.0f MB, counted so far",
                             (unsigned long long)g_rr_log_now_n, g_rr_log_now_b / M, (unsigned long long)g_rr_log_n, g_rr_log_b / M);
    else MLOG("[ledger]   render targets dead by overwrite (DM_NVN_RT_RETIRE): retired %llu, %.0f MB so far (of them whole resolution families %llu, %.0f MB), %llu made again; dead but kept at the last scan: inside the hold %llu, %.0f MB; "
              "bound through a texture ID within %d submissions %llu, %.0f MB; a serial's view %llu, %.0f MB; pinned %llu, %.0f MB; a finalized object's (ghost ring) %llu, %.0f MB; a resolution family with a member that stays %llu, %.0f MB",
              (unsigned long long)g_rr_n, g_rr_b / M, (unsigned long long)g_rr_fam_n, g_rr_fam_b / M, (unsigned long long)g_rr_again, (unsigned long long)g_rr_kept_n[RRK_HOLD], g_rr_kept_b[RRK_HOLD] / M,
              RR_IDLE, (unsigned long long)g_rr_kept_n[RRK_BOUND], g_rr_kept_b[RRK_BOUND] / M, (unsigned long long)g_rr_kept_n[RRK_VIEW], g_rr_kept_b[RRK_VIEW] / M, (unsigned long long)g_rr_kept_n[RRK_PIN], g_rr_kept_b[RRK_PIN] / M,
              (unsigned long long)g_rr_kept_n[RRK_GHOST], g_rr_kept_b[RRK_GHOST] / M, (unsigned long long)g_rr_kept_n[RRK_FAMILY], g_rr_kept_b[RRK_FAMILY] / M);
} }
// The recycled render-target heaps (dm.rt) and the image families (dm.image) of the residency set by what keeps each (lg_heaps): the `heaps by kind` line gives their total, and the
// `render targets` line counts only textures the set holds themselves, which a texture placed in a heap is not (res_add puts its heap there). A dm.rt heap stays in the set while the
// texture placed in it lives (NvRecycledHeap: its texture's associated object) or while it waits for the next target (RH); a dm.image heap while any of its family's textures lives
// (NvImageHeap). So each heap is named by the strongest holder of a texture placed in it, in this order: the waiting list; the sharing table, by who holds the shared texture (a live
// texture object, by how long since its last use: the lookup g_alias_seen, a direct use g_rr_use, a binding of one of its serial's texture IDs; a finalized object in the ghost ring;
// a pin; nobody); a serial entry's own texture or view (not or no longer shared); a retired texture waiting for the serial entries that hold it (g_retire_held); the cached views
// (of texture IDs, by texture object g_vc, by Metal texture g_vb), each holding its parent; the deferred-release queue (still to free, or a reference to drop). A heap none of these
// reaches is kept by something the host's tables do not show (a command buffer or an autorelease pool still holding its texture, or a leak). Of the live ones, those whose storage
// passes into other textures have reached since their last use (rt_retire's write map: dead by overwrite, kept by its idle rules or a view) and those over storage a retired texture
// had (made again) are counted. Takes g_rmu, then g_smu, as rt_retire does: a few milliseconds every DM_NVN_LEDGER seconds
enum { LH_WAIT, LH_LIVE0, LH_LIVE1, LH_LIVE2, LH_LIVE3, LH_GHOST, LH_PIN, LH_UNREF, LH_SERIAL, LH_RETIRE, LH_IDVIEW, LH_VC, LH_VB, LH_DEFER, LH_DEFREF, LH_ELSE, LH_N, LH_NONE = 0xff };
typedef struct { uint64_t size, tex; uint8_t kind, holder, lossy, dead, again, live; uint16_t members; } lh_ent;   // tex: the largest texture placed in it; dead: every live member drawn over
typedef struct { nvn_hmap hm; lh_ent *e; uint32_t n; } lh_set;
static lh_ent *lh_find(lh_set *s, id o, id<MTLTexture> *base) {   // the entry of the heap o (a texture or a view of one) is placed in, or NULL
    if (!o || ![o conformsToProtocol:@protocol(MTLTexture)]) return NULL;
    id<MTLTexture> t = o; while (t.parentTexture) t = t.parentTexture;
    id<MTLHeap> h = t.heap; if (!h) return NULL;
    uintptr_t k = (uintptr_t)(__bridge void *)h, j = (uintptr_t)nvn_hm_get(&s->hm, &k);
    if (!j) return NULL;
    if (base) *base = t;
    return &s->e[j - 1];
}
static void lh_mark(lh_set *s, id o, int holder) {
    id<MTLTexture> t = nil; lh_ent *x = lh_find(s, o, &t); if (!x) return;
    if (holder < x->holder) { x->holder = (uint8_t)holder; x->lossy = t.compressionType == MTLTextureCompressionTypeLossy; }
    uint64_t z = t.allocatedSize; if (z > x->tex) x->tex = z;
}
typedef struct { uint64_t n[2][LH_N], b[2][LH_N], dn[2], db[2], an[2], ab[2], ln[2], lb[2], tb[2], sb[2], mem[2], multi[2]; } lh_tot;   // [0] dm.rt, [1] dm.image
static void lh_tally(NSArray *live, lh_tot *T) { @autoreleasepool {
    memset(T, 0, sizeof *T);
    lh_set s = {.hm = {.klen = sizeof(uintptr_t)}};
    for (id a in live) {
        if (![a conformsToProtocol:@protocol(MTLHeap)]) continue;
        NSString *l = ((id<MTLHeap>)a).label; int kind = [l isEqualToString:@"dm.rt"] ? 0 : [l isEqualToString:@"dm.image"] ? 1 : -1;
        if (kind < 0) continue;
        s.e = realloc_or_die(s.e, (s.n + 1) * sizeof *s.e, "the ledger's heaps");
        s.e[s.n] = (lh_ent){.size = ((id<MTLHeap>)a).size, .kind = (uint8_t)kind, .holder = LH_NONE};
        uintptr_t k = (uintptr_t)(__bridge void *)a; nvn_hm_put(&s.hm, &k, (void *)(uintptr_t)(++s.n));
    }
    if (!s.n) { free(s.hm.keys); free(s.hm.vals); return; }
    os_unfair_lock_lock(&g_rh_lk);
    for (unsigned i = 0; i < g_rh_n; i++) { uintptr_t k = (uintptr_t)g_rh[i].heap, j = (uintptr_t)nvn_hm_get(&s.hm, &k); if (j) s.e[j - 1].holder = LH_WAIT; }
    os_unfair_lock_unlock(&g_rh_lk);
    uint64_t now = clock_gettime_nsec_np(CLOCK_MONOTONIC), fence = atomic_load(&g_fence);
    os_unfair_lock_lock(&g_rmu); pthread_mutex_lock(&g_smu);
    {   // the sharing table: each texture in a heap of the set by who holds it; the live ones' serials, for their texture IDs' last bindings
        typedef struct { void *o; alias_key k; uint64_t lu; } lh_live;
        lh_live *lv = NULL; uint32_t nl = 0, cl = 0; nvn_hmap li = {.klen = sizeof(uintptr_t)};   // live texture → index + 1
        for (uint32_t i = 0; i < g_alias.cap; i++) {
            void *v = g_alias.vals[i]; if (!v) continue;
            id o = (__bridge id)v; if (!lh_find(&s, o, NULL)) continue;
            uintptr_t a = (uintptr_t)v; alias_key k; memcpy(&k, g_alias.keys + (size_t)i * g_alias.klen, sizeof k);
            if (!serial_table_holds(v)) { lh_mark(&s, o, g_ghost_held.n && nvn_hm_get(&g_ghost_held, &a) ? LH_GHOST : tex_object_pinned(o) ? LH_PIN : LH_UNREF); continue; }
            uint64_t lu = (uint64_t)(uintptr_t)nvn_hm_get(&g_alias_seen, &k);
            os_unfair_lock_lock(&g_rr_use_lk); lu = MAX(lu, (uint64_t)(uintptr_t)nvn_hm_get(&g_rr_use, &a)); os_unfair_lock_unlock(&g_rr_use_lk);
            if (nl == cl) { cl = cl ? 2 * cl : 256; lv = realloc_or_die(lv, cl * sizeof *lv, "the ledger's heaps"); }
            lv[nl] = (lh_live){v, k, lu}; nvn_hm_put(&li, &a, (void *)(uintptr_t)(++nl));
        }
        for (uint32_t i = 0; nl && i < g_by_serial.cap; i++) {   // the live serials that hold one: their texture IDs' last bindings are uses too
            void *v = g_by_serial.vals[i]; if (!v) continue; uintptr_t a = (uintptr_t)v, j = (uintptr_t)nvn_hm_get(&li, &a); if (!j) continue;
            uint64_t ser; memcpy(&ser, g_by_serial.keys + (size_t)i * 8, 8);
            for (int k = (int)(uintptr_t)nvn_hm_get(&g_treg_serial, &ser); k; k = g_treg[k - 1].next) lv[j - 1].lu = MAX(lv[j - 1].lu, g_treg[k - 1].ufence);
        }
        for (uint32_t j = 0; j < nl; j++) {
            id o = (__bridge id)lv[j].o; int c = lg_idle_class(lv[j].lu, fence, now);
            lh_mark(&s, o, LH_LIVE0 + c);
            lh_ent *x = lh_find(&s, o, NULL); if (!x) continue;
            const pool_t *p = (const pool_t *)(uintptr_t)lv[j].k.pool; nvn_texlayout L; nvn_tex_layout(&lv[j].k.d, &L);
            uint64_t cover = L.size ? wm_min(p, (uint64_t)lv[j].k.off, (uint64_t)lv[j].k.off + L.size) : 0;
            int dead = cover && cover > lv[j].lu;
            x->dead = x->live ? x->dead && dead : dead; x->live = 1; x->members++;
            if (g_rr_hold.n && nvn_hm_get(&g_rr_hold, &lv[j].k)) x->again = 1;
        }
        nvn_hm_clear(&li, NULL); free(li.keys); free(li.vals); free(lv);
    }
    for (uint32_t i = 0; i < g_by_serial.cap; i++) {   // a serial's own entry: a texture or a view not (or no longer) in the sharing table, a packaged texture's
        void *v = g_by_serial.vals[i]; if (!v) continue; id o = (__bridge id)v;
        if ([o isKindOfClass:[NvPkg class]]) { NvPkg *pk = o; lh_mark(&s, pk->tex, LH_SERIAL); lh_mark(&s, pk->spare, LH_SERIAL); lh_mark(&s, pk->view, LH_SERIAL); }
        else lh_mark(&s, o, LH_SERIAL);
    }
    for (uint32_t i = 0; i < g_ghost.cap; i++) { void *v = g_ghost.vals[i]; if (!v) continue; id o = (__bridge id)v;
        if ([o isKindOfClass:[NvPkg class]]) { NvPkg *pk = o; lh_mark(&s, pk->tex, LH_GHOST); lh_mark(&s, pk->view, LH_GHOST); } else lh_mark(&s, o, LH_GHOST); }
    for (uint32_t i = 0; i < g_tex_pins.cap; i++) { tex_pin *pin = g_tex_pins.vals[i]; if (pin && pin->object) lh_mark(&s, (__bridge id)pin->object, LH_PIN); }
    for (uint32_t i = 0; i < g_retire_held.cap; i++) { void *v = g_retire_held.vals[i]; if (v) lh_mark(&s, (__bridge id)v, LH_RETIRE); }
    pthread_mutex_unlock(&g_smu); os_unfair_lock_unlock(&g_rmu);
    for (int c = 0;; c += 2048) {   // the texture IDs' cached views and stand-ins, under g_rmu a few thousand IDs at a time (the replay takes it at every binding)
        os_unfair_lock_lock(&g_rmu); int end = MIN(c + 2048, g_ntreg);
        for (int i = c; i < end; i++) { treg_t *r = &g_treg[i]; if (!r->ok) continue;
            if (r->view) lh_mark(&s, (__bridge id)r->view, LH_IDVIEW);
            if (r->alt) lh_mark(&s, (__bridge id)r->alt, LH_IDVIEW);
            if (r->im) lh_mark(&s, (__bridge id)r->im, LH_IDVIEW);
            if (r->stand) lh_mark(&s, (__bridge id)r->stand, LH_IDVIEW); }
        os_unfair_lock_unlock(&g_rmu);
        if (end < c + 2048) break;
    }
    os_unfair_lock_lock(&g_rmu);
    for (uint32_t i = 0; i < g_vc.cap; i++) { vc_set *vs = g_vc.vals[i]; if (!vs) continue; for (int w = 0; w < VC_WAYS; w++) if (vs->view[w]) lh_mark(&s, (__bridge id)vs->view[w], LH_VC); }
    os_unfair_lock_lock(&g_vb_lk);
    for (uint32_t i = 0; i < g_vb.cap; i++) { vb_set *vs = g_vb.vals[i]; if (!vs) continue; for (int w = 0; w < VC_WAYS; w++) if (vs->view[w]) lh_mark(&s, (__bridge id)vs->view[w], LH_VB); }
    os_unfair_lock_unlock(&g_vb_lk);
    os_unfair_lock_unlock(&g_rmu);
    pthread_mutex_lock(&g_deferred_mu);
    for (NvDeferredRelease *d in g_deferred) if (d->object) lh_mark(&s, d->object, d->keep_resident ? LH_DEFREF : LH_DEFER);
    pthread_mutex_unlock(&g_deferred_mu);
    for (uint32_t i = 0; i < s.n; i++) { lh_ent *x = &s.e[i]; int k = x->kind, h = x->holder == LH_NONE ? LH_ELSE : x->holder;
        T->n[k][h]++; T->b[k][h] += x->size; T->sb[k] += x->size; T->tb[k] += x->tex;
        if (h >= LH_LIVE0 && h <= LH_LIVE3) { if (x->dead) { T->dn[k]++; T->db[k] += x->size; } if (x->again) { T->an[k]++; T->ab[k] += x->size; } }
        if (x->lossy) { T->ln[k]++; T->lb[k] += x->size; }
        T->mem[k] += x->members; T->multi[k] += x->members > 1; }
    free(s.e); free(s.hm.keys); free(s.hm.vals);
} }
static void lg_heaps(NSArray *live) {
    const double M = 1048576.0; lh_tot T; lh_tally(live, &T);
    uint64_t (*hn)[LH_N] = T.n, (*hb)[LH_N] = T.b, *dn = T.dn, *db = T.db, *an = T.an, *ab = T.ab, *ln = T.ln, *lb = T.lb, *tb = T.tb, *sb = T.sb, *mem = T.mem, *multi = T.multi;
    static const char *kn[2] = {"recycled render-target heaps", "image families"};
    for (int k = 0; k < 2; k++) {
        if (!(hn[k][LH_WAIT] + hn[k][LH_LIVE0] + hn[k][LH_LIVE1] + hn[k][LH_LIVE2] + hn[k][LH_LIVE3] + hn[k][LH_GHOST] + hn[k][LH_PIN] + hn[k][LH_UNREF] + hn[k][LH_SERIAL] + hn[k][LH_RETIRE]
              + hn[k][LH_IDVIEW] + hn[k][LH_VC] + hn[k][LH_VB] + hn[k][LH_DEFER] + hn[k][LH_DEFREF] + hn[k][LH_ELSE])) continue;
        uint64_t liven = hn[k][LH_LIVE0] + hn[k][LH_LIVE1] + hn[k][LH_LIVE2] + hn[k][LH_LIVE3], liveb = hb[k][LH_LIVE0] + hb[k][LH_LIVE1] + hb[k][LH_LIVE2] + hb[k][LH_LIVE3];
        MLOG("[ledger]   %s by holder: waiting (RH) %llu, %.0f MB; a live texture object's shared texture %llu, %.0f MB (used within %d submissions %llu, %.0f MB; under 1 s ago %llu, %.0f MB; 1-10 s %llu, %.0f MB; longer %llu, %.0f MB; of them drawn over by other textures since their last use %llu, %.0f MB, and over storage a retired target had %llu, %.0f MB); "
             "a finalized one's (ghost ring) %llu, %.0f MB; pinned %llu, %.0f MB; unreferenced shared %llu, %.0f MB; a serial's own texture or view %llu, %.0f MB; retired, waiting for the serial entries holding it %llu, %.0f MB; "
             "cached views: of texture IDs %llu, %.0f MB, by texture object %llu, %.0f MB, by Metal texture %llu, %.0f MB; deferred-release queue: to free %llu, %.0f MB, a reference to drop %llu, %.0f MB; none of these (in flight, an autorelease pool or a leak) %llu, %.0f MB",
             kn[k], (unsigned long long)hn[k][LH_WAIT], hb[k][LH_WAIT] / M, (unsigned long long)liven, liveb / M, ALIAS_IDLE, (unsigned long long)hn[k][LH_LIVE0], hb[k][LH_LIVE0] / M, (unsigned long long)hn[k][LH_LIVE1], hb[k][LH_LIVE1] / M,
             (unsigned long long)hn[k][LH_LIVE2], hb[k][LH_LIVE2] / M, (unsigned long long)hn[k][LH_LIVE3], hb[k][LH_LIVE3] / M, (unsigned long long)dn[k], db[k] / M, (unsigned long long)an[k], ab[k] / M,
             (unsigned long long)hn[k][LH_GHOST], hb[k][LH_GHOST] / M, (unsigned long long)hn[k][LH_PIN], hb[k][LH_PIN] / M, (unsigned long long)hn[k][LH_UNREF], hb[k][LH_UNREF] / M, (unsigned long long)hn[k][LH_SERIAL], hb[k][LH_SERIAL] / M,
             (unsigned long long)hn[k][LH_RETIRE], hb[k][LH_RETIRE] / M, (unsigned long long)hn[k][LH_IDVIEW], hb[k][LH_IDVIEW] / M, (unsigned long long)hn[k][LH_VC], hb[k][LH_VC] / M, (unsigned long long)hn[k][LH_VB], hb[k][LH_VB] / M,
             (unsigned long long)hn[k][LH_DEFER], hb[k][LH_DEFER] / M, (unsigned long long)hn[k][LH_DEFREF], hb[k][LH_DEFREF] / M, (unsigned long long)hn[k][LH_ELSE], hb[k][LH_ELSE] / M);
        MLOG("[ledger]   %s: %.0f MB of heaps for %.0f MB of the largest texture placed in each (the rest is size rounding, a reused heap's slack or a family's larger members; waiting heaps hold none); lossy %llu, %.0f MB; %llu live textures in them, %llu heaps holding more than one",
             kn[k], sb[k] / M, tb[k] / M, (unsigned long long)ln[k], lb[k] / M, (unsigned long long)mem[k], (unsigned long long)multi[k]);
    }
}
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
    // A render target placed in a recycled heap or an image family is in the set as its heap (res_add), so this count leaves it out: those are the heaps lines' (heaps by kind, by holder)
    MLOG("[ledger]   render targets %llu textures, %.0f MB, in allocations of their own (those placed in recycled heaps and image families are counted as their heaps, below; render-target memory in all %.0f MB); sampled textures %llu, %.0f MB (ASTC %llu / %.0f MB, BC %llu / %.0f MB, other %llu / %.0f MB)",
         (unsigned long long)rt_n, rt_b / M, (rt_b + hk_b[0] + hk_b[1]) / M, (unsigned long long)(st_n[0] + st_n[1] + st_n[2]), (st_b[0] + st_b[1] + st_b[2]) / M, (unsigned long long)st_n[0], st_b[0] / M, (unsigned long long)st_n[1], st_b[1] / M, (unsigned long long)st_n[2], st_b[2] / M);
    if (rl_mode()) {   // DM_NVN_RT_LOSSY: the lossy targets alive (alone or in recycled heaps), the largest groups, and the decisions so far
        lg_group lg[LG_GROUPS]; int nl = 0; uint64_t ln = 0, lb = 0, ls = 0;
        os_unfair_lock_lock(&g_rl_lk);
        for (id<MTLTexture> t in g_rl_live.keyEnumerator) { uint64_t sz = t.allocatedSize; ln++; lb += sz; ls += [[g_rl_live objectForKey:t] unsignedLongLongValue];
            lg_add(lg, &nl, (uint64_t)MIN(t.width, 65535u) << 48 | (uint64_t)MIN(t.height, 65535u) << 32 | (uint64_t)MIN(t.arrayLength * t.depth, 255u) << 24 | (uint64_t)MIN(t.sampleCount, 255u) << 16 | ((uint32_t)t.pixelFormat & 0xffff), sz); }
        os_unfair_lock_unlock(&g_rl_lk);
        MLOG("[ledger]   lossy render targets (DM_NVN_RT_LOSSY): %llu alive, %.0f MB, saving %.0f MB; made lossy %llu so far (%.0f MB saved as made); left lossless %llu by format, %llu by use, %llu by shape, %llu under %u KB; made lossless as carried across frames %llu",
             (unsigned long long)ln, lb / M, ls / M, (unsigned long long)g_rl_n[RL_LOSSY], g_rl_saved_b / M, (unsigned long long)g_rl_n[RL_FORMAT], (unsigned long long)g_rl_n[RL_USAGE],
             (unsigned long long)g_rl_n[RL_SHAPE], (unsigned long long)g_rl_n[RL_SMALL], RL_MIN >> 10, (unsigned long long)g_rl_n[RL_CARRIED]);
        qsort(lg, nl, sizeof lg[0], lg_cmp);
        for (int i = 0; i < nl && i < 6; i++) { char fb[16]; uint64_t k = lg[i].key;
            MLOG("[ledger]   lossy render targets %llux%llu x%llu %s: %u, %.0f MB", (unsigned long long)(k >> 48), (unsigned long long)(k >> 32 & 0xffff), (unsigned long long)(k >> 24 & 0xff), lg_fmt((uint32_t)(k & 0xffff), fb, sizeof fb), lg[i].n, lg[i].bytes / M); }
    }
    MLOG("[ledger]   buffers in the set %llu, %.0f MB (of them resident pool buffers %llu, %.0f MB, and replaced chunks %llu, %.0f MB: %.0f MB of distinct memory); heaps %llu, %.0f MB; other objects %llu, %.0f MB",
         (unsigned long long)buf_n, buf_b / M, (unsigned long long)poolres_n, poolres_b / M, (unsigned long long)oldres_n, oldres_b / M, distinct_b / M, (unsigned long long)heap_n, heap_b / M, (unsigned long long)other_n, other_b / M);
    MLOG("[ledger]   heaps by kind: recycled render targets %llu, %.0f MB; image families %llu, %.0f MB; sparse tiles %llu, %.0f MB; other %llu, %.0f MB; textures over buffers %llu (their memory is the buffers'; buffers outside the set %.0f MB)",
         (unsigned long long)hk_n[0], hk_b[0] / M, (unsigned long long)hk_n[1], hk_b[1] / M, (unsigned long long)hk_n[2], hk_b[2] / M, (unsigned long long)hk_n[3], hk_b[3] / M, (unsigned long long)ob_n, ob_b / M);
    MLOG("[ledger]   memory pools registered %llu, %.0f MB (resident %llu, %.0f MB; pinned by a texture made on the buffer %llu, %.0f MB, of them large-pool chunks %llu, and replaced chunks %llu); pool buffers freed but alive %llu, %.0f MB; recycled heaps waiting (RH) %u, %.0f MB; upload staging kept %llu blocks, %.0f MB",
         (unsigned long long)pool_n, pool_b / M, (unsigned long long)poolres_n, poolres_b / M, (unsigned long long)pin_n, pin_b / M, (unsigned long long)pin_big, (unsigned long long)pin_old, (unsigned long long)dead_n, dead_b / M, rh_n, rh_b / M, (unsigned long long)up_n, up_b / M);
    lg_heaps(live);   // the recycled render-target heaps and image families by holder
    if (g_mr_mode > 0) {   // DM_NVN_MEM_RELIEF: its state and what it gave back (read without the submit thread's ordering: a diagnostic's view)
        char b[512]; mr_line(b, sizeof b); uint64_t t = clock_gettime_nsec_np(CLOCK_MONOTONIC), on = g_mr_on_ns + (atomic_load(&g_mr_short) ? t - MIN(t, g_mr_since) : 0), av = atomic_load(&g_mr_avail);
        char avs[32] = "not looked at yet"; if (av != UINT64_MAX) snprintf(avs, sizeof avs, "%llu MB available", (unsigned long long)av);
        MLOG("[ledger]   memory relief (DM_NVN_MEM_RELIEF): %s, %s (it gives back under %llu MB), the least seen %llu MB; short of memory %llu times, %.0f s in all; given back so far: %s",
             atomic_load(&g_mr_short) ? "short of memory now" : "not short of memory", avs, (unsigned long long)g_mr_low, (unsigned long long)(g_mr_min == UINT64_MAX ? 0 : g_mr_min),
             (unsigned long long)g_mr_episodes, on / 1e9, b); }
    qsort(rt, nrt, sizeof rt[0], lg_cmp); qsort(sm, nsm, sizeof sm[0], lg_cmp);
    for (int i = 0; i < nrt && i < 8; i++) { char fb[16]; uint64_t k = rt[i].key;
        MLOG("[ledger]   render targets %llux%llu x%llu %s%s: %u, %.0f MB", (unsigned long long)(k >> 48), (unsigned long long)(k >> 32 & 0xffff), (unsigned long long)(k >> 24 & 0xff), lg_fmt((uint32_t)(k & 0xffff), fb, sizeof fb), (k >> 16 & 0xff) > 1 ? " (multisampled)" : "", rt[i].n, rt[i].bytes / M); }
    for (int i = 0; i < nsm && i < 6; i++) { char fb[16]; MLOG("[ledger]   sampled textures %s: %u, %.0f MB", lg_fmt((uint32_t)sm[i].key, fb, sizeof fb), sm[i].n, sm[i].bytes / M); }
    lg_shared();
    {   // the Metal 4 command allocators: each keeps the memory of the largest submission it encoded since it was made (its high water), across resets
        uint64_t am = atomic_load(&g_alloc_pub_b), au = 0, ap = 0, amx = atomic_load(&g_alloc_pub_max); int an = g_alloc_n;   // the submit thread's snapshot: it alone replaces them
        for (int i = 0; i < 3; i++) { au += g_up_alloc4[i] ? g_up_alloc4[i].allocatedSize : 0; ap += g_present_alloc4[i] ? g_present_alloc4[i].allocatedSize : 0; }
        malloc_statistics_t ms; malloc_zone_statistics(NULL, &ms);
        MLOG("[ledger]   command allocators: main %d, %.0f MB (largest %.0f MB; made again empty %llu times, %.0f MB); upload 3, %.0f MB; present 3, %.0f MB; host malloc: %.0f MB in use of %.0f MB the zones hold",
             an, am / M, amx / M, (unsigned long long)g_alloc_trims, g_alloc_trim_b / M, au / M, ap / M, ms.size_in_use / M, ms.size_allocated / M);
    }
} }
// DM_NVN_LEDGER_TSV=<path> (diagnostic, with DM_NVN_LEDGER): every ledger round rewrites <path> with one line per Metal texture, heap and buffer the host holds: the residency set's objects, every
// texture the serial table, the finalized ring and the sharing table hold (a packaged texture's current one and its spare), each once. A texture placed in a heap of its own (a recycled render
// target, dm.rt) counts its heap's size and the heap no more; a view or a texture over a buffer counts 0. Columns: where it was found, kind, in the residency set, bytes, size, mips, Metal format
// and type, usage, storage, purgeable state, heap label, and the storage (pool object + offset) of a texture the sharing table holds, else its label. So a run tells which objects make the graphics part of the footprint, ranked, beside the grouped [ledger] lines
int dm_guest_as_contains(uintptr_t a);   // hle_svc.c: a pool buffer is guest memory (no copy), which the footprint does not charge
static NSMapTable *g_lg_store;   // lg_inventory: a texture of the sharing table → its storage (the pool object and offset), so textures over the same storage show as such
static void lg_inv_line(FILE *f, CFMutableSetRef seen, CFSetRef inset, id o, const char *src) {
    if (!o || CFSetContainsValue(seen, (__bridge const void *)o)) return;
    CFSetAddValue(seen, (__bridge const void *)o);
    int in = CFSetContainsValue(inset, (__bridge const void *)o) != 0;
    if ([o conformsToProtocol:@protocol(MTLTexture)]) { id<MTLTexture> t = o; id<MTLHeap> h = t.heap; uint64_t b; const char *kind = "texture"; NSString *hl = h.label;
        if (t.buffer) { b = 0; kind = "texture-over-buffer"; } else if (t.parentTexture) { b = 0; kind = "view"; }
        else if (h && [hl isEqualToString:@"dm.rt"]) { b = h.size; kind = "texture-in-rt-heap"; CFSetAddValue(seen, (__bridge const void *)h); in = CFSetContainsValue(inset, (__bridge const void *)h) != 0; }
        else b = h ? 0 : t.allocatedSize;   // in a shared heap: the heap's own line counts it
        if (h && b == 0 && !t.buffer && !t.parentTexture) kind = "texture-in-heap";
        int pst = h || t.buffer || t.parentTexture ? 0 : (int)[t setPurgeableState:MTLPurgeableStateKeepCurrent];
        NSString *st = [g_lg_store objectForKey:o];
        fprintf(f, "%s\t%s\t%d\t%llu\t%lu\t%lu\t%lu\t%lu\t%lu\t%lu\t%lu\t%lu\t%lu\t%d\t%s\t%s\n", src, kind, in, (unsigned long long)b, (unsigned long)t.width, (unsigned long)t.height, (unsigned long)t.depth,
                (unsigned long)t.arrayLength, (unsigned long)t.mipmapLevelCount, (unsigned long)t.pixelFormat, (unsigned long)t.textureType, (unsigned long)t.usage, (unsigned long)t.storageMode, pst,
                hl ? hl.UTF8String : "-", st ? st.UTF8String : t.label ? t.label.UTF8String : "-");
        return; }
    if ([o conformsToProtocol:@protocol(MTLHeap)]) { id<MTLHeap> h = o;
        fprintf(f, "%s\theap\t%d\t%llu\t%llu\t%llu\t0\t0\t0\t0\t0\t0\t%lu\t%d\t%s\t-\n", src, in, (unsigned long long)h.size, (unsigned long long)h.usedSize, (unsigned long long)h.currentAllocatedSize,
                (unsigned long)h.storageMode, (int)[h setPurgeableState:MTLPurgeableStateKeepCurrent], h.label ? h.label.UTF8String : "-");
        return; }
    if ([o conformsToProtocol:@protocol(MTLBuffer)]) { id<MTLBuffer> b = o;
        fprintf(f, "%s\tbuffer\t%d\t%llu\t%lu\t0\t0\t0\t0\t0\t0\t0\t%lu\t%d\t%s\t%s\n", src, in, (unsigned long long)b.allocatedSize, (unsigned long)b.length, (unsigned long)b.storageMode,
                b.heap ? 0 : (int)[b setPurgeableState:MTLPurgeableStateKeepCurrent], b.heap.label ? b.heap.label.UTF8String : "-",
                b.storageMode == MTLStorageModeShared && dm_guest_as_contains((uintptr_t)b.contents) ? "guest-pool" : b.label ? b.label.UTF8String : "-");
        return; }
}
static void lg_inventory(const char *path) { @autoreleasepool {
    char tmp[1100]; snprintf(tmp, sizeof tmp, "%s.tmp", path);
    FILE *f = fopen(tmp, "w"); if (!f) return;
    fprintf(f, "src\tkind\tin_set\tbytes\tw_or_len\th_or_used\td_or_alloc\tlayers\tmips\tfmt\ttype\tusage\tstorage\tpurgeable\theap\tlabel\n");
    NSMutableArray *tex = [NSMutableArray array], *src = [NSMutableArray array];
    g_lg_store = [NSMapTable strongToStrongObjectsMapTable];
    pthread_mutex_lock(&g_smu);   // the tables' objects, retained here (+1 each), read below without the lock
    for (uint32_t i = 0; i < g_alias.cap; i++) { void *v = g_alias.vals[i]; if (!v) continue; alias_key k; memcpy(&k, g_alias.keys + (size_t)i * g_alias.klen, sizeof k);
        [g_lg_store setObject:[NSString stringWithFormat:@"storage %llx+%llx", (unsigned long long)k.pool, (unsigned long long)k.off] forKey:(__bridge id)v]; }
    nvn_hmap *maps[3] = {&g_by_serial, &g_ghost, &g_alias}; const char *names[3] = {"serial", "ghost", "shared"};
    for (int m = 0; m < 3; m++) for (uint32_t i = 0; i < maps[m]->cap; i++) { void *v = maps[m]->vals[i]; if (!v) continue; id o = (__bridge id)v;
        if ([o isKindOfClass:[NvPkg class]]) { NvPkg *pk = o; if (pk->tex) { [tex addObject:pk->tex]; [src addObject:@"pkg"]; } if (pk->spare) { [tex addObject:pk->spare]; [src addObject:@"pkg-spare"]; } continue; }
        if ([o conformsToProtocol:@protocol(MTLTexture)]) { [tex addObject:o]; [src addObject:@(names[m])]; } }
    pthread_mutex_unlock(&g_smu);
    pthread_mutex_lock(&g_res_mu); NSArray *live = g_res_objects.allObjects; pthread_mutex_unlock(&g_res_mu);
    CFMutableSetRef seen = CFSetCreateMutable(NULL, 0, NULL), inset = CFSetCreateMutable(NULL, 0, NULL);
    for (id a in live) CFSetAddValue(inset, (__bridge const void *)a);
    for (NSUInteger i = 0; i < tex.count; i++) lg_inv_line(f, seen, inset, tex[i], [src[i] UTF8String]);
    for (id a in live) lg_inv_line(f, seen, inset, a, "set");
    CFRelease(seen); CFRelease(inset); g_lg_store = nil;
    fclose(f); rename(tmp, path);
} }
static void *lg_thread(void *arg) {
    double sec = *(double *)arg; pthread_setname_np("dm-ledger");
    const char *tsv = getenv("DM_NVN_LEDGER_TSV"); char tp[1100];
#if TARGET_OS_IPHONE
    if (tsv && *tsv && *tsv != '/') {   // a relative name goes in the app's data directory, as DM_MEMSTAT's (Library/Caches on tvOS, Documents on iOS: dm/ios/Sources/main.m)
        NSString *dir = NSSearchPathForDirectoriesInDomains(TARGET_OS_TV ? NSCachesDirectory : NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
        if (dir) { snprintf(tp, sizeof tp, "%s/%s", dir.fileSystemRepresentation, tsv); tsv = tp; }
    }
#else
    (void)tp;
#endif
    for (;;) { usleep((useconds_t)(sec * 1e6)); lg_dump(); if (tsv && *tsv) lg_inventory(tsv); }
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
