// A pixel shader's fixed-offset uniform reads without their bounds tests (dmsh_build.py ub_fixed, nvn_mtl.m ubx_want / ubx_fn), on the GPU. With the directory test_dmsh_ubx.py --fixture
// writes (ubx.metal: a shader in the translator's shape whose tests are behind DMSH_UBX_FC; ubx.json: the bytes each slot's tests need), the host loads it as a shader (shader_load: ub_need),
// decides from the fragment stage's bindings when the variant may draw (every slot bound at least as long as its tests need, measured as the size table holds it: min(size, 64 KiB), 0
// unbound), and pso_desc gives a pipeline with ubc 0 the specialization with DMSH_UBX_FC true and one with ubc 1 the shader as it is. The variant and the shader with its tests then draw
// with the same bindings and the same size table: every word of both targets must be the same at every pixel (a run of each binding the host accepts: exactly the need, more, over 64 KiB),
// and where a slot is bound shorter than a fixed read, the host must keep the tests, which give 0 for the words past the size while the variant would read the memory beyond it
// (checked, so the test sees the difference it guards). Both compiler paths: DM_PSO_MTL4=0 (MTLDevice, the TV's) and 1
#include "../nvn/nvn_mtl.m"
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t *g_mod; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int checks, failed;
#define CHECK(c, ...) do { checks++; if (!(c)) { failed++; fprintf(stderr, "FAIL: "); fprintf(stderr, __VA_ARGS__); fprintf(stderr, "\n"); } } while (0)
enum { W = 4, H = 4, C3_WORDS = 8192, C4_WORDS = 16 };

static const char *VS = "#include <metal_stdlib>\nusing namespace metal;\nstruct V { float4 p [[position]]; };\n"
    "vertex V ubx_vs(uint i [[vertex_id]]) { float2 q[3] = {float2(-1, -1), float2(3, -1), float2(-1, 3)}; V o; o.p = float4(q[i], 0, 1); return o; }\n";

static int fixture(NSString *dir) {
    NSTask *t = [NSTask new]; t.executableURL = [NSURL fileURLWithPath:@"/usr/bin/xcrun"];
    t.arguments = @[@"-sdk", @"macosx", @"metal", @"-O1", @"-fpreserve-invariance", @"-fwrapv", [dir stringByAppendingPathComponent:@"ubx.metal"], @"-o", [dir stringByAppendingPathComponent:@"ubx-fs.metallib"]];
    NSError *e = nil; if (![t launchAndReturnError:&e]) { fprintf(stderr, "metal: %s\n", e.localizedDescription.UTF8String); return 0; }
    [t waitUntilExit]; if (t.terminationStatus) return 0;
    NSDictionary *fx = [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:[dir stringByAppendingPathComponent:@"ubx.json"]] options:0 error:nil];
    if (![fx[@"ub_fixed"] isKindOfClass:NSDictionary.class]) return 0;
    NSDictionary *refl = @{@"chain": @DMSH_CHAIN, @"route": @"B", @"stage": @"ps", @"entry": @"main0", @"vertex_inputs": @[], @"ub_fixed": fx[@"ub_fixed"],
        @"bindings": @[@{@"msl_name": @"fp_c3", @"msl_type": @"constant _16*", @"arg_id": @0, @"kind": @DMSH_KIND_CBUF, @"reg": @0},
                       @{@"msl_name": [NSString stringWithFormat:@"fp_c%d", DMSH_CBSIZE_BANK], @"msl_type": @"constant _23*", @"arg_id": @1, @"kind": @DMSH_KIND_CBSIZE},
                       @{@"msl_name": @"fp_c4", @"msl_type": @"constant _16*", @"arg_id": @2, @"kind": @DMSH_KIND_CBUF, @"reg": @1}]};
    if (![[NSJSONSerialization dataWithJSONObject:refl options:0 error:nil] writeToFile:[dir stringByAppendingPathComponent:@"ubx-fs.json"] atomically:YES]) return 0;
    g_msl_dir = dir; return 1;
}

