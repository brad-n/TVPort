// Function specialization on the MTLDevice pipeline path (DM_PSO_MTL4=0, iOS and tvOS without the profile's pso_mtl4): a function with constants stays unspecialized when its shader
// loads (fn_spec) and is specialized the first time an MTLDevice pipeline is built from it (fn_dev, DM_NVN_SPEC_LAZY on by default), so the thousands of shaders the prewarm loads
// and no pipeline uses keep no specialized module in memory (131 MB of malloc in Ocarina of Time on the Apple TV path). Checks: loading specializes nothing; a pipeline built from the
// loaded functions draws with the constants the loader gave (a true constant and its default), each function specialized once however many pipelines use it; a second request for a
// name the library already handed out (one object per name: nf_fn's variants) is specialized at once, a function of its own, and leaves the first one's constants alone, while one with
// the same values shares the first one's function; the geometry capture
// pipeline (geo_capture_pso), which builds its own MTLDevice pipeline, gets the capture entry specialized; a function noted again with no values (Metal's one library for one shader's data,
// loaded twice) still gets the values it was loaded with; with DM_NVN_SPEC_LAZY=0 loading specializes at once, as before
#include "../nvn/nvn_mtl.m"
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t *g_mod; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int checks, failed;
#define CHECK(c, label) do { checks++; if (!(c)) { failed++; fprintf(stderr, "FAIL: %s (line %d)\n", label, __LINE__); } } while (0)

