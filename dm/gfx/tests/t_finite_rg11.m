// A non-finite colour output stored to an R11G11B10F target (dmsh_rewrite.py finite_rg11, from test_dmsh_finite_rg11.py --fixture; make check_t_finite_rg11). The shader divides 1 by an
// exact 0, writes a NaN it reads and 2.0 to blue, as Ocarina of Time's ground mist does (issue #1839). With the function constant dm_nf_fc (DMSH_FINITE_FC) set to 1, as nvn_mtl.m nf_fn does for
// a pipeline with an R11G11B10F target 0, the target must hold 0, 0 and 2: Maxwell stores a non-finite value there as black. With it unset the pipeline keeps Metal's own result (printed), and an RGBA16F target keeps the infinity and the NaN with the constant unset. Fails when the constant leaves the sanitized value non-zero or touches a finite one.
#import <Metal/Metal.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int fails;
#define CHECK(c, ...) do { if (!(c)) { fails++; printf("FAIL: " __VA_ARGS__); printf("\n"); } } while (0)
enum { FC = 230 };

static const char *VS = "struct V { float4 p [[position]]; };\n"
    "vertex V vs(uint i [[vertex_id]]) { float2 q[3] = {float2(-1, -1), float2(3, -1), float2(-1, 3)}; V o; o.p = float4(q[i], 0, 1); return o; }\n";

static void draw(id<MTLDevice> dev, id<MTLCommandQueue> q, id<MTLLibrary> lib, MTLPixelFormat fmt, int mask, float *rgba, uint16_t *raw) {
    MTLFunctionConstantValues *cv = [MTLFunctionConstantValues new]; uint32_t m = (uint32_t)mask; NSError *e = nil;
    if (mask >= 0) [cv setConstantValue:&m type:MTLDataTypeUInt atIndex:FC];
    id<MTLFunction> fs = [lib newFunctionWithName:@"main0" constantValues:cv error:&e];
    if (!fs) { printf("FAIL: specialize: %s\n", e.localizedDescription.UTF8String); exit(1); }
    MTLRenderPipelineDescriptor *d = [MTLRenderPipelineDescriptor new];
    d.vertexFunction = [lib newFunctionWithName:@"vs"]; d.fragmentFunction = fs; d.colorAttachments[0].pixelFormat = fmt;
    d.colorAttachments[1].pixelFormat = MTLPixelFormatRGBA16Float; d.colorAttachments[2].pixelFormat = MTLPixelFormatRGBA32Uint; d.colorAttachments[3].pixelFormat = MTLPixelFormatRGBA32Float;
    id<MTLRenderPipelineState> p = [dev newRenderPipelineStateWithDescriptor:d error:&e];
    if (!p) { printf("FAIL: pipeline: %s\n", e.localizedDescription.UTF8String); exit(1); }
    MTLPixelFormat fm[4] = {fmt, MTLPixelFormatRGBA16Float, MTLPixelFormatRGBA32Uint, MTLPixelFormatRGBA32Float};
    id<MTLTexture> t[4]; MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor new];
    for (int i = 0; i < 4; i++) {
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:fm[i] width:4 height:4 mipmapped:NO];
        td.usage = MTLTextureUsageRenderTarget; td.storageMode = MTLStorageModeShared; t[i] = [dev newTextureWithDescriptor:td];
        rp.colorAttachments[i].texture = t[i]; rp.colorAttachments[i].loadAction = MTLLoadActionClear; rp.colorAttachments[i].storeAction = MTLStoreActionStore;
    }
    float c[4] = {0, NAN, 0, 0};   // c[0].x = 0 (the weight sum), c[0].y = NaN, c[0].w = 0 (no early return)
    id<MTLCommandBuffer> cb = [q commandBuffer]; id<MTLRenderCommandEncoder> en = [cb renderCommandEncoderWithDescriptor:rp];
    [en setRenderPipelineState:p]; [en setFragmentBytes:c length:sizeof c atIndex:0]; [en drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3]; [en endEncoding];
    [cb commit]; [cb waitUntilCompleted];
    if (fmt == MTLPixelFormatRG11B10Float) {
        uint32_t w; [t[0] getBytes:&w bytesPerRow:16 fromRegion:MTLRegionMake2D(1, 1, 1, 1) mipmapLevel:0];
        // the format's own decode: R 5-bit exponent + 6-bit mantissa, G likewise, B 5 + 5
        uint32_t r = w & 0x7ff, g = w >> 11 & 0x7ff, b = w >> 22;
        float v[3]; uint32_t f[3] = {r, g, b}; int mb[3] = {6, 6, 5};
        for (int i = 0; i < 3; i++) { uint32_t ex = f[i] >> mb[i], mn = f[i] & ((1u << mb[i]) - 1); v[i] = ex == 0 ? ldexpf((float)mn / (1 << mb[i]), -14) : ex == 31 ? (mn ? NAN : INFINITY) : ldexpf(1.0f + (float)mn / (1 << mb[i]), (int)ex - 15); }
        rgba[0] = v[0]; rgba[1] = v[1]; rgba[2] = v[2]; rgba[3] = 1;
    } else {
        [t[0] getBytes:raw bytesPerRow:32 fromRegion:MTLRegionMake2D(1, 1, 1, 1) mipmapLevel:0];
        for (int i = 0; i < 4; i++) { uint16_t h = raw[i]; int ex = h >> 10 & 31, mn = h & 1023; rgba[i] = ex == 31 ? (mn ? NAN : INFINITY) : ex == 0 ? ldexpf(mn / 1024.0f, -14) : ldexpf(1 + mn / 1024.0f, ex - 15); }
    }
}