// Draws fs with the bindings the size table describes: c[3] and c[4] from their buffers, the table's entries as the host encodes them; *out: the two RGBA32Uint targets, 2 x W x H x 4 words
static void ubx_draw(id<MTLFunction> fs, id<MTLBuffer> c3, id<MTLBuffer> c4, const uint32_t table[DMSH_CBSIZE_SLOTS], uint32_t *out) {
    static id<MTLFunction> vs; static id<MTLCommandQueue> q;
    NSError *e = nil;
    if (!vs) { vs = [[g_dev newLibraryWithSource:@(VS) options:nil error:&e] newFunctionWithName:@"ubx_vs"]; q = [g_dev newCommandQueue]; }
    MTLRenderPipelineDescriptor *d = [MTLRenderPipelineDescriptor new]; d.vertexFunction = vs; d.fragmentFunction = fs;
    d.colorAttachments[0].pixelFormat = d.colorAttachments[1].pixelFormat = MTLPixelFormatRGBA32Uint;
    id<MTLRenderPipelineState> p = [g_dev newRenderPipelineStateWithDescriptor:d error:&e];
    if (!p) { CHECK(0, "pipeline: %s", e.localizedDescription.UTF8String); return; }
    id<MTLBuffer> tb = [g_dev newBufferWithLength:16 * ((DMSH_CBSIZE_SLOTS + 3) / 4) options:MTLResourceStorageModeShared]; memcpy(tb.contents, table, sizeof(uint32_t) * DMSH_CBSIZE_SLOTS);
    id<MTLBuffer> ab = [g_dev newBufferWithLength:24 options:MTLResourceStorageModeShared];   // the argument buffer: fp_c3 [[id(0)]], the size table [[id(1)]], fp_c4 [[id(2)]]
    ((uint64_t *)ab.contents)[0] = c3.gpuAddress; ((uint64_t *)ab.contents)[1] = tb.gpuAddress; ((uint64_t *)ab.contents)[2] = c4.gpuAddress;
    id<MTLTexture> t[2]; MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor new];
    for (int i = 0; i < 2; i++) {
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA32Uint width:W height:H mipmapped:NO];
        td.usage = MTLTextureUsageRenderTarget; td.storageMode = MTLStorageModeShared; t[i] = [g_dev newTextureWithDescriptor:td];
        rp.colorAttachments[i].texture = t[i]; rp.colorAttachments[i].loadAction = MTLLoadActionClear; rp.colorAttachments[i].clearColor = MTLClearColorMake(7, 7, 7, 7); rp.colorAttachments[i].storeAction = MTLStoreActionStore;
    }
    id<MTLCommandBuffer> cb = [q commandBuffer]; id<MTLRenderCommandEncoder> en = [cb renderCommandEncoderWithDescriptor:rp];
    [en setRenderPipelineState:p]; [en setFragmentBuffer:ab offset:0 atIndex:0];
    [en useResource:c3 usage:MTLResourceUsageRead stages:MTLRenderStageFragment]; [en useResource:c4 usage:MTLResourceUsageRead stages:MTLRenderStageFragment]; [en useResource:tb usage:MTLResourceUsageRead stages:MTLRenderStageFragment];
    [en drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3]; [en endEncoding]; [cb commit]; [cb waitUntilCompleted];
    CHECK(cb.status == MTLCommandBufferStatusCompleted, "draw completed");
    for (int i = 0; i < 2; i++) [t[i] getBytes:out + i * W * H * 4 bytesPerRow:W * 16 fromRegion:MTLRegionMake2D(0, 0, W, H) mipmapLevel:0];
}

// What the shader with its tests writes: c[3] words 5, 17, 63, 1023, c[4] words 0 and 6, c[3] word 4 (y + 2) + (x & 3), each 0 past its slot's size in words (table >> 2)
static void ubx_expect(const uint32_t *w3, const uint32_t *w4, const uint32_t table[DMSH_CBSIZE_SLOTS], uint32_t *out) {
    uint32_t n3 = table[0] >> 2, n4 = table[1] >> 2;
    for (int y = 0; y < H; y++) for (int x = 0; x < W; x++) {
        uint32_t *a = out + (y * W + x) * 4, *b = out + W * H * 4 + (y * W + x) * 4, cw = 4u * (uint32_t)(y + 2) + (uint32_t)(x & 3);
        a[0] = 5 < n3 ? w3[5] : 0; a[1] = 17 < n3 ? w3[17] : 0; a[2] = 63 < n3 ? w3[63] : 0; a[3] = 1023 < n3 ? w3[1023] : 0;
        b[0] = 0 < n4 ? w4[0] : 0; b[1] = 6 < n4 ? w4[6] : 0; b[2] = cw < n3 ? w3[cw] : 0; b[3] = 4660;
    }
}

