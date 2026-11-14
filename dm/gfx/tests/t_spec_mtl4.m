// Function constants on the Metal 4 pipeline path (pso_build through MTL4Compiler, the Mac's default). A function's constant values live only in the descriptor noted on it
// (fn4_note / fn4_of), and Metal hands out one function object for an entry point of the same library data, so a shader loaded a second time notes the function a live pipeline
// is built from. MTL4Compiler aborts on a fragment function that declares constants and has no values (validateWithDevice, debug layer or not): Star Fox, after the barrel-roll
// training. Checks: a function noted again with no values (shader_load's first note of each entry) keeps its specialized descriptor, also while another thread reads it as a
// pipeline build does; a function noted only with no values (tf_fn, mesh_obj) gets an empty set, and an MTLDevice pipeline (pso_build_dev) gets it specialized; a second request for
// a name with other values (nf_fn's R11G11B10F variants) is a function of its own, with a base of its own, whose pipelines draw with its values while the first request's keep theirs.
// A check that would hand Metal an unspecialized function reports the failure instead of building (Metal would abort the run)
#include "../nvn/nvn_mtl.m"
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t *g_mod; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int checks, failed;
#define CHECK(c, label) do { checks++; if (!(c)) { failed++; fprintf(stderr, "FAIL: %s (line %d)\n", label, __LINE__); } } while (0)

