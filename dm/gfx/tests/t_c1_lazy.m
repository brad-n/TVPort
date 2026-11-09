// A shader's c1 (its embedded constant segment) goes into a bank at its first use, the argument block that binds it (nvn_mtl.m c1_slot), not when the shader loads (DM_NVN_C1_LAZY, on
// by default; 0 = at load as before). The prewarm loads thousands of shaders a game never draws, and without a valid c1_full.tsv each took 64 KiB (468 MB in Ocarina of Time's first house
// on a partial library). Checks: loaded shaders take no bank; a bound one gets its data, zero past it, in a 64 KiB slice of its own without the table, or packed when the table clears it;
// a second use, and many threads binding a fresh shader at once, give one slice; a shader with no c1 data gets none (the caller binds the zero bank)
#include "../nvn/nvn_mtl.m"
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t *g_mod; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int checks, failed;
#define CHECK(c, label) do { checks++; if (!(c)) { failed++; fprintf(stderr, "FAIL: %s (line %d)\n", label, __LINE__); } } while (0)

static NvShader *shader(const char *key, unsigned len, uint8_t v) {
    NvShader *o = [NvShader new]; snprintf(o->key, sizeof o->key, "%s_b", key);
    if (len) { o->rf.has_c1 = 1; o->rf.c1_len = (uint16_t)len; o->rf.c1 = malloc(len); memset(o->rf.c1, v, len); }
    if (!c1_lazy() && o->rf.has_c1) c1_store(o);   // what the shader loader does (shader_get)
    return o;
}
static int slice_ok(NvShader *o, id<MTLBuffer> b, uint64_t gpu, size_t zeros) {   // its data, then zeros
    if (!b || gpu != b.gpuAddress + o->c1off) return 0;
    const uint8_t *p = (const uint8_t *)b.contents + o->c1off;
    for (unsigned i = 0; i < o->rf.c1_len; i++) if (p[i] != o->rf.c1[i]) return 0;
    for (size_t i = o->rf.c1_len; i < zeros; i++) if (p[i]) return 0;
    return 1;
}

int main(void) { @autoreleasepool {
    mtl_init();
    int lazy = !(getenv("DM_NVN_C1_LAZY") && !strcmp(getenv("DM_NVN_C1_LAZY"), "0"));
    CHECK(c1_lazy() == lazy, "the switch: on unless DM_NVN_C1_LAZY=0");
    g_c1_full_valid = 0;   // a partial library: no c1_full.tsv
    NSMutableArray<NvShader *> *loaded = [NSMutableArray array];
    for (int i = 0; i < 1000; i++) { char k[17]; snprintf(k, sizeof k, "%016x", 0xa0000 + i); [loaded addObject:shader(k, 256 + (i % 3) * 256, (uint8_t)(i + 1))]; }
    if (lazy) CHECK(g_c1_count == 0 && g_c1_banks.count == 0, "1,000 shaders loaded take no c1 memory");
    else CHECK(g_c1_count == 1000 && g_c1_banks.count == 16, "with the switch at 0 each loaded shader takes 64 KiB at once (16 banks)");
    uint64_t prev = 0;
    for (int i = 0; i < 10; i++) {
        uint64_t gpu = 0; id<MTLBuffer> b = c1_slot(loaded[i], &gpu);
        CHECK(slice_ok(loaded[i], b, gpu, C1_DECL_SIZE), "without the table a bound shader's c1 is its data and zeros to 64 KiB");
        CHECK(!i || gpu >= prev + C1_DECL_SIZE, "each slice has 64 KiB of its own");
        prev = gpu;
    }
    if (lazy) CHECK(g_c1_count == 10 && g_c1_banks.count == 1, "ten bound shaders take ten slices of one bank (the other 990 nothing)");
    { uint64_t g1 = 0, g2 = 0; id<MTLBuffer> b1 = c1_slot(loaded[3], &g1), b2 = c1_slot(loaded[3], &g2); uint64_t n = g_c1_count;
      CHECK(b1 == b2 && g1 == g2 && g_c1_count == n, "a second use is the same slice"); }
    // A valid table: a shader it does not list is packed (its data rounded to 256 bytes, then a 256-byte gap); a listed one keeps 64 KiB
    g_c1_full_valid = 1; g_c1_full = [NSMutableSet setWithObject:@"00000000000b0001"];
    size_t off0 = g_c1_bank_off;   // before the loader (with the switch at 0) or the first use gives them slices
    NvShader *p = shader("00000000000b0000", 300, 7), *q = shader("00000000000b0001", 300, 9);
    uint64_t gp = 0, gq = 0;
    id<MTLBuffer> bp = c1_slot(p, &gp);
    CHECK(slice_ok(p, bp, gp, 512) && p->c1off == off0, "an unlisted shader's c1 is packed");
    id<MTLBuffer> bq = c1_slot(q, &gq);
    CHECK(slice_ok(q, bq, gq, C1_DECL_SIZE) && q->c1off == off0 + 512 + 256 && g_c1_bank_off == q->c1off + C1_DECL_SIZE, "its data rounded to 256 bytes and a 256-byte gap; a listed one gets 64 KiB of zeros past its data");
    // Many threads binding one fresh shader at once: one slice, one address
    NvShader *r = shader("00000000000c0000", 512, 0x33);
    uint64_t n0 = g_c1_count, addr[64], *ap = addr;
    dispatch_apply(64, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^(size_t i) { uint64_t g = 0; c1_slot(r, &g); ap[i] = g; });
    int same = 1; for (int i = 1; i < 64; i++) same &= addr[i] == addr[0];
    CHECK(same && addr[0] && g_c1_count == n0 + (lazy ? 1 : 0), "threads binding a fresh shader at once get one slice");
    // A shader that declares c1 with no data: no slice (the argument block binds the zero bank)
    NvShader *z = shader("00000000000d0000", 0, 0); uint64_t gz = 0;
    CHECK(!c1_slot(z, &gz), "a c1 of length 0 gets no slice");
    printf("t_c1_lazy%s: %d checks, %d failed\n", lazy ? "" : " (off)", checks, failed); return failed != 0;
} }
