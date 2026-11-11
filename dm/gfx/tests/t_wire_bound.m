// DM_NVN_WIRE_BOUND (nvn_mtl.m wire_min): a pool of 32 MB or more is held in chunks as a pool of BIG_MIN is, so a binding wires its own range, not the pool. A storage buffer bound inside a
// 96 MB pool must be read and written by the GPU through its device pointer with only its chunk resident; a lookup of unknown extent in such a pool must reach its end (as its whole buffer
// did), while a pool of BIG_MIN keeps BIG_UNKNOWN; a raw load through the learned table (DM_NVN_GMEM_MODE=learned) reads 0 at a stub as before, and once its log is read the pool is whole,
// so a raw load anywhere in it reads its bytes; a raw store makes it whole too; a pool under 32 MB stays one buffer, and the removal of a pool in chunks takes every entry
#include "../nvn/nvn_mtl.m"
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t *g_mod; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int checks, failed;
#define CHECK(label, c) do { checks++; if (!(c)) { failed++; fprintf(stderr, "FAIL: %s (line %d)\n", label, __LINE__); } } while (0)
enum { MB = 1 << 20, ENTRIES = DMSH_GMEM_MAP_ENTRIES };
static uint32_t value(uint64_t off) { return 0x5e000000u | (uint32_t)(off / 4); }
// Resident pool entries over [a, a + n) (no lookup: pool_find would make a chunk)
static int resident_over(uint64_t a, uint64_t n) {
    pthread_mutex_lock(&g_mu); int k = 0;
    for (int i = 0; i < g_npool; i++) if (g_pools[i].res && g_pools[i].base < a + n && a < g_pools[i].base + g_pools[i].buf.length) k++;
    pthread_mutex_unlock(&g_mu); return k;
}
// What a translated storage buffer access does: the shader gets the binding's device address and reads / writes at an offset from it
static NSString *const SRC = @"#include <metal_stdlib>\nusing namespace metal;\n"
    "kernel void sb(device const ulong* ptr [[buffer(0)]], device uint* out [[buffer(1)]], uint id [[thread_position_in_grid]]) {\n"
    "  device uint* p = reinterpret_cast<device uint*>(ptr[0]); uint v = p[id]; p[id] = v ^ 0xffffffffu; out[id] = v; }\n"
    "struct Ent { ulong lo, hi, delta; uint hint, stub; };\n"
    "kernel void rd(device const Ent* map [[buffer(0)]], device atomic_uint* log [[buffer(1)]], device const ulong* addr [[buffer(2)]], device uint* out [[buffer(3)]], uint id [[thread_position_in_grid]]) {\n"
    "  ulong a = addr[id]; out[id] = 0;\n"
    "  for (uint k = 1; k < 8192; k++) { Ent e = map[k]; if (e.lo == ~0ul) break;\n"
    "    if (a >= e.lo && a < e.hi) { atomic_fetch_or_explicit(&log[256 + (k >> 5)], 1u << (k & 31), memory_order_relaxed); out[id] = *reinterpret_cast<device const uint*>(a + e.delta); return; } } }\n";
