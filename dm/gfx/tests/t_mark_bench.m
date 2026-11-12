// GPU cost of a shader's per-pixel marks on a bitmap word (dmsh_build.py POOL_MARK, the raw memory read log's test in GlobalToStorage), on this machine's GPU.
// Prints numbers, not a test (like t_astc_bench). A full-screen pass, or a dispatch of one thread a pixel, where every pixel makes <marks> marks on IDs <stride> apart
// (stride 1: all of a pixel's IDs in one word, as a pass that reads a few textures; the bits set before the pass, as after the first frame), in four forms:
//   none     no mark (the index alone)
//   atomic   test with atomic_load_explicit, OR if clear (the pool mark of chains before upstream 04811a63, the Apple TV library f29dec7af2c1)
//   plain    test with a plain load, OR if clear (the pool mark now, and the read and write logs since they exist)
//   always   an unconditional atomic OR (what an untested log would cost)
// Usage: make t_mark_bench && ./t_mark_bench [width height marks stride reps]   (default 960 540 8 1 40); median GPU ms of reps command buffers each
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <stdio.h>
#include <stdlib.h>

static const char *SRC =
    "#include <metal_stdlib>\nusing namespace metal;\n"
    "constant int MODE [[function_constant(0)]]; constant int MARKS [[function_constant(1)]]; constant int STRIDE [[function_constant(2)]];\n"
    "static inline uint mark(device uint *seen, uint i) {\n"
    "    uint b = 1u << (i & 31u);\n"
    "    if (MODE == 1) { device atomic_uint *w = (device atomic_uint *)seen + (i >> 5); if (!(atomic_load_explicit(w, memory_order_relaxed) & b)) atomic_fetch_or_explicit(w, b, memory_order_relaxed); }\n"
    "    else if (MODE == 2) { device uint *w = seen + (i >> 5); if (!(*w & b)) atomic_fetch_or_explicit((device atomic_uint *)w, b, memory_order_relaxed); }\n"
    "    else if (MODE == 3) atomic_fetch_or_explicit((device atomic_uint *)seen + (i >> 5), b, memory_order_relaxed);\n"
    "    return i;\n}\n"
    "static inline float marks(device uint *seen, constant uint *ids, uint salt, uint px) { float acc = 0; for (int k = 0; k < MARKS; k++) acc += float(mark(seen, ids[k] + salt) & 3u) * float(px & 7u); return acc; }\n"
    "struct V { float4 p [[position]]; };\n"
    "vertex V vs(uint id [[vertex_id]]) { float2 uv = float2((id << 1) & 2, id & 2); V o; o.p = float4(uv * 2.0 - 1.0, 0, 1); return o; }\n"
    "[[early_fragment_tests]] fragment float4 fs(V in [[stage_in]], device uint *seen [[buffer(0)]], constant uint &salt [[buffer(1)]], constant uint *ids [[buffer(2)]]) {\n"
    "    return float4(marks(seen, ids, salt, uint(in.p.x)) * 1e-3, in.p.y * 1e-4, 0, 1); }\n"
    "kernel void cs(uint2 g [[thread_position_in_grid]], device uint *seen [[buffer(0)]], constant uint &salt [[buffer(1)]], constant uint *ids [[buffer(2)]], texture2d<float, access::write> o [[texture(0)]]) {\n"
    "    o.write(float4(marks(seen, ids, salt, g.x) * 1e-3, 0, 0, 1), g); }\n";

static double median(double *v, int n) { for (int i = 1; i < n; i++) for (int j = i; j && v[j - 1] > v[j]; j--) { double t = v[j]; v[j] = v[j - 1]; v[j - 1] = t; } return v[n / 2]; }