int main(int argc, char **argv) { @autoreleasepool {
    if (argc != 2) { fprintf(stderr, "usage: t_ubx <dir test_dmsh_ubx.py --fixture wrote>\n"); return 2; }
    alarm(60);
    setenv("DM_PSO_ARCHIVE", "off", 1); unsetenv("DM_NVN_UBX"); unsetenv("DM_AB");
    mtl_init();
    if (!fixture(@(argv[1]))) { fprintf(stderr, "fixture failed\n"); return 1; }
    NvShader *fs = shader_load(@"ubx-fs", 1, 0);
    CHECK(fs && fs->ub_any, "the shader's tests are known (ub_fixed)");
    if (!fs || !fs->ub_any) return 1;
    CHECK(fs->ub_need[0] == 4096 && fs->ub_need[1] == 28, "needs c[3] 4096 bytes, c[4] 28 (got %u, %u)", fs->ub_need[0], fs->ub_need[1]);
    // The words of the two slots' memory: finite, distinct, none 0
    id<MTLBuffer> c3 = [g_dev newBufferWithLength:C3_WORDS * 4 options:MTLResourceStorageModeShared], c4 = [g_dev newBufferWithLength:C4_WORDS * 4 options:MTLResourceStorageModeShared];
    uint32_t *w3 = c3.contents, *w4 = c4.contents;
    for (uint32_t i = 0; i < C3_WORDS; i++) w3[i] = 0x40000000u + i;
    for (uint32_t i = 0; i < C4_WORDS; i++) w4[i] = 0x41000000u + i;
    // The fragment function as the host builds a pipeline with the tests (pso_desc with ubc 1) and without them (ubc 0)
    pso_key k; memset(&k, 0, sizeof k); k.cfmt[0] = k.cfmt[1] = MTLPixelFormatRGBA32Uint; k.chmask = 0xff;
    k.ubc = 1; id<MTLFunction> with = fn_dev(pso_desc(&k, nil, fs, nil, 0).fragmentFunction);
    k.ubc = 0; id<MTLFunction> without = fn_dev(pso_desc(&k, nil, fs, nil, 0).fragmentFunction);
    CHECK(with && without && with != without, "ubc 0 takes another function than ubc 1");
    CHECK(fn_dev(pso_desc(&k, nil, fs, nil, 0).fragmentFunction) == without, "the variant is made once per function");
    MTL4FunctionDescriptor *note = fn4_of(without);
    CHECK([note isKindOfClass:[MTL4SpecializedFunctionDescriptor class]] && [((MTL4LibraryFunctionDescriptor *)((MTL4SpecializedFunctionDescriptor *)note).functionDescriptor).name isEqual:@"main0"],
          "the variant is main0 specialized, noted for the Metal 4 compiler");
    // Bindings the host accepts, and what it decides for each (ubx_want reads S.ubo[1], as pso_key_fill does at the draw)
    struct { const char *what; uint64_t a3, s3, a4, s4; int want; } cases[] = {
        {"both slots bound exactly as long as the tests need", 1, 4096, 1, 28, 1},
        {"longer than needed", 1, 32768, 1, 64, 1},
        {"c[3] past 64 KiB (the table holds 64 KiB)", 1, 100000, 1, 28, 1},
        {"c[3] 4 bytes short of word 1023", 1, 4092, 1, 28, 0},
        {"c[3] bound with 64 bytes (words 17, 63 and 1023 past it)", 1, 64, 1, 28, 0},
        {"c[4] 24 bytes (word 6 past it)", 1, 4096, 1, 24, 0},
        {"c[4] not bound", 1, 4096, 0, 0, 0},
    };
    for (size_t c = 0; c < sizeof cases / sizeof *cases; c++) {
        memset(S.ubo[1], 0, sizeof S.ubo[1]);
        S.ubo[1][0] = (p_bind_buf){.stage = 1, .index = 0, .addr = cases[c].a3 ? 0x10000000 : 0, .size = cases[c].s3};
        S.ubo[1][1] = (p_bind_buf){.stage = 1, .index = 1, .addr = cases[c].a4 ? 0x20000000 : 0, .size = cases[c].s4};
        int want = ubx_want(fs);
        CHECK(want == cases[c].want, "%s: the host %s the variant", cases[c].what, want ? "takes" : "does not take");
        uint32_t table[DMSH_CBSIZE_SLOTS] = {0};   // as encode_args_ fills NVN_RB_CBSIZE
        for (int r = 0; r < 2; r++) { const p_bind_buf *u = &S.ubo[1][r]; if (u->addr) table[r] = u->size < 65536 ? (uint32_t)u->size : 65536; }
        static uint32_t a[2 * W * H * 4], b[2 * W * H * 4], x[2 * W * H * 4];
        ubx_expect(w3, w4, table, x);
        ubx_draw(with, c3, c4, table, a);
        CHECK(!memcmp(a, x, sizeof a), "%s: the shader with its tests writes the words of the bindings, 0 past their sizes", cases[c].what);
        ubx_draw(without, c3, c4, table, b);
        if (cases[c].want) CHECK(!memcmp(a, b, sizeof a), "%s: the variant writes the same words as the shader with its tests, at every pixel", cases[c].what);
        else CHECK(memcmp(a, b, sizeof a) != 0, "%s: the variant would read past the size (so the host must not take it, and does not)", cases[c].what);
    }
    // DM_NVN_UBX=0: never
    memset(S.ubo[1], 0, sizeof S.ubo[1]); S.ubo[1][0] = (p_bind_buf){.addr = 0x10000000, .size = 4096}; S.ubo[1][1] = (p_bind_buf){.addr = 0x20000000, .size = 28};
    int m = g_ubx_m; g_ubx_m = 0; CHECK(!ubx_want(fs), "DM_NVN_UBX=0 keeps the tests"); g_ubx_m = m;
    printf("t_ubx: %d checks, %d failed; %s\n", checks, failed, pso4_compiler() ? "Metal 4" : "MTLDevice");
    return failed != 0;
} }
