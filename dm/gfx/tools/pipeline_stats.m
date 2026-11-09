// Pipeline statistics of translated shaders, as Xcode's Pipeline Statistics shows them: temporary (per-thread) registers, spilled bytes, uniform registers and the instruction mix,
// read from the pipeline reflection's performanceStatistics, which Metal fills when the pipeline is made with option bit 18 (private, undocumented; macOS 27 on an M2 Pro). A tool for
// people, not part of the host. On Apple GPUs before Apple9 a SIMD group keeps its peak registers for its whole life, so a shader at 128 registers with a spill runs at the lowest
// occupancy: Ocarina of Time's lit model pixel shaders (1e4d2630d24846d0: 128 registers, 208 B spilled) and its raw-lookup shaders (eac11c8140d0b809: 128, 656 B).
// Build: clang -fobjc-arc -framework Metal -framework Foundation dm/gfx/tools/pipeline_stats.m -o /tmp/pipeline_stats
// Usage: pipeline_stats <spec>...   (one line per stage: spec, stage, then name=value; PIPELINE_STATS_REMARKS=1 also prints the register allocator's remarks)
//   c:<metallib>                             compute function main0
//   f:<metallib>:<msl>                       pixel function main0, after a generated vertex function writing the inputs main0_in of its MSL declares (<key>_b.metal beside the library)
//   m:<task metallib|->:<mesh metallib>:<pixel metallib|->   a mesh pipeline: object main0 of the task library (or main0_o of the mesh library), mesh main0, pixel main0 (or an empty one);
//                                            Metal reports the pixel stage only
// Functions with function constants are specialized with no values, as the host does. A library of one file (b-<chain>.img) needs its files first: dm/tools/shader_lib.py cat.
#import <Metal/Metal.h>
#include <stdio.h>
#include <stdlib.h>
static NSArray *keys;
static void show(const char *spec, const char *stage, NSDictionary *d) {
    printf("%s\t%s", spec, stage);
    for (NSString *k in keys) { id v = d[k]; printf("\t%s=%s", k.UTF8String, v ? [v description].UTF8String : "-"); }
    printf("\n");
    if (getenv("PIPELINE_STATS_REMARKS")) printf("%s\n", [[d[@"Remarks"] description] UTF8String]);
}
static void walk(const char *spec, id st) {
    if (![st isKindOfClass:NSDictionary.class]) { printf("%s\t-\tno statistics (this Metal does not fill them)\n", spec); return; }
    NSDictionary *d = st;
    if (d[@"Temporary register count"]) { show(spec, "all", d); return; }
    for (NSString *k in d) if ([d[k] isKindOfClass:NSDictionary.class] && d[k][@"Temporary register count"]) show(spec, k.UTF8String, d[k]);
}
static id<MTLFunction> fn(id<MTLLibrary> l, NSString *n) {
    id<MTLFunction> f = [l newFunctionWithName:n]; if (!f || !f.functionConstantsDictionary.count) return f;
    NSError *e = nil; return [l newFunctionWithName:n constantValues:[MTLFunctionConstantValues new] error:&e];
}
int main(int argc, char **argv) { @autoreleasepool {
    keys = @[@"Temporary register count", @"Spilled bytes", @"Uniform register count", @"Instruction count", @"ALU instruction count", @"FP16 instruction count", @"FP32 instruction count",
             @"Device load instruction count", @"Texture reads instruction count", @"Wait instruction count", @"Threadgroup memory"];
    id<MTLDevice> dev = MTLCreateSystemDefaultDevice(); MTLPipelineOption opt = (MTLPipelineOption)(1ull << 18);
    for (int i = 1; i < argc; i++) {
        NSArray *p = [@(argv[i]) componentsSeparatedByString:@":"]; NSError *e = nil;
        id<MTLLibrary> (^lib)(NSString *) = ^id<MTLLibrary>(NSString *path) { NSError *er = nil; id<MTLLibrary> l = [dev newLibraryWithURL:[NSURL fileURLWithPath:path] error:&er];
            if (!l) printf("%s\t-\tcannot load %s: %s\n", argv[i], path.UTF8String, er.localizedDescription.UTF8String); return l; };
        id ps = nil; id refl = nil;
        if ([p[0] isEqual:@"c"] && p.count == 2) {
            id<MTLFunction> f = fn(lib(p[1]), @"main0"); if (!f) continue;
            MTLAutoreleasedComputePipelineReflection r = nil; ps = [dev newComputePipelineStateWithFunction:f options:opt reflection:&r error:&e]; refl = r;
        } else if ([p[0] isEqual:@"f"] && p.count == 3) {
            id<MTLFunction> ff = fn(lib(p[1]), @"main0"); if (!ff) continue;
            NSString *msl = [NSString stringWithContentsOfFile:p[2] encoding:NSUTF8StringEncoding error:nil]; NSString *body = @"";
            NSRange a = [msl rangeOfString:@"struct main0_in\n{\n"];
            if (a.location != NSNotFound) { NSRange b = [msl rangeOfString:@"};" options:0 range:NSMakeRange(a.location, msl.length - a.location)]; body = [msl substringWithRange:NSMakeRange(a.location + a.length, b.location - a.location - a.length)]; }
            NSString *vs = [NSString stringWithFormat:@"#include <metal_stdlib>\nusing namespace metal;\nstruct VO {\n float4 dm_pos [[position]];\n%@};\nvertex VO dm_vs(uint vid [[vertex_id]]) { VO o = {}; o.dm_pos = float4(float(vid & 1), float(vid >> 1), 0, 1); return o; }\n", body];
            id<MTLLibrary> vl = [dev newLibraryWithSource:vs options:nil error:&e]; if (!vl) { printf("%s\t-\tvertex stub failed: %s\n", argv[i], e.localizedDescription.UTF8String); continue; }
            MTLRenderPipelineDescriptor *d = [MTLRenderPipelineDescriptor new]; d.vertexFunction = [vl newFunctionWithName:@"dm_vs"]; d.fragmentFunction = ff;
            for (int c = 0; c < 8; c++) { NSRange q = [msl rangeOfString:[NSString stringWithFormat:@"[[color(%d)]]", c]]; if (q.location == NSNotFound || q.location < 40) continue;
                NSString *pre = [msl substringWithRange:NSMakeRange(q.location - 40, 40)];
                d.colorAttachments[c].pixelFormat = [pre containsString:@"uint4"] ? MTLPixelFormatRGBA32Uint : [pre containsString:@"int4"] ? MTLPixelFormatRGBA32Sint : MTLPixelFormatRGBA16Float; }
            if ([msl rangeOfString:@"[[depth("].location != NSNotFound) d.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;
            MTLAutoreleasedRenderPipelineReflection r = nil; ps = [dev newRenderPipelineStateWithDescriptor:d options:opt reflection:&r error:&e]; refl = r;
        } else if ([p[0] isEqual:@"m"] && p.count >= 4) {
            id<MTLLibrary> ml = lib(p[2]); id<MTLFunction> mf = fn(ml, @"main0"), of = nil, ff = nil;
            of = [p[1] isEqual:@"-"] ? fn(ml, @"main0_o") : fn(lib(p[1]), @"main0");
            if (![p[3] isEqual:@"-"]) ff = fn(lib(p[3]), @"main0");
            if (!ff) ff = [[dev newLibraryWithSource:@"fragment void dm_nop() {}" options:nil error:&e] newFunctionWithName:@"dm_nop"];
            if (!mf || !of) { printf("%s\t-\tno mesh / object function\n", argv[i]); continue; }
            MTLMeshRenderPipelineDescriptor *d = [MTLMeshRenderPipelineDescriptor new]; d.objectFunction = of; d.meshFunction = mf; d.fragmentFunction = ff;
            d.payloadMemoryLength = [p[1] isEqual:@"-"] ? 16 : 256; d.maxTotalThreadsPerObjectThreadgroup = [p[1] isEqual:@"-"] ? 1 : 32; d.maxTotalThreadsPerMeshThreadgroup = 32;
            for (int c = 0; c < 4; c++) d.colorAttachments[c].pixelFormat = MTLPixelFormatRGBA16Float;
            d.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;
            MTLAutoreleasedRenderPipelineReflection r = nil; ps = [dev newRenderPipelineStateWithMeshDescriptor:d options:opt reflection:&r error:&e]; refl = r;
        } else { printf("%s\t-\tunknown spec (c:<lib>, f:<lib>:<msl>, m:<task|->:<mesh>:<pixel|->)\n", argv[i]); continue; }
        if (!ps) { printf("%s\t-\tpipeline failed: %s\n", argv[i], e.localizedDescription.UTF8String); continue; }
        walk(argv[i], [refl respondsToSelector:@selector(performanceStatistics)] ? [refl performSelector:@selector(performanceStatistics)] : nil);
    }
} return 0; }