static id<MTLCommandQueue> g_q;
static int is_spec(id<MTLFunction> f) { return [fn4_of(f) isKindOfClass:MTL4SpecializedFunctionDescriptor.class]; }
// The value a pipeline draws into one R32Float pixel
static float draw_one(id<MTLRenderPipelineState> ps) {
    if (!ps) return -3;
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR32Float width:1 height:1 mipmapped:NO];
    td.usage = MTLTextureUsageRenderTarget; td.storageMode = MTLStorageModeShared;
    id<MTLTexture> t = [g_dev newTextureWithDescriptor:td];
    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor new]; rp.colorAttachments[0].texture = t; rp.colorAttachments[0].loadAction = MTLLoadActionClear;
    rp.colorAttachments[0].clearColor = MTLClearColorMake(-1, 0, 0, 0); rp.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLCommandBuffer> cb = [g_q commandBuffer]; id<MTLRenderCommandEncoder> e = [cb renderCommandEncoderWithDescriptor:rp];
    [e setRenderPipelineState:ps]; [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3]; [e endEncoding];
    [cb commit]; [cb waitUntilCompleted];
    float v = -2; [t getBytes:&v bytesPerRow:4 fromRegion:MTLRegionMake2D(0, 0, 1, 1) mipmapLevel:0]; return v;
}
static MTLRenderPipelineDescriptor *desc(id<MTLFunction> vs, id<MTLFunction> fs) {
    MTLRenderPipelineDescriptor *d = [MTLRenderPipelineDescriptor new]; d.vertexFunction = vs; d.fragmentFunction = fs; d.colorAttachments[0].pixelFormat = MTLPixelFormatR32Float; return d;
}
int main(void) { @autoreleasepool {
    setenv("DM_PSO_ARCHIVE", "off", 1);   // no archive: each base is compiled here
    mtl_init(); g_q = [g_dev newCommandQueue];
    CHECK(pso4_compiler(), "the Metal 4 compiler is on (the Mac's default)");
    NSError *err = nil;
    NSMutableString *src = [NSMutableString stringWithString:@"#include <metal_stdlib>\nusing namespace metal;\nconstant uint k [[function_constant(0)]];\nstruct V { float4 p [[position]]; };\n"
        "vertex V pvs(uint i [[vertex_id]]) { V o; float2 uv = float2((i << 1) & 2, i & 2); o.p = float4(uv * 2 - 1, 0, 1); return o; }\n"];
    for (int i = 1; i <= 4; i++) [src appendFormat:@"fragment float4 cfs%d() { return float4(is_function_constant_defined(k) ? float(k) : 0.25, 0, 0, 1); }\n", i];
    id<MTLLibrary> L = [g_dev newLibraryWithSource:src options:nil error:&err];
    if (!L) { fprintf(stderr, "library: %s\n", err.localizedDescription.UTF8String); return 1; }
    MTLFunctionConstantValues *none = [MTLFunctionConstantValues new], *three = [MTLFunctionConstantValues new]; uint32_t v3 = 3; [three setConstantValue:&v3 type:MTLDataTypeUInt atIndex:0];
    id<MTLFunction> vs = fn_spec(L, @"pvs", none, &err);
    CHECK(vs && !vs.functionConstantsDictionary.count, "the vertex function has no constants");
    NSError *pe = nil;

    // A shader loaded a second time: Metal's one function object for the entry point, noted with no values before the loader specializes it
    id<MTLFunction> f1 = fn_spec(L, @"cfs1", none, &err);
    CHECK(f1 && f1.functionConstantsDictionary.count == 1 && is_spec(f1), "a loaded function with constants has a specialized descriptor");
    id<MTLFunction> again = [L newFunctionWithName:@"cfs1"];
    CHECK(again == f1, "the library hands out the same function object for the name");
    fn4_note(again, L, @"cfs1", nil);
    CHECK(is_spec(f1), "noted again with no values, it keeps its specialized descriptor");
    if (is_spec(f1)) CHECK(draw_one(pso_build(desc(vs, f1), &pe)) == 0.25f, "and its pipeline draws with the constant at its default");

    // The same while another thread reads the descriptor, as a pipeline build does: never unspecialized
    id<MTLFunction> f2 = fn_spec(L, @"cfs2", none, &err);
    __block _Atomic int writing = 1; __block _Atomic uint64_t reads = 0, open = 0;
    dispatch_group_t g = dispatch_group_create(); dispatch_queue_t gq = dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0);
    dispatch_group_async(g, gq, ^{ @autoreleasepool { while (atomic_load(&writing)) { atomic_fetch_add(&reads, 1); if (!is_spec(f2)) atomic_fetch_add(&open, 1); } } });
    dispatch_group_async(g, gq, ^{ @autoreleasepool { for (int i = 0; i < 20000; i++) { @autoreleasepool { NSError *we = nil;
        fn4_note([L newFunctionWithName:@"cfs2"], L, @"cfs2", nil); fn_spec(L, @"cfs2", none, &we); } } atomic_store(&writing, 0); } });
    dispatch_group_wait(g, DISPATCH_TIME_FOREVER);
    if (atomic_load(&open)) fprintf(stderr, "unspecialized descriptor seen %llu times in %llu reads\n", (unsigned long long)atomic_load(&open), (unsigned long long)atomic_load(&reads));
    CHECK(atomic_load(&open) == 0, "a reader never sees the function unspecialized while it is loaded again");

    // An entry point noted only with no values (tf_fn, mesh_obj, never through fn_spec): an empty set, on the Metal 4 path and for an MTLDevice pipeline
    id<MTLFunction> f3 = fn4_note([L newFunctionWithName:@"cfs3"], L, @"cfs3", nil);
    CHECK(is_spec(f3), "a function with constants noted with no values gets a specialized descriptor");
    if (is_spec(f3)) CHECK(draw_one(pso_build(desc(vs, f3), &pe)) == 0.25f, "its Metal 4 pipeline draws with the constant at its default");
    id<MTLFunction> d3 = fn_dev(f3);
    CHECK(d3 && d3 != f3 && !d3.functionConstantsDictionary.count, "fn_dev specializes it for an MTLDevice pipeline");
    CHECK(fn_dev(f3) == d3, "once");
    if (d3 && d3 != f3) CHECK(draw_one(pso_build_dev(desc(vs, f3), &pe)) == 0.25f, "and that pipeline draws with the constant at its default");

    // A second request for the name with other values (nf_fn's variant for R11G11B10F targets): a function of its own; both requests' pipelines draw with their own values
    id<MTLFunction> f4 = fn_spec(L, @"cfs4", none, &err);
    id<MTLFunction> v4 = fn_spec_k(L, @"cfs4", three, 2, &err);
    CHECK(v4 && v4 != f4, "the variant is a function of its own");
    CHECK(is_spec(f4) && is_spec(v4), "both have specialized descriptors");
    uint64_t built0 = g_pb_built;
    float base_px = draw_one(pso_build(desc(vs, f4), &pe));
    if (base_px != 0.25f) fprintf(stderr, "the first request's pipeline drew %f\n", base_px);
    CHECK(base_px == 0.25f, "the first request's pipeline keeps its values (the constant at its default)");
    float var_px = draw_one(pso_build(desc(vs, v4), &pe));
    if (var_px != 3.0f) fprintf(stderr, "the variant's pipeline drew %f\n", var_px);
    CHECK(var_px == 3.0f, "the variant's pipeline draws with its values (k = 3)");
    CHECK(g_pb_built == built0 + 2, "each with a base of its own");
    CHECK(fn_spec_k(L, @"cfs4", none, 0, &err) == f4, "a request with the first one's values shares its function");
    CHECK(draw_one(pso_build(desc(vs, f4), &pe)) == 0.25f, "whose pipelines still draw with them");
    printf("t_spec_mtl4: %d checks, %d failed\n", checks, failed);
    return failed != 0;
} }