int main(int argc, char **argv) { @autoreleasepool {
    if (argc != 2) { fprintf(stderr, "usage: t_finite_rg11 <dir with finite.metal>\n"); return 2; }
    NSString *body = [NSString stringWithContentsOfFile:[@(argv[1]) stringByAppendingPathComponent:@"finite.metal"] encoding:NSUTF8StringEncoding error:nil];
    if (!body) { fprintf(stderr, "no finite.metal in %s\n", argv[1]); return 2; }
    id<MTLDevice> dev = MTLCreateSystemDefaultDevice(); NSError *e = nil;
    NSString *src = [NSString stringWithFormat:@"#include <metal_stdlib>\n%@\n%s", body, VS];   // finite.metal opens with `using namespace metal;`
    MTLCompileOptions *co = [MTLCompileOptions new];   // fast math on, as the chain compiles
    id<MTLLibrary> lib = [dev newLibraryWithSource:src options:co error:&e];
    if (!lib) { printf("FAIL: compile: %s\n", e.localizedDescription.UTF8String); return 1; }
    id<MTLCommandQueue> q = [dev newCommandQueue];
    float v[4]; uint16_t raw[4];
    draw(dev, q, lib, MTLPixelFormatRG11B10Float, 1, v, raw);
    printf("R11G11B10F, constant 1 (output 0 sanitized): %g %g %g\n", v[0], v[1], v[2]);
    CHECK(v[0] == 0 && v[1] == 0, "a non-finite value was stored as %g, %g; Maxwell stores 0", v[0], v[1]);
    CHECK(v[2] == 2, "the finite blue 2.0 was stored as %g", v[2]);
    draw(dev, q, lib, MTLPixelFormatRG11B10Float, -1, v, raw);
    printf("R11G11B10F, constant unset (Metal's own result): %g %g %g\n", v[0], v[1], v[2]);
    CHECK(v[2] == 2, "unset: the finite blue was stored as %g", v[2]);
    draw(dev, q, lib, MTLPixelFormatRG11B10Float, 0, v, raw);
    CHECK(v[2] == 2, "constant 0: the finite blue was stored as %g", v[2]);
    draw(dev, q, lib, MTLPixelFormatRGBA16Float, -1, v, raw);
    printf("RGBA16F, constant unset: %g %g %g\n", v[0], v[1], v[2]);
    CHECK(isinf(v[0]) && isnan(v[1]) && v[2] == 2, "RGBA16F must keep the infinity and the NaN: %g %g %g", v[0], v[1], v[2]);
    printf(fails ? "t_finite_rg11: %d failed\n" : "t_finite_rg11: ok\n", fails);
    return fails != 0;
} }