int main(int argc, const char **argv) { @autoreleasepool {
    int W = argc > 1 ? atoi(argv[1]) : 960, H = argc > 2 ? atoi(argv[2]) : 540, M = argc > 3 ? atoi(argv[3]) : 8, S = argc > 4 ? atoi(argv[4]) : 1, R = argc > 5 ? atoi(argv[5]) : 40;
    id<MTLDevice> dev = MTLCreateSystemDefaultDevice(); NSError *e = nil;
    id<MTLLibrary> lib = [dev newLibraryWithSource:@(SRC) options:nil error:&e]; if (!lib) { printf("%s\n", e.description.UTF8String); return 2; }
    id<MTLCommandQueue> q = [dev newCommandQueue];
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:W height:H mipmapped:NO];
    td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderWrite; td.storageMode = MTLStorageModePrivate;
    id<MTLTexture> rt = [dev newTextureWithDescriptor:td];
    id<MTLBuffer> seen = [dev newBufferWithLength:(1 << 16) / 8 options:MTLResourceStorageModeShared];
    uint32_t ids[64]; for (int k = 0; k < 64; k++) ids[k] = (uint32_t)(k * S);   // the IDs from a buffer, as a shader reads its texture handles: the compiler cannot merge the marks
    static const char *NAME[] = {"none", "atomic", "plain", "always"};
    printf("%s, %dx%d, %d marks a pixel %d IDs apart (%d bitmap words), median of %d\n", dev.name.UTF8String, W, H, M, S, (M * S + 31) / 32, R);
    for (int stage = 0; stage < 2; stage++) for (int warm = 0; warm < 2; warm++) {
        printf("  %-8s %-5s", stage ? "compute" : "fragment", warm ? "set" : "clear");
        for (int mode = 0; mode < 4; mode++) {
            MTLFunctionConstantValues *fc = [MTLFunctionConstantValues new];
            [fc setConstantValue:&mode type:MTLDataTypeInt atIndex:0]; [fc setConstantValue:&M type:MTLDataTypeInt atIndex:1]; [fc setConstantValue:&S type:MTLDataTypeInt atIndex:2];
            id<MTLRenderPipelineState> rp = nil; id<MTLComputePipelineState> cp = nil;
            if (stage) cp = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"cs" constantValues:fc error:&e] error:&e];
            else {
                MTLRenderPipelineDescriptor *d = [MTLRenderPipelineDescriptor new];
                d.vertexFunction = [lib newFunctionWithName:@"vs"]; d.fragmentFunction = [lib newFunctionWithName:@"fs" constantValues:fc error:&e];
                d.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm; rp = [dev newRenderPipelineStateWithDescriptor:d error:&e];
            }
            if (!rp && !cp) { printf("%s\n", e.description.UTF8String); return 2; }
            double t[256]; int n = R < 256 ? R : 256;
            for (int r = -3; r < n; r++) {
                memset(seen.contents, warm ? 0xff : 0, seen.length);   // set: every bit already set (the steady state); clear: each pass sets its bits first
                uint32_t salt = (uint32_t)(r & 7) * 4096u;   // IDs below 2^15 + 2^14: inside the 8 KB bitmap
                id<MTLCommandBuffer> cb = [q commandBuffer];
                if (stage) {
                    id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder]; [ce setComputePipelineState:cp];
                    [ce setBuffer:seen offset:0 atIndex:0]; [ce setBytes:&salt length:4 atIndex:1]; [ce setBytes:ids length:sizeof ids atIndex:2]; [ce setTexture:rt atIndex:0];
                    [ce dispatchThreads:MTLSizeMake(W, H, 1) threadsPerThreadgroup:MTLSizeMake(16, 16, 1)]; [ce endEncoding];
                } else {
                    MTLRenderPassDescriptor *pd = [MTLRenderPassDescriptor renderPassDescriptor];
                    pd.colorAttachments[0].texture = rt; pd.colorAttachments[0].loadAction = MTLLoadActionDontCare; pd.colorAttachments[0].storeAction = MTLStoreActionStore;
                    id<MTLRenderCommandEncoder> re = [cb renderCommandEncoderWithDescriptor:pd]; [re setRenderPipelineState:rp];
                    [re setFragmentBuffer:seen offset:0 atIndex:0]; [re setFragmentBytes:&salt length:4 atIndex:1]; [re setFragmentBytes:ids length:sizeof ids atIndex:2];
                    [re drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3]; [re endEncoding];
                }
                [cb commit]; [cb waitUntilCompleted];
                if (r >= 0) t[r] = (cb.GPUEndTime - cb.GPUStartTime) * 1e3;
            }
            printf("  %s %6.3f", NAME[mode], median(t, n));
        }
        printf("  ms\n");
    }
    return 0;
} }