static unsigned g_specs;   // specializations through a library (counted by SpecLibrary)
@interface SpecLibrary : NSObject { @public id<MTLLibrary> library; } @end
@implementation SpecLibrary
- (id)forwardingTargetForSelector:(SEL)selector { return library; }
- (id<MTLFunction>)newFunctionWithName:(NSString *)entry constantValues:(MTLFunctionConstantValues *)values error:(NSError **)error {
    g_specs++; return [library newFunctionWithName:entry constantValues:values error:error];
}
@end
// One pixel drawn by a pipeline of vertex function v and fragment function f into an R32Float target: its value
static float draw_one(id<MTLCommandQueue> q, id<MTLRenderPipelineState> ps) {
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR32Float width:1 height:1 mipmapped:NO];
    td.usage = MTLTextureUsageRenderTarget; td.storageMode = MTLStorageModeShared;
    id<MTLTexture> t = [g_dev newTextureWithDescriptor:td];
    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor new]; rp.colorAttachments[0].texture = t; rp.colorAttachments[0].loadAction = MTLLoadActionClear;
    rp.colorAttachments[0].clearColor = MTLClearColorMake(-1, 0, 0, 0); rp.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLCommandBuffer> cb = [q commandBuffer]; id<MTLRenderCommandEncoder> e = [cb renderCommandEncoderWithDescriptor:rp];
    [e setRenderPipelineState:ps]; [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3]; [e endEncoding];
    [cb commit]; [cb waitUntilCompleted];
    float v = -2; [t getBytes:&v bytesPerRow:4 fromRegion:MTLRegionMake2D(0, 0, 1, 1) mipmapLevel:0]; return v;
}
int main(void) { @autoreleasepool {
    setenv("DM_PSO_MTL4", "0", 1);   // the Apple TV's path: every pipeline through the MTLDevice
    mtl_init(); id<MTLCommandQueue> q = [g_dev newCommandQueue];
    CHECK(!pso4_compiler(), "DM_PSO_MTL4=0: no Metal 4 compiler");
    int lazy = !(getenv("DM_NVN_SPEC_LAZY") && !strcmp(getenv("DM_NVN_SPEC_LAZY"), "0"));
    CHECK(spec_lazy() == lazy, "the switch: on unless DM_NVN_SPEC_LAZY=0");
    NSError *err = nil;
    id<MTLLibrary> real = [g_dev newLibraryWithSource:@"#include <metal_stdlib>\nusing namespace metal;\nconstant bool k [[function_constant(0)]];\n"
        "struct V { float4 p [[position]]; };\nvertex V cvs(uint i [[vertex_id]]) { V o; float2 uv = float2((i << 1) & 2, i & 2); o.p = float4(uv * 2 - 1, is_function_constant_defined(k) && k ? 0.5 : 0.0, 1); return o; }\n"
        "fragment float4 cfs() { return float4(is_function_constant_defined(k) ? (k ? 1.0 : 0.5) : 0.25, 0, 0, 1); }\n"
        "fragment float4 cfs2() { return float4(is_function_constant_defined(k) ? (k ? 1.0 : 0.5) : 0.25, 0, 0, 1); }\n"
        "fragment float4 cfs3() { return float4(is_function_constant_defined(k) ? (k ? 1.0 : 0.5) : 0.25, 0, 0, 1); }\n"
        "vertex void cap(uint i [[vertex_id]], device float *o [[buffer(0)]]) { o[i] = is_function_constant_defined(k) ? 1.0 : 0.0; }\n" options:nil error:&err];
    if (!real) { fprintf(stderr, "library: %s\n", err.localizedDescription.UTF8String); return 1; }
    SpecLibrary *lib = [SpecLibrary new]; lib->library = real;
    MTLFunctionConstantValues *on = [MTLFunctionConstantValues new]; bool t = true; [on setConstantValue:&t type:MTLDataTypeBool atIndex:0];
    id<MTLLibrary> L = (id<MTLLibrary>)lib;
    id<MTLFunction> vs = fn_spec(L, @"cvs", [MTLFunctionConstantValues new], &err), fs_on = fn_spec_k(L, @"cfs", on, 2, &err), fs_def = fn_spec(L, @"cfs2", [MTLFunctionConstantValues new], &err);
    id<MTLFunction> cap = fn_spec(L, @"cap", [MTLFunctionConstantValues new], &err);
    CHECK(vs && fs_on && fs_def && cap, "the functions load");
    if (lazy) CHECK(g_specs == 0, "loading specializes nothing");
    else CHECK(g_specs == 4, "with DM_NVN_SPEC_LAZY=0 loading specializes each function at once");
    MTLRenderPipelineDescriptor *d = [MTLRenderPipelineDescriptor new]; d.vertexFunction = vs; d.fragmentFunction = fs_on; d.colorAttachments[0].pixelFormat = MTLPixelFormatR32Float;
    uint64_t legacy0 = g_pb_legacy; NSError *pe = nil;
    id<MTLRenderPipelineState> p_on = pso_build(d, &pe);
    CHECK(p_on != nil, "a pipeline is built from the loaded functions");
    CHECK(g_pb_legacy == legacy0 + 1, "through the MTLDevice");
    float v_on = p_on ? draw_one(q, p_on) : -3; if (v_on != 1.0f) fprintf(stderr, "drew %f\n", v_on);
    CHECK(v_on == 1.0f, "it draws with the constant the loader gave (k = true)");
    unsigned after_one = g_specs;
    if (lazy && after_one != 2) fprintf(stderr, "specializations after one pipeline: %u\n", after_one);
    if (lazy) CHECK(after_one == 2, "the pipeline specialized its two functions");
    d.fragmentFunction = fs_def; id<MTLRenderPipelineState> p_def = pso_build(d, &pe);
    CHECK(p_def && draw_one(q, p_def) == 0.25f, "a function loaded with no values keeps the constant undefined");
    if (lazy) CHECK(g_specs == after_one + 1, "the vertex function is specialized once for both pipelines");
    d.fragmentFunction = fs_on; id<MTLRenderPipelineState> p_again = pso_build(d, &pe);
    CHECK(p_again != nil, "the same pipeline again");
    if (lazy) CHECK(g_specs == after_one + 1, "and nothing specialized again");
    // the same name again with other values (nf_fn asks so for its variants): the library hands out its one object for the name, which carries the first request's note
    MTLFunctionConstantValues *off = [MTLFunctionConstantValues new]; bool fl = false; [off setConstantValue:&fl type:MTLDataTypeBool atIndex:0];
    unsigned before_off = g_specs; id<MTLFunction> fs_off = fn_spec_k(L, @"cfs", off, 1, &err);
    CHECK(fs_off && fs_off != fs_on, "a second request for the name is a function of its own");
    if (lazy) CHECK(g_specs == before_off + 1, "specialized at once");
    d.fragmentFunction = fs_off; id<MTLRenderPipelineState> p_off = pso_build(d, &pe);
    CHECK(p_off && draw_one(q, p_off) == 0.5f, "it draws with its own values (k = false)");
    d.fragmentFunction = fs_on; id<MTLRenderPipelineState> p_on2 = pso_build(d, &pe);
    CHECK(p_on2 && draw_one(q, p_on2) == 1.0f, "and the first request keeps its values");
    // the same name with the same values again (a shader loaded a second time over Metal's one library for its data): the first request's function, nothing specialized
    unsigned before_same = g_specs; id<MTLFunction> fs_same = fn_spec_k(L, @"cfs", on, 2, &err);
    if (lazy) CHECK(fs_same == fs_on && g_specs == before_same, "a second request with the same values shares the first one's function");
    // the same function object noted again with no values (a shader loaded a second time gets Metal's same library, and the loader notes each entry before it specializes it):
    // the pipeline still takes what the first request asked
    id<MTLFunction> fs3 = fn_spec_k(L, @"cfs3", on, 2, &err); fn4_note([L newFunctionWithName:@"cfs3"], L, @"cfs3", nil);
    d.fragmentFunction = fs3; id<MTLRenderPipelineState> p3 = pso_build(d, &pe);
    CHECK(p3 && draw_one(q, p3) == 1.0f, "a function noted again keeps the values it was loaded with");
    // the geometry capture pipeline builds its own MTLDevice pipeline from the vertex shader's capture entry
    NvShader *v = [NvShader new]; v->stage = 0; v->fn = vs; v->geo_fn = cap; strlcpy(v->key, "00000000000000ab_b", sizeof v->key);
    unsigned before_cap = g_specs;
    id<MTLRenderPipelineState> pc = geo_capture_pso(v);
    CHECK(pc != nil, "the geometry capture pipeline is built from a loaded capture entry");
    if (lazy) CHECK(g_specs == before_cap + 1, "its capture entry specialized for it");
    printf("t_spec_lazy (%s): %d checks, %d failed\n", lazy ? "lazy" : "DM_NVN_SPEC_LAZY=0", checks, failed);
    return failed != 0;
} }