static id<MTLComputePipelineState> g_sb, g_rd;
static void pipes(void) {
    NSError *e = nil; id<MTLLibrary> l = [g_dev newLibraryWithSource:SRC options:nil error:&e]; if (!l) { fprintf(stderr, "%s\n", e.description.UTF8String); abort(); }
    g_sb = [g_dev newComputePipelineStateWithFunction:[l newFunctionWithName:@"sb"] error:&e]; g_rd = [g_dev newComputePipelineStateWithFunction:[l newFunctionWithName:@"rd"] error:&e]; if (!g_sb || !g_rd) abort();
}
// A storage buffer of n words at address a, as encode_args binds one (mtl_gpu_addr, its residency): the kernel reads every word and writes it inverted. Returns the words read
static int sbuf_rw(uint64_t a, int n, uint32_t *got) {
    void *mb = NULL; uint64_t mo = 0, gpu = 0;
    if (!mtl_gpu_addr(a, (uint64_t)n * 4, &mb, &mo, &gpu)) return 0;
    id<MTLBuffer> ptr = [g_dev newBufferWithBytes:&gpu length:8 options:MTLResourceStorageModeShared], out = [g_dev newBufferWithLength:(NSUInteger)n * 4 options:MTLResourceStorageModeShared];
    res_add(ptr); res_add(out); res_commit();
    id<MTLCommandBuffer> cb = q_cb(); id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
    [ce setComputePipelineState:g_sb]; [ce setBuffer:ptr offset:0 atIndex:0]; [ce setBuffer:out offset:0 atIndex:1]; [ce useResource:(__bridge id<MTLBuffer>)mb usage:MTLResourceUsageRead | MTLResourceUsageWrite];
    [ce dispatchThreads:MTLSizeMake((NSUInteger)n, 1, 1) threadsPerThreadgroup:MTLSizeMake(64, 1, 1)]; [ce endEncoding]; [cb commit]; [cb waitUntilCompleted];
    CHECK("storage buffer access has no GPU error", cb.error == nil);
    memcpy(got, out.contents, (size_t)n * 4); return 1;
}
static void raw_read(id<MTLBuffer> map, id<MTLBuffer> log, const uint64_t *addr, int n, uint32_t *out) {
    id<MTLBuffer> ab = [g_dev newBufferWithBytes:addr length:(NSUInteger)n * 8 options:MTLResourceStorageModeShared], ob = [g_dev newBufferWithLength:(NSUInteger)n * 4 options:MTLResourceStorageModeShared];
    id<MTLCommandBuffer> cb = q_cb(); id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
    [ce setComputePipelineState:g_rd]; [ce setBuffer:map offset:0 atIndex:0]; [ce setBuffer:log offset:0 atIndex:1]; [ce setBuffer:ab offset:0 atIndex:2]; [ce setBuffer:ob offset:0 atIndex:3];
    [ce dispatchThreads:MTLSizeMake((NSUInteger)n, 1, 1) threadsPerThreadgroup:MTLSizeMake((NSUInteger)n, 1, 1)]; [ce endEncoding]; [cb commit]; [cb waitUntilCompleted];
    CHECK("raw read has no GPU error", cb.error == nil);
    memcpy(out, ob.contents, (size_t)n * 4);
}
static int entry_of(id<MTLBuffer> map, uint64_t addr, int *stub) {
    const uint8_t *t = (const uint8_t *)map.contents;
    for (int k = 1; k < ENTRIES; k++) { uint64_t e[2]; memcpy(e, t + (size_t)k * DMSH_GMEM_MAP_ENTRY, sizeof e); if (e[0] == ~0ull) break;
        if (addr >= e[0] && addr < e[1]) { uint32_t f; memcpy(&f, t + (size_t)k * DMSH_GMEM_MAP_ENTRY + 28, 4); if (stub) *stub = (int)f; return k; } }
    return 0;
}
static void sub(void) { mtl_sub_begin(); (void)gmem_map(); CHECK("submission completes", mtl_wait(mtl_sub_commit(), 5000000000ull)); }
int main(void) { @autoreleasepool {
    mtl_init(); pipes();
    CHECK("the switch is on: pools of 32 MB and more in chunks", wire_min() == WIRE_MIN);
    CHECK("learned mode", gmem_learned());
    // A 96 MB pool: in chunks, nothing wired
    uint8_t *mem = mmap(NULL, 96 * MB, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0); if (mem == MAP_FAILED) abort();
    uint64_t base = (uint64_t)(uintptr_t)mem;
    for (uint64_t o = 0; o < 96ull * MB; o += 4) *(uint32_t *)(mem + o) = value(o);
    int pools0 = g_npool; mtl_pool_add(mem, 96 * MB);
    CHECK("in chunks: no buffer yet", g_npool == pools0 && g_nbig == 1 && g_big[0].small);
    // A storage buffer bound at 70 MB, 1 MB long: the GPU reads its words and writes them inverted through the device pointer; only its chunk is resident
    enum { W = 1 * MB / 4 }; static uint32_t got[W];
    CHECK("storage buffer bound", sbuf_rw(base + 70 * MB, W, got));
    int ok = 1; for (int i = 0; i < W; i++) ok &= got[i] == value(70ull * MB + 4ull * i) && *(uint32_t *)(mem + 70 * MB + 4ull * i) == ~value(70ull * MB + 4ull * i);
    CHECK("the GPU read the bound range's bytes and its writes landed in the guest's memory", ok);
    CHECK("one chunk made", g_npool == pools0 + 1);
    CHECK("the binding's range is resident", resident_over(base + 70 * MB, MB) == 1);
    CHECK("the pool's start is not wired", resident_over(base, 32 * MB) == 0);
    { pthread_mutex_lock(&g_mu); const pool_ent *p = &g_pools[g_npool - 1]; CHECK("the chunk starts at its stride and holds the range", p->base == base + 64 * MB && p->base + p->buf.length >= base + 71 * MB && p->base + p->buf.length <= base + 96 * MB); pthread_mutex_unlock(&g_mu); }
    // Unknown extent (length 1) in a small pool: the buffer reaches the pool's end, as its whole buffer did; the GPU writes far past BIG_UNKNOWN's reach from a lookup low in the pool
    void *mb = NULL; uint64_t mo = 0, gpu = 0;
    CHECK("unknown extent found", mtl_gpu_addr(base + 8 * MB + 4, 1, &mb, &mo, &gpu));
    CHECK("unknown extent reaches the pool's end", (uint64_t)(uintptr_t)((__bridge id<MTLBuffer>)mb).contents + ((__bridge id<MTLBuffer>)mb).length == base + 96 * MB);
    { id<MTLCommandBuffer> cb = q_cb(); id<MTLBlitCommandEncoder> be = [cb blitCommandEncoder]; [be fillBuffer:(__bridge id<MTLBuffer>)mb range:NSMakeRange(mo + 80 * MB, 4096) value:0xa5]; [be endEncoding]; [cb commit]; [cb waitUntilCompleted];
      CHECK("a write 80 MB past an unknown-extent lookup lands", mem[88 * MB + 4] == 0xa5 && mem[88 * MB + 4095] == 0xa5); }
    // A look that only asks (pool_peek, the walk's statistic) makes no chunk: one made to the pool's end would be what a later binding in that stride takes and wires
    { pthread_mutex_lock(&g_mu); int np = g_npool, q = pool_peek(base + 40 * MB + 64); CHECK("a peek in a stride with no chunk finds nothing and makes none", q < 0 && g_npool == np);
      q = pool_peek(base + 70 * MB + 64); CHECK("a peek finds the binding's chunk", q >= 0 && g_pools[q].base == base + 64 * MB); pthread_mutex_unlock(&g_mu); }
    // A pool of BIG_MIN keeps BIG_UNKNOWN for unknown extents
    uint8_t *big = mmap(NULL, 640 * MB, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0); if (big == MAP_FAILED) abort();
    mtl_pool_add(big, 640 * MB); CHECK("the large pool in chunks, not small", g_nbig == 2 && !g_big[1].small);
    CHECK("large pool, unknown extent found", mtl_gpu_addr((uint64_t)(uintptr_t)big + 100 * MB + 4, 1, &mb, &mo, &gpu));
    { id<MTLBuffer> b = (__bridge id<MTLBuffer>)mb; uint64_t end = (uint64_t)(uintptr_t)b.contents + b.length;
      CHECK("large pool, unknown extent: BIG_UNKNOWN past it, not the pool's end", b.length - mo >= BIG_UNKNOWN && end < (uint64_t)(uintptr_t)big + 640 * MB); }
    // Raw global memory, learned: every window of the small pool not chunked is a stub, and so is its resident chunk not read lately (as a resident pool not read lately is). A raw load reads 0
    mtl_pool_addressed(mem, 96 * MB);
    mtl_sub_begin(); id<MTLBuffer> map = gmem_map(); CHECK("table made", map != nil); CHECK("submission completes", mtl_wait(mtl_sub_commit(), 5000000000ull));
    int stub = 0; uint64_t r1 = base + 5 * MB + 64, r2 = base + 40 * MB + 128;
    CHECK("an unbound window is a stub", entry_of(map, r1, &stub) && stub == 1);
    id<MTLBuffer> log = [g_dev newBufferWithLength:2 * ENTRIES / 8 options:MTLResourceStorageModeShared]; memset(log.contents, 0, log.length);
    uint64_t a1[1] = {r1}; uint32_t o1[1]; raw_read(map, log, a1, 1, o1);
    CHECK("a raw load at a stub reads 0, as before", o1[0] == 0);
    gml_rd_read(log, map, 900);
    CHECK("the read makes the small pool whole", g_big[0].full > 0);
    { pthread_mutex_lock(&g_mu); const pool_ent *p = &g_pools[g_big[0].full - 1]; CHECK("its whole entry spans the pool", p->base == base && p->base + p->buf.length == base + 96 * MB); pthread_mutex_unlock(&g_mu); }
    mtl_sub_begin(); id<MTLBuffer> map2 = gmem_map(); CHECK("submission completes", mtl_wait(mtl_sub_commit(), 5000000000ull));
    CHECK("a new table", map2 != map);
    CHECK("the read address is resident now", entry_of(map2, r1, &stub) && !stub);
    CHECK("so is another window of the pool, never read", entry_of(map2, r2, &stub) && !stub);
    memset(log.contents, 0, log.length);
    uint64_t a2[2] = {r1, r2}; uint32_t o2[2]; raw_read(map2, log, a2, 2, o2);
    CHECK("the read address reads its bytes", o2[0] == value(r1 - base));
    CHECK("another window reads its bytes at once, as from the whole buffer before", o2[1] == value(r2 - base));
    CHECK("lookups now take the whole entry", mtl_gpu_addr(base + 20 * MB, 64, &mb, &mo, &gpu) && ((__bridge id<MTLBuffer>)mb).length == 96 * MB);
    // A raw store reaching a second small pool makes it whole too (the write log)
    uint8_t *m2 = mmap(NULL, 48 * MB, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0); if (m2 == MAP_FAILED) abort();
    mtl_pool_add(m2, 48 * MB); mtl_pool_addressed(m2, 48 * MB); int k2 = g_nbig - 1; CHECK("a second small pool in chunks", g_big[k2].small && !g_big[k2].full);
    mtl_sub_begin(); id<MTLBuffer> map3 = gmem_map(); (void)gml_take(map3, 1); CHECK("submission completes", mtl_wait(mtl_sub_commit(), 5000000000ull));
    int want = entry_of(map3, (uint64_t)(uintptr_t)m2 + 20 * MB, &stub); CHECK("its window has an entry", want > 0);
    id<MTLBuffer> w = [g_dev newBufferWithLength:GML_BYTES options:MTLResourceStorageModeShared]; ((uint32_t *)w.contents)[want / 32] = 1u << (want % 32);
    gml_read(w, map3, 0, 0);
    CHECK("a raw store makes it whole", g_big[k2].full > 0);
    // A pool under 32 MB is one buffer
    uint8_t *s = mmap(NULL, 24 * MB, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0); if (s == MAP_FAILED) abort();
    int n4 = g_npool, b4 = g_nbig; mtl_pool_add(s, 24 * MB); CHECK("a 24 MB pool: one entry, not in chunks", g_npool == n4 + 1 && g_nbig == b4);
    // Removal takes every entry of a pool in chunks
    int before = g_npool; mtl_pool_del(mem); mtl_drain();
    CHECK("the small pool's entries are gone", g_npool < before && !mtl_gpu_addr(base + 70 * MB, 4, &mb, &mo, &gpu));
    mtl_pool_del(m2); mtl_pool_del(big); mtl_pool_del(s); mtl_drain();
    CHECK("no pool in chunks left", g_nbig == 0);
    CHECK("GPU success", !mtl_last_commit_error());
    printf("t_wire_bound: %d checks, %d failed\n", checks, failed); return failed != 0;
} }
