// Flat guest GPU address space in Metal: feasibility spike (branch tv-all-flatva-spike). Not a test: it prints numbers, and the Makefile keeps it out of `make run` (NOT_RUN).
// The question: can a shader turn a guest GPU pointer (in nxnative the host pointer of the guest's memory, nvnMemoryPoolGetBufferAddress) into a Metal address with one add or
// one page-table load, instead of the raw pool table's last-entry check, 2 MiB hint and 13-step search (GlobalToStorage.TryGenerateRawStorageOp, nvn_mtl.m gmem_map)?
//
//   t_flatva_bench limits   what Metal allows on this device: placement sparse buffers (largest length per page size, the cost of a mapping update, what an unmapped page reads
//                           and what a write to one does), the GPU addresses of zero-copy, plain, placement-heap and sparse buffers (the CPU pointer? contiguous? at the heap
//                           offset?), a zero-copy buffer over an inaccessible page, whether the residency set wires a zero-copy buffer whole, and whether a shared Metal
//                           buffer's pages can be mapped again at a chosen CPU address
//   t_flatva_bench msl [unroll] [reads]   compile the chase kernels only (no GPU work)
//   t_flatva_bench wire         whether the residency set wires 1 GB of written zero-copy memory whole
//   t_flatva_bench sharedheap   the sparse probe of `limits` with a shared placement heap behind the (private) sparse buffer
//   t_flatva_bench chase    dependent pointer chases through guest memory (default 1.5 GB) cut into zero-copy pools as mtl_pool_add makes them, each access translated:
//       legacy  the raw pool table as the translator emits it without shader_raw_regs (the shaders the frame model measured): last entry's range read from the table, the 2 MiB
//               hint, the 13-step unrolled search, the read log (shader_raw_read_log)
//       regs    the same with shader_raw_regs (the last entry's range in private words), as tv-all builds Ocarina of Time
//       pt      a flat page table: one 64-bit entry per 16 KB guest page, the Metal address of the page with the pool's table slot in the low bits: one load, an and, an or
//       ptlog   pt and the read log by slot, set when the slot changes (what DM_NVN_GMEM_MODE=learned needs)
//       pt2     a two-level page table: a 32-bit block number per 32 MiB of guest addresses (a table small enough to stay cached, for a span of 64 GB or more), then the
//               block's 2,048 page entries as in pt: two dependent loads, the first one always a cache hit
//       flat    one add, base + (va - va0), over one zero-copy buffer spanning every pool (design b)
//       sparse  one add over a placement sparse buffer whose pages come from placement heaps, the arena's bytes copied in (design a)
//     options: --mb 1536 --threads 65536 --steps 64 --unroll 16 --reads 1,4 --modes cross-hot,same-hot,cross-cold --pools mixed|big --hot 4096 --reps 5 --spage 64
//              --variants legacy,regs,pt,ptlog,pt2,flat,sparse
//     modes:  cross-hot   every step to a random one of 4096 nodes spread over all pools: the data stays in cache, the translation is the cost
//             same-hot    16 nodes in one page, then the next group: 15 steps of 16 stay in the pool (the last-entry check hits)
//             cross-cold  every step to a random node of one per 16 KB page of the arena: a GPU TLB miss each step (the 64-byte nodes, ~6 MB, stay in the system cache)
//             dram        every step to a random node of one per 512 bytes of the arena (~180 MB of nodes): a TLB and a DRAM miss each step
//     Each step is one 64-bit load of the next pointer through the vector-load helper, then reads-1 32-bit loads of the node through the scalar helper (each helper keeps its
//     own last entry, as the translator's do); unroll copies of the step are inlined in the loop body, as a shader's lookup sites are.
//
// Measured on the Mac mini M2 Pro (macOS 27.0.1, 2026-11-09):
//   placement sparse buffers are private only (shared is an assertion) but take a shared placement heap; up to 96 GB with 16 KB pages, 363 GB with 64 / 256 KB pages; footprint
//   +1 / +0.25 / +0.06 MB per GB of range; an unmapped page reads 0 and drops writes; mapping updates about 0.03 ms plus 0.03-0.06 us a page. Zero-copy GPU addresses are bump-allocated
//   (not the CPU pointer, 32 KB apart); placement-heap buffers sit at heap base + offset; a zero-copy buffer over a PROT_NONE page is refused; the residency set wired 1 GB of written
//   zero-copy memory whole; mach_vm_remap puts a shared Metal buffer's pages at a chosen CPU address, coherent both ways.
//   chase, ns a load with the data in cache: today's raw table 0.37-0.69 (regs) / 0.49-0.97 (legacy), page table 0.05-0.13, one add 0.02-0.06 (sparse = flat); every access a DRAM
//   miss: all within 8 %.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <mach/mach.h>
#include <mach/mach_vm.h>
#include <mach/mach_error.h>
#include <sys/mman.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

static id<MTLDevice> D; static id<MTLCommandQueue> Q; static id<MTLResidencySet> RS;
static uint64_t now_ns(void) { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW); }
static uint64_t g_rng = 0x9e3779b97f4a7c15ull;
static uint64_t rnd(void) { g_rng ^= g_rng << 13; g_rng ^= g_rng >> 7; g_rng ^= g_rng << 17; return g_rng; }
static double rndf(void) { return (double)(rnd() >> 11) / 9007199254740992.0; }
static int dcmp(const void *a, const void *b) { double x = *(const double *)a, y = *(const double *)b; return x < y ? -1 : x > y; }
static double median(double *v, int n) { qsort(v, (size_t)n, sizeof *v, dcmp); return n & 1 ? v[n / 2] : (v[n / 2 - 1] + v[n / 2]) / 2; }
static double MB(uint64_t b) { return (double)b / 1048576.0; }
static double GB(uint64_t b) { return (double)b / 1073741824.0; }
static uint64_t footprint(void) { task_vm_info_data_t i; mach_msg_type_number_t c = TASK_VM_INFO_COUNT; return task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&i, &c) == KERN_SUCCESS ? i.phys_footprint : 0; }
static uint64_t wired(void) { vm_statistics64_data_t s; mach_msg_type_number_t c = HOST_VM_INFO64_COUNT; host_statistics64(mach_host_self(), HOST_VM_INFO64, (host_info64_t)&s, &c); return (uint64_t)s.wire_count * vm_page_size; }
static void rs_commit(void) { [RS commit]; [RS requestResidency]; }

static id<MTLComputePipelineState> pipeline(NSString *src, const char *fn) {
    NSError *err = nil;
    id<MTLLibrary> lib = [D newLibraryWithSource:src options:[MTLCompileOptions new] error:&err];
    if (!lib) { fprintf(stderr, "compile %s: %s\n", fn, err.localizedDescription.UTF8String); exit(1); }
    id<MTLComputePipelineState> p = [D newComputePipelineStateWithFunction:[lib newFunctionWithName:@(fn)] error:&err];
    if (!p) { fprintf(stderr, "pipeline %s: %s\n", fn, err.localizedDescription.UTF8String); exit(1); }
    return p;
}
static double run(id<MTLComputePipelineState> p, NSUInteger n, NSUInteger tg, NSString *label, void (^bind)(id<MTLComputeCommandEncoder>), NSError **err) {
    id<MTLCommandBuffer> cb = [Q commandBuffer]; cb.label = label;
    id<MTLComputeCommandEncoder> e = [cb computeCommandEncoder]; e.label = label;
    [e setComputePipelineState:p]; bind(e);
    [e dispatchThreads:MTLSizeMake(n, 1, 1) threadsPerThreadgroup:MTLSizeMake(tg, 1, 1)];
    [e endEncoding]; [cb commit]; [cb waitUntilCompleted];
    if (err) *err = cb.error;
    return (cb.GPUEndTime - cb.GPUStartTime) * 1e3;
}
static NSError *blit(id<MTLBuffer> src, uint64_t so, id<MTLBuffer> dst, uint64_t dof, uint64_t len, double *ms) {
    id<MTLCommandBuffer> cb = [Q commandBuffer]; id<MTLBlitCommandEncoder> b = [cb blitCommandEncoder];
    [b copyFromBuffer:src sourceOffset:so toBuffer:dst destinationOffset:dof size:len]; [b endEncoding]; [cb commit]; [cb waitUntilCompleted];
    if (ms) *ms = (cb.GPUEndTime - cb.GPUStartTime) * 1e3;
    return cb.error;
}

static NSString *k_small = @
    "#include <metal_stdlib>\nusing namespace metal;\n"
    "kernel void probe(device uint *out [[buffer(0)]], constant ulong4 &a [[buffer(1)]], uint tid [[thread_position_in_grid]]) {\n"
    "  if (tid) return;\n"
    "  device uint *p0 = reinterpret_cast<device uint *>(a.x), *p1 = reinterpret_cast<device uint *>(a.y), *pu = reinterpret_cast<device uint *>(a.z);\n"
    "  out[0] = *p0; out[1] = *p1; out[2] = *pu;\n"
    "  if (a.w & 1ul) { *pu = 0xdeadbeefu; p0[1] = 0x5555u; }\n"
    "}\n"
    "kernel void poke(device uint *b [[buffer(0)]], constant uint2 &v [[buffer(1)]], uint tid [[thread_position_in_grid]]) { if (!tid) b[v.x] = v.y; }\n";

static const MTLSparsePageSize PSS[3] = {MTLSparsePageSize16, MTLSparsePageSize64, MTLSparsePageSize256};
static const char *PSN[3] = {"16 KB", "64 KB", "256 KB"};
static uint64_t ev_v;
static void q4_sync(id<MTL4CommandQueue> q4, id<MTLSharedEvent> ev) { [q4 signalEvent:ev value:++ev_v]; if (![ev waitUntilSignaledValue:ev_v timeoutMS:20000]) printf("  (event wait timed out)\n"); }
static id<MTLHeap> placement_heap(uint64_t size, MTLStorageMode sm, MTLSparsePageSize ps) {
    MTLHeapDescriptor *hd = [MTLHeapDescriptor new]; hd.type = MTLHeapTypePlacement; hd.storageMode = sm; hd.size = size; hd.maxCompatiblePlacementSparsePageSize = ps;
    return [D newHeapWithDescriptor:hd];
}

// A 16 GB placement sparse buffer with two 64 KB pages mapped from a placement heap: what a kernel reads and writes there and on an unmapped page. hm = the heap's storage mode
// (the buffer is private, the only mode Metal accepts for one); the `sharedheap` command runs it with a shared heap, which the M2 Pro accepted
static void sparse_probe(MTLStorageMode hm, id<MTLComputePipelineState> probe, id<MTL4CommandQueue> q4, id<MTLSharedEvent> ev) {
    printf("\n== a sparse buffer's mapped and unmapped pages, read and written by a kernel through gpuAddress + offset (64 KB pages, %s placement heap)\n", hm == MTLStorageModeShared ? "shared" : "private");
    @autoreleasepool {
        uint64_t tile = 65536;
        id<MTLHeap> h = placement_heap(4 * tile, hm, PSS[1]);
        MTLResourceOptions ro = hm == MTLStorageModeShared ? MTLResourceStorageModeShared : MTLResourceStorageModePrivate;
        id<MTLBuffer> sb = [D newBufferWithLength:16ull << 30 options:MTLResourceStorageModePrivate placementSparsePageSize:PSS[1]];
        printf("heap %s (%s), sparse buffer %s\n", h ? "ok" : "nil", hm == MTLStorageModeShared ? "shared" : "private", sb ? "ok" : "nil");
        id<MTLBuffer> hb = hm == MTLStorageModeShared ? [h newBufferWithLength:4 * tile options:ro offset:0] : nil;
        if (hb) { uint32_t *w = hb.contents; for (uint32_t k = 0; k < 4 * tile / 4; k++) w[k] = 0xA0000000u | k; }
        else if (h) { id<MTLBuffer> st = [D newBufferWithLength:4 * tile options:MTLResourceStorageModeShared]; uint32_t *w = st.contents; for (uint32_t k = 0; k < 4 * tile / 4; k++) w[k] = 0xA0000000u | k;
            hb = [h newBufferWithLength:4 * tile options:ro offset:0]; [RS addAllocation:hb]; [RS addAllocation:st]; rs_commit(); NSError *e = blit(st, 0, hb, 0, 4 * tile, NULL); if (e) printf("fill: %s\n", e.localizedDescription.UTF8String); }
        if (h && sb) {
            MTL4UpdateSparseBufferMappingOperation op2[2] = {{.mode = MTLSparseTextureMappingModeMap, .bufferRange = NSMakeRange(100000, 1), .heapOffset = 0}, {.mode = MTLSparseTextureMappingModeMap, .bufferRange = NSMakeRange(200000, 1), .heapOffset = 1}};
            [q4 updateBufferMappings:sb heap:h operations:op2 count:2]; q4_sync(q4, ev);
            id<MTLBuffer> out = [D newBufferWithLength:64 options:MTLResourceStorageModeShared]; memset(out.contents, 0xcc, 64);
            [RS addAllocation:sb]; [RS addAllocation:h]; [RS addAllocation:out]; rs_commit();
            uint64_t g = sb.gpuAddress; uint64_t a[4] = {g + 100000 * tile + 12, g + 200000 * tile + 20, g + 150000 * tile + 28, 1}, *ap = a;
            NSError *e1 = nil, *e2 = nil;
            run(probe, 1, 1, @"sparse probe 1", ^(id<MTLComputeCommandEncoder> e) { [e setBuffer:out offset:0 atIndex:0]; [e setBytes:ap length:32 atIndex:1]; }, &e1);
            a[3] = 0;
            run(probe, 1, 1, @"sparse probe 2", ^(id<MTLComputeCommandEncoder> e) { [e setBuffer:out offset:16 atIndex:0]; [e setBytes:ap length:32 atIndex:1]; }, &e2);
            uint32_t *o = out.contents;
            printf("gpuAddress %#llx (1 GB aligned: %d); mapped page 100000 word 3: %#x (want 0xa0000003); mapped page 200000 word 5: %#x (want 0xa0004005)\n", (unsigned long long)g, !(g & ((1ull << 30) - 1)), o[0], o[1]);
            printf("unmapped page 150000: read %#x; after the kernel wrote 0xdeadbeef there, the next kernel read %#x; command buffers: %s / %s\n", o[2], o[6],
                e1 ? e1.localizedDescription.UTF8String : "ok", e2 ? e2.localizedDescription.UTF8String : "ok");
            if (hm == MTLStorageModeShared && hb) printf("GPU write through the sparse buffer seen in the heap's own buffer (word 4 = 0x5555): %#x\n", ((uint32_t *)hb.contents)[4]);
            else if (hb) { id<MTLBuffer> rb = [D newBufferWithLength:64 options:MTLResourceStorageModeShared]; [RS addAllocation:rb]; rs_commit(); NSError *e = blit(hb, 0, rb, 0, 64, NULL);
                printf("GPU write through the sparse buffer seen in the heap's own buffer (word 4 = 0x5555): %#x%s\n", ((uint32_t *)rb.contents)[4], e ? " (copy failed)" : ""); [RS removeAllocation:rb]; }
            [RS removeAllocation:sb]; [RS removeAllocation:h]; [RS removeAllocation:out]; rs_commit();
        }
    }

}

static void limits(void) {
    id<MTLComputePipelineState> probe = pipeline(k_small, "probe"), poke = pipeline(k_small, "poke");
    printf("== device\n%s, unified memory %d, maxBufferLength %.2f GB, recommendedMaxWorkingSetSize %.2f GB, RAM %.1f GB, VM page %lu B\n", D.name.UTF8String, D.hasUnifiedMemory,
        GB(D.maxBufferLength), GB(D.recommendedMaxWorkingSetSize), GB(NSProcessInfo.processInfo.physicalMemory), (unsigned long)vm_page_size);
    struct { const char *n; MTLGPUFamily f; } fam[] = {{"Apple7", MTLGPUFamilyApple7}, {"Apple8", MTLGPUFamilyApple8}, {"Apple9", MTLGPUFamilyApple9}, {"Apple10", MTLGPUFamilyApple10}, {"Metal3", MTLGPUFamilyMetal3}, {"Metal4", MTLGPUFamilyMetal4}};
    printf("families:"); for (size_t i = 0; i < sizeof fam / sizeof *fam; i++) printf(" %s=%d", fam[i].n, [D supportsFamily:fam[i].f]); printf("\n");
    printf("supportsPlacementSparse %d; sparseTileSizeInBytes %lu; sparseTileSizeInBytesForSparsePageSize 16/64/256 KB: %lu %lu %lu\n",
        [D respondsToSelector:@selector(supportsPlacementSparse)] ? D.supportsPlacementSparse : -1, (unsigned long)D.sparseTileSizeInBytes,
        (unsigned long)[D sparseTileSizeInBytesForSparsePageSize:PSS[0]], (unsigned long)[D sparseTileSizeInBytesForSparsePageSize:PSS[1]], (unsigned long)[D sparseTileSizeInBytesForSparsePageSize:PSS[2]]);

    printf("\n== placement sparse buffers, newBufferWithLength:options:placementSparsePageSize: (GB:ok|nil(ms to create))\n");
    const double gbs[] = {1, 4, 12.5, 16, 32, 64, 128, 256, 512, 1024};
    // Private only: a shared placement sparse buffer is an assertion in Metal (IOGPUMetalBuffer: "Invalid Storage Mode 0 for Placement Sparse Buffer"), so it has no CPU contents
    const MTLResourceOptions sto[1] = {MTLResourceStorageModePrivate}; const char *ston[1] = {"private"};
    uint64_t maxok[3][1] = {{0}}, minfail[3][1] = {{0}};
    for (int i = 0; i < 3; i++) for (int s = 0; s < 1; s++) @autoreleasepool {
        printf("page %-6s %-7s:", PSN[i], ston[s]);
        uint64_t charged = 0, gpu = 0; int contents = 0; uint64_t fp = 0;
        for (size_t g = 0; g < sizeof gbs / sizeof *gbs; g++) @autoreleasepool {
            uint64_t len = (uint64_t)(gbs[g] * 1073741824.0), a0 = D.currentAllocatedSize, f0 = footprint(), t0 = now_ns();
            id<MTLBuffer> b = [D newBufferWithLength:len options:sto[s] placementSparsePageSize:PSS[i]];
            double ms = (double)(now_ns() - t0) / 1e6;
            printf(" %g:%s(%.1f)", gbs[g], b ? "ok" : "nil", ms);
            if (b) { maxok[i][s] = len; charged = D.currentAllocatedSize - a0; fp = footprint() - f0; gpu = b.gpuAddress; contents = b.contents != NULL; }
            else if (!minfail[i][s]) minfail[i][s] = len;
        }
        printf("\n    largest that worked %.1f GB: currentAllocatedSize +%.1f MB, footprint +%.1f MB, gpuAddress %#llx, CPU contents %s\n", GB(maxok[i][s]), MB(charged), MB(fp), (unsigned long long)gpu, contents ? "yes" : "no");
    }
    for (int i = 0; i < 3; i++) if (minfail[i][0] && minfail[i][0] > maxok[i][0]) @autoreleasepool {   // the limit, to 1 GB
        uint64_t lo = maxok[i][0], hi = minfail[i][0];
        while (hi - lo > (1ull << 30)) { uint64_t mid = ((lo + hi) / 2) & ~((1ull << 30) - 1); if (mid <= lo) break;
            @autoreleasepool { id<MTLBuffer> b = [D newBufferWithLength:mid options:MTLResourceStorageModePrivate placementSparsePageSize:PSS[i]]; if (b) lo = mid; else hi = mid; } }
        printf("page %-6s private: largest length %.0f GB (fails at %.0f GB)\n", PSN[i], GB(lo), GB(hi));
    }

    printf("\n== mapping updates: MTL4CommandQueue updateBufferMappings:heap:operations:count: into a 16 GB sparse buffer from a 256 MB placement heap (median of 3; 'done' = until a shared event signalled after it)\n");
    id<MTL4CommandQueue> q4 = [D newMTL4CommandQueue]; id<MTLSharedEvent> ev = [D newSharedEvent];
    { double b[5]; for (int r = 0; r < 5; r++) { uint64_t t0 = now_ns(); q4_sync(q4, ev); b[r] = (double)(now_ns() - t0) / 1e6; } printf("bare signal + wait: %.3f ms\n", median(b, 5)); }
    static MTL4UpdateSparseBufferMappingOperation ops[4096];
    for (int i = 0; i < 3; i++) @autoreleasepool {
        uint64_t tile = 16384ull << (2 * i);
        id<MTLHeap> h = placement_heap(256 << 20, MTLStorageModePrivate, PSS[i]);
        id<MTLBuffer> sb = [D newBufferWithLength:16ull << 30 options:MTLResourceStorageModePrivate placementSparsePageSize:PSS[i]];
        if (!h || !sb) { printf("page %s: heap %s, sparse buffer %s\n", PSN[i], h ? "ok" : "nil", sb ? "ok" : "nil"); continue; }
        NSUInteger nb = sb.length / tile, nh = h.size / tile; const int Ns[] = {1, 16, 256, 4096};
        for (int k = 0; k < 4; k++) {
            int N = Ns[k]; if ((NSUInteger)N > nh) N = (int)nh;
            double tc[3], td[3], tu[3];
            for (int r = 0; r < 3; r++) {
                for (int j = 0; j < N; j++) ops[j] = (MTL4UpdateSparseBufferMappingOperation){.mode = MTLSparseTextureMappingModeMap, .bufferRange = NSMakeRange((NSUInteger)j * (nb / N) + rnd() % (nb / N), 1), .heapOffset = (NSUInteger)j};
                uint64_t t0 = now_ns(); [q4 updateBufferMappings:sb heap:h operations:ops count:N]; uint64_t t1 = now_ns(); q4_sync(q4, ev); uint64_t t2 = now_ns();
                for (int j = 0; j < N; j++) ops[j].mode = MTLSparseTextureMappingModeUnmap;
                uint64_t t3 = now_ns(); [q4 updateBufferMappings:sb heap:nil operations:ops count:N]; q4_sync(q4, ev); uint64_t t4 = now_ns();
                tc[r] = (double)(t1 - t0) / 1e6; td[r] = (double)(t2 - t0) / 1e6; tu[r] = (double)(t4 - t3) / 1e6;
            }
            double dn = median(td, 3);
            printf("page %-6s %5d scattered one-page maps: call %.3f ms, done %.3f ms (%.2f us a page); unmapping them %.3f ms\n", PSN[i], N, median(tc, 3), dn, dn * 1e3 / N, median(tu, 3));
        }
        MTL4UpdateSparseBufferMappingOperation op = {.mode = MTLSparseTextureMappingModeMap, .bufferRange = NSMakeRange(nb / 3, nh), .heapOffset = 0};
        uint64_t t0 = now_ns(); [q4 updateBufferMappings:sb heap:h operations:&op count:1]; q4_sync(q4, ev); uint64_t t1 = now_ns();
        op.mode = MTLSparseTextureMappingModeUnmap; [q4 updateBufferMappings:sb heap:nil operations:&op count:1]; q4_sync(q4, ev); uint64_t t2 = now_ns();
        printf("page %-6s one operation of %lu pages (256 MB): done %.3f ms, unmapped %.3f ms\n", PSN[i], (unsigned long)nh, (double)(t1 - t0) / 1e6, (double)(t2 - t1) / 1e6);
    }

    sparse_probe(MTLStorageModePrivate, probe, q4, ev);

    printf("\n== GPU addresses\n");
    @autoreleasepool {
        size_t M = 1 << 20; uint8_t *m = mmap(NULL, 8 * M, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0); memset(m, 1, 8 * M);
        NSMutableArray<id<MTLBuffer>> *nb = [NSMutableArray array];
        for (int i = 0; i < 8; i++) [nb addObject:[D newBufferWithBytesNoCopy:m + i * M length:M options:MTLResourceStorageModeShared deallocator:nil]];
        printf("8 zero-copy buffers over consecutive 1 MB of one mapping: gpuAddress - CPU pointer:"); for (int i = 0; i < 8; i++) printf(" %#llx", (unsigned long long)(nb[i].gpuAddress - (uint64_t)nb[i].contents));
        printf("\n  gpuAddress - the first one's, MB:"); for (int i = 0; i < 8; i++) printf(" %.2f", (double)(int64_t)(nb[i].gpuAddress - nb[0].gpuAddress) / 1048576.0);
        id<MTLBuffer> all = [D newBufferWithBytesNoCopy:m length:8 * M options:MTLResourceStorageModeShared deallocator:nil];
        printf("\n  one zero-copy buffer over all 8 MB: gpuAddress %#llx, CPU pointer %p\n", (unsigned long long)all.gpuAddress, m);
        NSMutableArray<id<MTLBuffer>> *pb = [NSMutableArray array]; for (int i = 0; i < 8; i++) [pb addObject:[D newBufferWithLength:M options:MTLResourceStorageModeShared]];
        printf("8 plain 1 MB buffers: gpuAddress - the first one's, MB:"); for (int i = 0; i < 8; i++) printf(" %.2f", (double)(int64_t)(pb[i].gpuAddress - pb[0].gpuAddress) / 1048576.0);
        id<MTLHeap> h = placement_heap(64 << 20, MTLStorageModeShared, MTLSparsePageSize64);
        if (h) { uint64_t offs[3] = {0, 1 << 20, 17 << 20}; id<MTLBuffer> hb[3]; for (int i = 0; i < 3; i++) hb[i] = [h newBufferWithLength:M options:MTLResourceStorageModeShared offset:offs[i]];
            printf("\nplacement heap buffers at offsets 0, 1, 17 MB: gpuAddress - the first one's, MB: %.2f %.2f %.2f\n", 0.0, (double)(int64_t)(hb[1].gpuAddress - hb[0].gpuAddress) / 1048576.0, (double)(int64_t)(hb[2].gpuAddress - hb[0].gpuAddress) / 1048576.0); }
        uint64_t pg = vm_page_size; uint8_t *m2 = mmap(NULL, 3 * pg, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0); memset(m2, 1, 3 * pg); mprotect(m2 + pg, pg, PROT_NONE);
        id<MTLBuffer> b2 = [D newBufferWithBytesNoCopy:m2 length:3 * pg options:MTLResourceStorageModeShared deallocator:nil];
        mprotect(m2 + pg, pg, PROT_READ); id<MTLBuffer> b3 = [D newBufferWithBytesNoCopy:m2 length:3 * pg options:MTLResourceStorageModeShared deallocator:nil];
        uint8_t *m3 = mmap(NULL, 3 * pg, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0); munmap(m3 + pg, pg);
        id<MTLBuffer> b4 = [D newBufferWithBytesNoCopy:m3 length:3 * pg options:MTLResourceStorageModeShared deallocator:nil];
        printf("zero-copy buffer over 3 pages, the middle one PROT_NONE: %s; read-only: %s; not mapped at all: %s\n", b2 ? "made" : "refused", b3 ? "made" : "refused", b4 ? "made" : "refused");
        b2 = b3 = b4 = nil; munmap(m2, 3 * pg); munmap(m3, pg); munmap(m3 + 2 * pg, pg);
        [nb removeAllObjects]; all = nil; munmap(m, 8 * M);
    }

    printf("\n== does the residency set wire a zero-copy buffer whole? A 1 GB mapping nothing touched, so no pages to wire (`wire` measures written memory; system wired memory, so other processes add noise)\n");
    @autoreleasepool {
        size_t L = 1ull << 30; uint8_t *m = mmap(NULL, L, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0);
        uint64_t w0 = wired(), f0 = footprint();
        id<MTLBuffer> b = [D newBufferWithBytesNoCopy:m length:L options:MTLResourceStorageModeShared deallocator:nil];
        uint64_t w1 = wired(), f1 = footprint();
        [RS addAllocation:b]; rs_commit(); usleep(300000); uint64_t w2 = wired(), f2 = footprint();
        uint32_t v[2] = {0, 7}, *vp = v; NSError *err = nil;
        run(poke, 1, 1, @"poke", ^(id<MTLComputeCommandEncoder> e) { [e setBuffer:b offset:0 atIndex:0]; [e setBytes:vp length:8 atIndex:1]; }, &err);
        usleep(300000); uint64_t w3 = wired(), f3 = footprint();
        [RS removeAllocation:b]; rs_commit(); usleep(300000); uint64_t w4 = wired();
        b = nil; usleep(300000); uint64_t w5 = wired();
        printf("wired MB vs before: buffer made %+.0f, in the residency set %+.0f, after a kernel wrote one word %+.0f (%s), out of the set %+.0f, buffer gone %+.0f; footprint %+.0f / %+.0f / %+.0f MB\n",
            MB(w1) - MB(w0), MB(w2) - MB(w0), MB(w3) - MB(w0), err ? err.localizedDescription.UTF8String : "ok", MB(w4) - MB(w0), MB(w5) - MB(w0), MB(f1) - MB(f0), MB(f2) - MB(f0), MB(f3) - MB(f0));
        munmap(m, L);
    }

    printf("\n== Metal memory at a chosen CPU address: mach_vm_remap (copy = FALSE, VM_FLAGS_FIXED | VM_FLAGS_OVERWRITE) of a shared buffer's pages over a PROT_NONE reservation\n");
    for (int kind = 0; kind < 2; kind++) @autoreleasepool {
        size_t L = 4 * vm_page_size; id<MTLHeap> h = nil;
        id<MTLBuffer> sh = kind == 0 ? [D newBufferWithLength:L options:MTLResourceStorageModeShared] : (h = placement_heap(L, MTLStorageModeShared, MTLSparsePageSize16)) ? [h newBufferWithLength:L options:MTLResourceStorageModeShared offset:0] : nil;
        const char *what = kind == 0 ? "plain shared buffer" : "placement heap buffer";
        if (!sh) { printf("%s: not made\n", what); continue; }
        memset(sh.contents, 0, L);
        void *res = mmap(NULL, L, PROT_NONE, MAP_ANON | MAP_PRIVATE, -1, 0);
        mach_vm_address_t dst = (mach_vm_address_t)res; vm_prot_t cur = 0, mx = 0;
        kern_return_t kr = mach_vm_remap(mach_task_self(), &dst, L, 0, VM_FLAGS_FIXED | VM_FLAGS_OVERWRITE, mach_task_self(), (mach_vm_address_t)sh.contents, FALSE, &cur, &mx, VM_INHERIT_NONE);
        printf("%s: remap kr %d (%s), at the reservation %d, protection cur %d max %d", what, kr, mach_error_string(kr), dst == (mach_vm_address_t)res, cur, mx);
        if (kr == KERN_SUCCESS) {
            ((volatile uint32_t *)dst)[0] = 0x1234; int cpu_ok = ((volatile uint32_t *)sh.contents)[0] == 0x1234;
            [RS addAllocation:sh]; rs_commit(); uint32_t v[2] = {1, 0x5678}, *vp = v; NSError *err = nil;
            run(poke, 1, 1, @"poke alias", ^(id<MTLComputeCommandEncoder> e) { [e setBuffer:sh offset:0 atIndex:0]; [e setBytes:vp length:8 atIndex:1]; }, &err);
            int gpu_ok = ((volatile uint32_t *)dst)[1] == 0x5678;
            printf("; CPU write through the alias seen in contents %d, GPU write seen through the alias %d (%s)", cpu_ok, gpu_ok, err ? err.localizedDescription.UTF8String : "ok");
            [RS removeAllocation:sh]; rs_commit();
        }
        printf("\n");
        munmap((void *)dst, L);
    }
}

// ---- chase ----
typedef struct { uint64_t va0, len, base, zero, npages; uint32_t steps, p1, p2, p3; } prm_t;
static NSString *k_chase = @
    "#include <metal_stdlib>\nusing namespace metal;\n"
    "struct Prm { ulong va0, len, base, zero, npages; uint steps, p1, p2, p3; };\n"
    "#define AT_OR_ABOVE(eh, el) ((eh) < hi || ((eh) == hi && (el) <= lo))\n"
    "#define BELOW(eh, el) (hi < (eh) || (hi == (eh) && lo < (el)))\n"
    "#define STEP(S) { uint c = idx + (S); uint ce = c * 8u; idx = AT_OR_ABOVE(t[ce + 1u], t[ce]) ? c : idx; }\n"
    "static inline __attribute__((always_inline)) uint pick(uint lo, uint hi, device uint *t) {\n"
    "  uint chunk = (hi << 11) | (lo >> 21);\n"
    "  uint h = t[(chunk & 8191u) * 8u + 6u];\n"
    "  uint hidx = h & 8191u;\n"
    "  if (hidx != 0u && (h >> 13) == chunk && hi < 256u) return hidx;\n"
    "  uint idx = 0u;\n"
    "  STEP(4096u) STEP(2048u) STEP(1024u) STEP(512u) STEP(256u) STEP(128u) STEP(64u) STEP(32u) STEP(16u) STEP(8u) STEP(4u) STEP(2u) STEP(1u)\n"
    "  return idx;\n"
    "}\n"
    "static inline __attribute__((always_inline)) void logbit(device uint *lg, uint sel) {\n"
    "  uint w = (sel >> 5) + 256u, b = 1u << (sel & 31u);\n"
    "  if ((lg[w] & b) == 0u) atomic_fetch_or_explicit((device atomic_uint *)&lg[w], b, memory_order_relaxed);\n"
    "}\n"
    "static inline __attribute__((always_inline)) device uint *look_legacy(uint lo, uint hi, device uint *t, device uint *lg, thread uint &last, ulong zero) {\n"
    "  uint sel = last, e = last * 8u;\n"
    "  if (!(AT_OR_ABOVE(t[e + 1u], t[e]) && BELOW(t[e + 3u], t[e + 2u]))) {\n"
    "    sel = pick(lo, hi, t); last = sel;\n"
    "    uint f = sel * 8u;\n"
    "    if (!BELOW(t[f + 3u], t[f + 2u])) return reinterpret_cast<device uint *>(zero);\n"
    "    logbit(lg, sel);\n"
    "  }\n"
    "  uint f = sel * 8u, hl = lo + t[f + 4u], hh = hi + t[f + 5u] + (hl < lo ? 1u : 0u);\n"
    "  return reinterpret_cast<device uint *>(as_type<ulong>(uint2(hl, hh)));\n"
    "}\n"
    "static inline __attribute__((always_inline)) device uint *look_regs(uint lo, uint hi, device uint *t, device uint *lg, thread uint &last, thread uint *r, ulong zero) {\n"
    "  uint sel = last;\n"
    "  if (!(AT_OR_ABOVE(r[1], r[0]) && BELOW(r[3], r[2]))) {\n"
    "    sel = pick(lo, hi, t); last = sel;\n"
    "    uint f = sel * 8u;\n"
    "    r[0] = t[f]; r[1] = t[f + 1u]; r[2] = t[f + 2u]; r[3] = t[f + 3u]; r[4] = t[f + 4u]; r[5] = t[f + 5u];\n"
    "    if (!BELOW(t[f + 3u], t[f + 2u])) return reinterpret_cast<device uint *>(zero);\n"
    "    logbit(lg, sel);\n"
    "  }\n"
    "  uint hl = lo + r[4], hh = hi + r[5] + (hl < lo ? 1u : 0u);\n"
    "  return reinterpret_cast<device uint *>(as_type<ulong>(uint2(hl, hh)));\n"
    "}\n"
    "static inline __attribute__((always_inline)) device uint *look_pt(uint lo, uint hi, device const ulong *pt, constant Prm &p) {\n"
    "  ulong va = as_type<ulong>(uint2(lo, hi)), i = (va - p.va0) >> 14;\n"
    "  i = i < p.npages ? i : p.npages;\n"
    "  return reinterpret_cast<device uint *>((pt[i] & ~0x3ffful) | (va & 0x3ffful));\n"
    "}\n"
    "static inline __attribute__((always_inline)) device uint *look_ptlog(uint lo, uint hi, device const ulong *pt, constant Prm &p, device uint *lg, thread uint &slot) {\n"
    "  ulong va = as_type<ulong>(uint2(lo, hi)), i = (va - p.va0) >> 14;\n"
    "  i = i < p.npages ? i : p.npages;\n"
    "  ulong e = pt[i]; uint s = uint(e) & 0x1fffu;\n"
    "  if (s != slot) { slot = s; logbit(lg, s); }\n"
    "  return reinterpret_cast<device uint *>((e & ~0x3ffful) | (va & 0x3ffful));\n"
    "}\n"
    "static inline __attribute__((always_inline)) device uint *look_pt2(uint lo, uint hi, device const uint *l1, device const ulong *l2, constant Prm &p) {\n"
    "  ulong va = as_type<ulong>(uint2(lo, hi)), o = va - p.va0, i = o >> 25;\n"
    "  ulong b = i < ulong(p.p1) ? ulong(l1[i]) : 0ul;\n"
    "  ulong e = l2[(b << 11) | ((o >> 14) & 2047ul)];\n"
    "  return reinterpret_cast<device uint *>((e & ~0x3ffful) | (va & 0x3ffful));\n"
    "}\n"
    "static inline __attribute__((always_inline)) device uint *look_flat(uint lo, uint hi, constant Prm &p) {\n"
    "  ulong off = as_type<ulong>(uint2(lo, hi)) - p.va0;\n"
    "  return reinterpret_cast<device uint *>(off < p.len ? p.base + off : p.zero);\n"
    "}\n";
static const char *VARIANTS[] = {"legacy", "regs", "pt", "ptlog", "pt2", "flat", "sparse"};
enum { NVAR = 7, V_FLAT = 5, V_SPARSE = 6 };
static NSString *chase_src(int v, unsigned U, unsigned R) {
    static const char *lv[] = {"look_legacy(lo, hi, t, lg, lastv, p.zero)", "look_regs(lo, hi, t, lg, lastv, rv, p.zero)", "look_pt(lo, hi, pt, p)", "look_ptlog(lo, hi, pt, p, lg, slv)", "look_pt2(lo, hi, l1, l2, p)", "look_flat(lo, hi, p)", "look_flat(lo, hi, p)"};
    static const char *ls[] = {"look_legacy(lo, hi, t, lg, lasts, p.zero)", "look_regs(lo, hi, t, lg, lasts, rs, p.zero)", "look_pt(lo, hi, pt, p)", "look_ptlog(lo, hi, pt, p, lg, sls)", "look_pt2(lo, hi, l1, l2, p)", "look_flat(lo, hi, p)", "look_flat(lo, hi, p)"};
    NSMutableString *s = [NSMutableString stringWithString:k_chase];
    [s appendFormat:@"#define LV(lo, hi) %s\n#define LS(lo, hi) %s\n", lv[v], ls[v]];
    [s appendString:@"kernel void chase(device const uint2 *starts [[buffer(0)]], device uint4 *out [[buffer(1)]], constant Prm &p [[buffer(2)]], device uint *t [[buffer(3)]], device uint *lg [[buffer(4)]], device const ulong *pt [[buffer(5)]], device const uint *l1 [[buffer(6)]], device const ulong *l2 [[buffer(7)]], uint tid [[thread_position_in_grid]]) {\n"
        "  uint lastv = 0u, lasts = 0u, slv = 0xffffffffu, sls = 0xffffffffu;\n"
        "  uint rv[6] = {0u, 0u, 0u, 0u, 0u, 0u}, rs[6] = {0u, 0u, 0u, 0u, 0u, 0u};\n"
        "  (void)lastv; (void)lasts; (void)slv; (void)sls; (void)rv; (void)rs; (void)t; (void)lg; (void)pt; (void)l1; (void)l2;\n"
        "  uint2 a = starts[tid]; uint acc = 0u;\n"];
    [s appendFormat:@"  for (uint s = 0u; s < p.steps; s += %uu) {\n", U];
    for (unsigned u = 0; u < U; u++) {
        [s appendString:@"    { uint2 nx = *reinterpret_cast<device uint2 *>(LV(a.x, a.y));"];
        for (unsigned r = 1; r < R; r++) [s appendFormat:@" acc += *LS(a.x + %uu, a.y);", 8 + 4 * (r - 1)];
        [s appendString:@" a = nx; }\n"];
    }
    [s appendString:@"  }\n  out[tid] = uint4(a, acc, 0u);\n}\n"];
    return s;
}
// The CPU's view of the translator's search, for the path mix: 0 the last entry held the address, 1 the hint, 2 the search
static int holds(const uint32_t *t, unsigned k, uint64_t a) { uint64_t lo, hi; memcpy(&lo, t + k * 8, 8); memcpy(&hi, t + k * 8 + 2, 8); return a >= lo && a < hi; }
static unsigned pick_cpu(const uint32_t *t, uint64_t a, int *path) {
    uint32_t lo = (uint32_t)a, hi = (uint32_t)(a >> 32), chunk = (hi << 11) | (lo >> 21), h = t[(chunk & 8191) * 8 + 6], hidx = h & 8191;
    if (hidx && (h >> 13) == chunk && hi < 256) { *path = 1; return hidx; }
    *path = 2; unsigned idx = 0;
    for (unsigned st = 4096; st; st >>= 1) { uint64_t s; memcpy(&s, t + (idx + st) * 8, 8); if (s <= a) idx += st; }
    return idx;
}
static int has(const char *list, const char *w) { size_t n = strlen(w); for (const char *p = list; (p = strstr(p, w)); p += n) if ((p == list || p[-1] == ',') && (p[n] == ',' || !p[n])) return 1; return 0; }

static void chase(int argc, char **argv) {
    uint64_t mbs = 1536; unsigned T = 65536, S = 64, U = 16, H = 4096, reps = 5, spage = 64; const char *modes = "cross-hot,same-hot,cross-cold", *reads = "1,4", *pools = "mixed", *variants = "legacy,regs,pt,ptlog,pt2,flat,sparse";
    for (int i = 2; i + 1 < argc; i += 2) {
        const char *k = argv[i], *v = argv[i + 1];
        if (!strcmp(k, "--mb")) mbs = strtoull(v, NULL, 0); else if (!strcmp(k, "--threads")) T = (unsigned)atoi(v); else if (!strcmp(k, "--steps")) S = (unsigned)atoi(v);
        else if (!strcmp(k, "--unroll")) U = (unsigned)atoi(v); else if (!strcmp(k, "--hot")) H = (unsigned)atoi(v); else if (!strcmp(k, "--reps")) reps = (unsigned)atoi(v);
        else if (!strcmp(k, "--spage")) spage = (unsigned)atoi(v); else if (!strcmp(k, "--modes")) modes = v; else if (!strcmp(k, "--reads")) reads = v;
        else if (!strcmp(k, "--pools")) pools = v; else if (!strcmp(k, "--variants")) variants = v; else { fprintf(stderr, "unknown option %s\n", k); exit(2); }
    }
    if (U < 1) U = 1; if (S % U) S = (S / U + 1) * U; if (reps > 15) reps = 15; H &= ~15u; if (H < 16) H = 16;
    const uint64_t PG = 16384; uint64_t W = (mbs << 20) & ~(PG - 1);
    uint8_t *ar = mmap(NULL, W, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0);
    if (ar == MAP_FAILED) { perror("arena"); exit(1); }
    // Pools: sizes log-uniform from 16 KB to 4 MB (Ocarina of Time: about 2,500 pools; 3,564 ranges in its raw table), memory in no pool before a fifth of them;
    // --pools big: the first half of the arena one pool, as the 2.4 GB graphics pool is one entry of the table once big_full takes it whole
    typedef struct { uint64_t lo, size, gpu; } pool_t;
    pool_t *pl = calloc(8192, sizeof *pl); int np = 0; uint64_t off = 0, gaps = 0;
    if (!strcmp(pools, "big")) { pl[np++] = (pool_t){(uint64_t)ar, (W / 2) & ~(PG - 1), 0}; off = pl[0].size; }
    while (off < W && np < 8000) {
        if (rndf() < 0.2) { uint64_t g = (uint64_t)exp(log(16384.0) + rndf() * (log(1048576.0) - log(16384.0))) & ~(PG - 1); if (!g) g = PG; off += g; gaps += g; continue; }
        uint64_t sz = (uint64_t)exp(log(16384.0) + rndf() * (log(4194304.0) - log(16384.0))) & ~(PG - 1); if (sz < PG) sz = PG;
        if (off + sz > W) sz = W - off;
        pl[np++] = (pool_t){(uint64_t)ar + off, sz, 0}; off += sz;
    }
    MTLResidencySetDescriptor *rd = [MTLResidencySetDescriptor new]; rd.initialCapacity = (NSUInteger)np + 64;
    NSMutableArray<id<MTLBuffer>> *bufs = [NSMutableArray array]; int unaligned = 0; uint64_t inpool = 0;
    uint64_t t0 = now_ns();
    for (int i = 0; i < np; i++) {
        id<MTLBuffer> b = [D newBufferWithBytesNoCopy:(void *)pl[i].lo length:pl[i].size options:MTLResourceStorageModeShared deallocator:nil];
        if (!b) { fprintf(stderr, "pool %d: zero-copy buffer refused\n", i); exit(1); }
        [bufs addObject:b]; [RS addAllocation:b]; pl[i].gpu = b.gpuAddress; if (pl[i].gpu & (PG - 1)) unaligned++; inpool += pl[i].size;
    }
    printf("== chase: %.0f MB of guest memory at %p, %d pools (%s, %.0f MB in pools, %.0f MB in none), zero-copy buffers made in %.1f ms, %d of their GPU addresses not 16 KB aligned\n",
        MB(W), ar, np, pools, MB(inpool), MB(gaps), (double)(now_ns() - t0) / 1e6, unaligned);
    // The raw pool table as gmem_map builds it (budget mode): entry 0 empty, the pools sorted and disjoint, unused entries at ~0, a tagged hint per 2 MiB chunk wholly inside an entry
    id<MTLBuffer> tb = [D newBufferWithLength:8192 * 32 options:MTLResourceStorageModeShared]; uint32_t *t = tb.contents; memset(t, 0, 8192 * 32);
    for (int k = 1; k < 8192; k++) memset(t + k * 8, 0xff, 8);
    for (int i = 0; i < np; i++) { uint64_t e[3] = {pl[i].lo, pl[i].lo + pl[i].size, pl[i].gpu - pl[i].lo}; memcpy(t + (i + 1) * 8, e, 24); }
    int nhint = 0;
    for (int k = 1; k <= np; k++) { uint64_t lo, hi; memcpy(&lo, t + k * 8, 8); memcpy(&hi, t + k * 8 + 2, 8);
        for (uint64_t c = (lo + (1ull << 21) - 1) >> 21; c < (hi >> 21) && c < (1ull << 19); c++) { t[(c % 8192) * 8 + 6] = (uint32_t)(c << 13 | (unsigned)k); nhint++; } }
    id<MTLBuffer> lgb = [D newBufferWithLength:512 * 4 options:MTLResourceStorageModeShared];
    id<MTLBuffer> zb = [D newBufferWithLength:PG options:MTLResourceStorageModeShared]; memset(zb.contents, 0, PG);
    // The page table: one entry per 16 KB page of the arena, the page's Metal address | the pool's slot (its table index); memory in no pool and anything past the end: the page of zeros
    uint64_t npages = W / PG;
    id<MTLBuffer> ptb = [D newBufferWithLength:(npages + 1) * 8 options:MTLResourceStorageModeShared]; uint64_t *pt = ptb.contents;
    for (uint64_t i = 0; i <= npages; i++) pt[i] = zb.gpuAddress;
    for (int i = 0; i < np; i++) for (uint64_t j = 0; j < pl[i].size / PG; j++) pt[(pl[i].lo - (uint64_t)ar) / PG + j] = (pl[i].gpu + j * PG) | (uint64_t)(i + 1);
    // The two-level table: L1 a block number per 32 MiB region (0: the block of zero pages), L2 the blocks of 2,048 entries, the regions' blocks in a shuffled order
    uint32_t nreg = (uint32_t)((npages + 2047) / 2048);
    id<MTLBuffer> l1b = [D newBufferWithLength:(NSUInteger)nreg * 4 options:MTLResourceStorageModeShared], l2b = [D newBufferWithLength:((NSUInteger)nreg + 1) * 2048 * 8 options:MTLResourceStorageModeShared];
    { uint32_t *l1 = l1b.contents, *perm = malloc((size_t)nreg * 4); uint64_t *l2 = l2b.contents;
        for (uint32_t i = 0; i < nreg; i++) perm[i] = i + 1;
        for (uint32_t i = nreg - 1; i > 0; i--) { uint32_t j = (uint32_t)(rnd() % (i + 1)), x = perm[i]; perm[i] = perm[j]; perm[j] = x; }
        for (uint64_t q = 0; q < 2048; q++) l2[q] = zb.gpuAddress;
        for (uint32_t i = 0; i < nreg; i++) { l1[i] = perm[i]; for (uint64_t q = 0; q < 2048; q++) { uint64_t pgi = (uint64_t)i * 2048 + q; l2[(uint64_t)perm[i] * 2048 + q] = pgi < npages ? pt[pgi] : zb.gpuAddress; } }
        free(perm); }
    // Design b: one zero-copy buffer over the whole arena
    id<MTLBuffer> nc = [D newBufferWithBytesNoCopy:ar length:W options:MTLResourceStorageModeShared deallocator:nil];
    printf("raw pool table: %d entries, %d chunk hints; page table %.1f MB (%llu pages); one zero-copy buffer over the arena: %s\n", np, nhint, MB((npages + 1) * 8), (unsigned long long)npages, nc ? "made" : "refused");
    // Design a: a 16 GB placement sparse buffer, the arena's bytes mapped at 4 GB from placement heaps of 512 MB
    id<MTLBuffer> sb = nil; NSMutableArray<id<MTLHeap>> *heaps = [NSMutableArray array]; const uint64_t sboff = 4ull << 30;
    if (has(variants, "sparse")) {
        MTLSparsePageSize sps = spage == 16 ? MTLSparsePageSize16 : spage == 256 ? MTLSparsePageSize256 : MTLSparsePageSize64; uint64_t tile = (uint64_t)(spage == 16 || spage == 256 ? spage : 64) << 10;
        sb = [D newBufferWithLength:16ull << 30 options:MTLResourceStorageModePrivate placementSparsePageSize:sps];
        id<MTL4CommandQueue> q4 = [D newMTL4CommandQueue]; id<MTLSharedEvent> ev = [D newSharedEvent];
        uint64_t tm = now_ns();
        for (uint64_t o = 0; sb && o < W; o += 512ull << 20) {
            uint64_t len = MIN(512ull << 20, W - o); len = (len + tile - 1) / tile * tile;
            id<MTLHeap> h = placement_heap(len, MTLStorageModePrivate, sps); if (!h) { printf("placement heap of %.0f MB refused\n", MB(len)); sb = nil; break; }
            [heaps addObject:h]; [RS addAllocation:h];
            MTL4UpdateSparseBufferMappingOperation op = {.mode = MTLSparseTextureMappingModeMap, .bufferRange = NSMakeRange((sboff + o) / tile, len / tile), .heapOffset = 0};
            [q4 updateBufferMappings:sb heap:h operations:&op count:1];
        }
        if (sb) { q4_sync(q4, ev); [RS addAllocation:sb]; printf("sparse: 16 GB placement sparse buffer, %u KB pages, %.0f MB mapped from %lu heaps in %.1f ms\n", spage, MB(W), (unsigned long)heaps.count, (double)(now_ns() - tm) / 1e6); }
        else printf("sparse: not available\n");
    }
    id<MTLBuffer> stb = [D newBufferWithLength:(NSUInteger)T * 8 options:MTLResourceStorageModeShared], out = [D newBufferWithLength:(NSUInteger)T * 16 options:MTLResourceStorageModeShared];
    for (id<MTLBuffer> b in @[tb, lgb, zb, ptb, l1b, l2b, stb, out]) [RS addAllocation:b];
    if (nc) [RS addAllocation:nc];
    t0 = now_ns(); rs_commit(); printf("residency set committed (%lu allocations) in %.1f ms\n", (unsigned long)RS.allocationCount, (double)(now_ns() - t0) / 1e6);
    // Node candidates: one per 16 KB page of a pool, at a random 64-byte slot, shuffled
    uint64_t ncand = 0; for (int i = 0; i < np; i++) ncand += pl[i].size / PG;
    uint64_t *cand = malloc(ncand * 8), k = 0;
    for (int i = 0; i < np; i++) for (uint64_t j = 0; j < pl[i].size / PG; j++) cand[k++] = pl[i].lo + j * PG + (rnd() % 256) * 64;
    for (uint64_t i = ncand - 1; i > 0; i--) { uint64_t j = rnd() % (i + 1), x = cand[i]; cand[i] = cand[j]; cand[j] = x; }
    uint64_t *set = malloc(MAX(ncand * 32, (uint64_t)H) * 8); uint64_t (*ref)[2] = malloc((size_t)T * 16);
    NSMutableDictionary<NSString *, id<MTLComputePipelineState>> *pipes = [NSMutableDictionary dictionary];
    char mbuf[256]; snprintf(mbuf, sizeof mbuf, "%s", modes);
    for (char *mode = strtok(mbuf, ","); mode; mode = strtok(NULL, ",")) {
        uint64_t ns;
        if (!strcmp(mode, "cross-cold")) { ns = ncand; memcpy(set, cand, ncand * 8); }
        else if (!strcmp(mode, "dram")) { ns = 0; for (int i = 0; i < np; i++) for (uint64_t o = 0; o + 512 <= pl[i].size; o += 512) set[ns++] = pl[i].lo + o + (rnd() % 8) * 64;
            for (uint64_t i = ns - 1; i > 0; i--) { uint64_t j = rnd() % (i + 1), x = set[i]; set[i] = set[j]; set[j] = x; } }
        else if (!strcmp(mode, "cross-hot")) { ns = MIN((uint64_t)H, ncand); memcpy(set, cand, ns * 8); }
        else if (!strcmp(mode, "same-hot")) { ns = H; for (unsigned g = 0; g < H / 16; g++) { uint64_t page = cand[g] & ~(PG - 1); uint8_t sl[256]; for (int q = 0; q < 256; q++) sl[q] = (uint8_t)q;
                for (int q = 0; q < 16; q++) { int j = q + (int)(rnd() % (uint64_t)(256 - q)); uint8_t x = sl[q]; sl[q] = sl[j]; sl[j] = x; set[g * 16 + q] = page + (uint64_t)sl[q] * 64; } } }
        else { printf("unknown mode %s\n", mode); continue; }
        for (uint64_t i = 0; i < ns; i++) { uint32_t *nd = (uint32_t *)set[i]; *(uint64_t *)nd = set[(i + 1) % ns]; for (int q = 2; q < 16; q++) nd[q] = (uint32_t)(set[i] * 2654435761u) ^ (uint32_t)q; }
        uint32_t *st = stb.contents; for (unsigned i = 0; i < T; i++) { uint64_t a = set[((uint64_t)i * 7919) % ns]; st[2 * i] = (uint32_t)a; st[2 * i + 1] = (uint32_t)(a >> 32); }
        // The path the next-pointer helper takes today, from the CPU's copy of the table
        uint64_t path[3] = {0}; for (unsigned i = 0; i < T; i += 16) { uint64_t a = set[((uint64_t)i * 7919) % ns]; unsigned last = 0;
            for (unsigned s = 0; s < S; s++) { int pth = 0; if (!holds(t, last, a)) last = pick_cpu(t, a, &pth); path[pth]++; a = *(uint64_t *)a; } }
        uint64_t pn = path[0] + path[1] + path[2];
        double bms = 0; if (sb) { NSError *e = blit(nc, 0, sb, sboff, W, &bms); if (e) printf("copy into the sparse buffer: %s\n", e.localizedDescription.UTF8String); }
        printf("\n-- %s: %llu nodes; the next-pointer lookup today: last entry %.0f%%, hint %.0f%%, search %.0f%%%s\n", mode, (unsigned long long)ns, 100.0 * path[0] / pn, 100.0 * path[1] / pn, 100.0 * path[2] / pn,
            sb ? [NSString stringWithFormat:@" (arena copied into the sparse buffer, %.1f ms)", bms].UTF8String : "");
        char rbuf[64]; snprintf(rbuf, sizeof rbuf, "%s", reads); char *rsave = NULL;
        for (char *rs = strtok_r(rbuf, ",", &rsave); rs; rs = strtok_r(NULL, ",", &rsave)) {
            unsigned R = (unsigned)atoi(rs); if (R < 1) R = 1;
            for (unsigned i = 0; i < T; i++) { uint64_t a = set[((uint64_t)i * 7919) % ns], acc = 0; for (unsigned s = 0; s < S; s++) { for (unsigned r = 1; r < R; r++) acc += ((uint32_t *)a)[2 + r - 1]; a = *(uint64_t *)a; } ref[i][0] = a; ref[i][1] = (uint32_t)acc; }
            printf("   %u threads x %u steps, %u load(s) a step, %u steps inlined in the loop\n", T, S, R, U);
            // Each variant built and checked against the CPU once, then the reps interleaved (rep r runs every variant in turn), so a clock or cache drift touches them alike
            id<MTLComputePipelineState> P[NVAR] = {nil}; prm_t PR[NVAR]; int bad[NVAR] = {0}, ok[NVAR] = {0}; double ms[NVAR][16]; NSError *err = nil;
            void (^dispatch)(id<MTLComputePipelineState>, prm_t, int, double *) = ^(id<MTLComputePipelineState> pp, prm_t prm, int v, double *x) {
                memset(lgb.contents, 0, 512 * 4);
                NSError *e2 = nil;
                double t = run(pp, T, MIN((NSUInteger)256, pp.maxTotalThreadsPerThreadgroup), [NSString stringWithFormat:@"chase %s R%u %s", mode, R, VARIANTS[v]], ^(id<MTLComputeCommandEncoder> e) {
                    [e setBuffer:stb offset:0 atIndex:0]; [e setBuffer:out offset:0 atIndex:1]; [e setBytes:&prm length:sizeof prm atIndex:2]; [e setBuffer:tb offset:0 atIndex:3];
                    [e setBuffer:lgb offset:0 atIndex:4]; [e setBuffer:ptb offset:0 atIndex:5]; [e setBuffer:l1b offset:0 atIndex:6]; [e setBuffer:l2b offset:0 atIndex:7]; }, &e2);
                if (e2) printf("   %-7s error: %s\n", VARIANTS[v], e2.localizedDescription.UTF8String);
                *x = e2 ? -1 : t;
            };
            for (int v = 0; v < NVAR; v++) {
                if (!has(variants, VARIANTS[v]) || (v == V_SPARSE && !sb) || (v == V_FLAT && !nc)) continue;
                NSString *key = [NSString stringWithFormat:@"%d.%u.%u", v, U, R]; P[v] = pipes[key];
                if (!P[v]) { P[v] = pipeline(chase_src(v, U, R), "chase"); pipes[key] = P[v]; }
                PR[v] = (prm_t){(uint64_t)ar, W, 0, zb.gpuAddress, npages, S, nreg, 0, 0};
                if (v == V_FLAT) PR[v].base = nc.gpuAddress; else if (v == V_SPARSE) PR[v].base = sb.gpuAddress + sboff;
                double x; memset(out.contents, 0, (size_t)T * 16); dispatch(P[v], PR[v], v, &x); if (x < 0) continue;
                const uint32_t *o = out.contents; for (unsigned i = 0; i < T; i++) if (o[4 * i] != (uint32_t)ref[i][0] || o[4 * i + 1] != (uint32_t)(ref[i][0] >> 32) || o[4 * i + 2] != (uint32_t)ref[i][1]) bad[v]++;
                ok[v] = 1;
            }
            (void)err;
            for (int h = 0; h < 6; h++) for (int v = 0; v < NVAR; v++) if (ok[v]) { double x; dispatch(P[v], PR[v], v, &x); }   // warm-up: every variant, so the clock has ramped and the data and tables are where a rep finds them
            for (unsigned r = 0; r < reps; r++) for (int v = 0; v < NVAR; v++) if (ok[v]) dispatch(P[v], PR[v], v, &ms[v][r]);
            double base = 0;
            for (int v = 0; v < NVAR; v++) {
                if (!ok[v]) continue;
                double md = median(ms[v], (int)reps), mn = ms[v][0];
                if (!base) base = md;
                printf("   %-7s %8.3f ms (min %.3f)  %6.3f ns a load  %6.3f ns a step  %5.2fx legacy  max threads/threadgroup %4lu  %s\n", VARIANTS[v], md, mn, md * 1e6 / ((double)T * S * R), md * 1e6 / ((double)T * S),
                    base / md, (unsigned long)P[v].maxTotalThreadsPerThreadgroup, bad[v] ? [NSString stringWithFormat:@"%d threads WRONG", bad[v]].UTF8String : "results match the CPU");
            }
        }
    }
    free(cand); free(set); free(ref); free(pl);
    [RS removeAllAllocations]; rs_commit();
    [bufs removeAllObjects]; nc = nil; sb = nil; [heaps removeAllObjects];
    munmap(ar, W);
}

// Whether the residency set wires a zero-copy buffer's pages: 1 GB the CPU has written (so its pages exist), in and out of the set, system wired memory read after each step
static void wire(void) {
    id<MTLComputePipelineState> poke = pipeline(k_small, "poke");
    size_t L = 1ull << 30; uint8_t *m = mmap(NULL, L, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0); memset(m, 1, L);
    uint64_t w[8]; const char *what[8] = {"before", "buffer made", "in the residency set", "a kernel wrote one word", "1 s later", "out of the set", "buffer gone", ""};
    usleep(500000); w[0] = wired();
    id<MTLBuffer> b = [D newBufferWithBytesNoCopy:m length:L options:MTLResourceStorageModeShared deallocator:nil]; usleep(300000); w[1] = wired();
    [RS addAllocation:b]; rs_commit(); usleep(300000); w[2] = wired();
    uint32_t v[2] = {0, 7}, *vp = v; NSError *err = nil;
    run(poke, 1, 1, @"poke", ^(id<MTLComputeCommandEncoder> e) { [e setBuffer:b offset:0 atIndex:0]; [e setBytes:vp length:8 atIndex:1]; }, &err);
    usleep(300000); w[3] = wired(); usleep(1000000); w[4] = wired();
    [RS removeAllocation:b]; rs_commit(); usleep(500000); w[5] = wired();
    b = nil; usleep(500000); w[6] = wired();
    printf("== 1 GB of written zero-copy memory: system wired MB relative to before:");
    for (int i = 1; i < 7; i++) printf(" %s %+.0f;", what[i], MB(w[i]) - MB(w[0]));
    printf(" (kernel %s)\n", err ? err.localizedDescription.UTF8String : "ok");
    munmap(m, L);
}

// Compile only (no GPU work, no lock needed): every variant's kernel at the given unroll and reads, with what the pipeline reports
static void msl(int argc, char **argv) {
    unsigned U = argc > 2 ? (unsigned)atoi(argv[2]) : 16, R = argc > 3 ? (unsigned)atoi(argv[3]) : 4;
    for (int v = 0; v < V_SPARSE; v++) { uint64_t t0 = now_ns(); NSString *src = chase_src(v, U, R); id<MTLComputePipelineState> p = pipeline(src, "chase");
        printf("%-7s unroll %u reads %u: %lu lines of MSL, compiled in %.0f ms, max threads/threadgroup %lu, execution width %lu\n", VARIANTS[v], U, R, (unsigned long)[src componentsSeparatedByString:@"\n"].count,
            (double)(now_ns() - t0) / 1e6, (unsigned long)p.maxTotalThreadsPerThreadgroup, (unsigned long)p.threadExecutionWidth);
        if (getenv("FLATVA_DUMP")) [src writeToFile:[NSString stringWithFormat:@"%s/%s_u%u_r%u.metal", getenv("FLATVA_DUMP"), VARIANTS[v], U, R] atomically:YES encoding:NSUTF8StringEncoding error:nil]; }
}

int main(int argc, char **argv) {
    @autoreleasepool {
        D = MTLCreateSystemDefaultDevice(); Q = [D newCommandQueue];
        MTLResidencySetDescriptor *rd = [MTLResidencySetDescriptor new]; rd.initialCapacity = 16384; NSError *err = nil;
        RS = [D newResidencySetWithDescriptor:rd error:&err]; if (!RS) { fprintf(stderr, "residency set: %s\n", err.localizedDescription.UTF8String); return 1; }
        [Q addResidencySet:RS];
        const char *what = argc > 1 ? argv[1] : "all";
        if (!strcmp(what, "limits") || !strcmp(what, "all")) limits();
        if (!strcmp(what, "chase") || !strcmp(what, "all")) { if (!strcmp(what, "all")) printf("\n"); chase(argc, argv); }
        if (!strcmp(what, "msl")) msl(argc, argv);
        else if (!strcmp(what, "wire")) wire();
        else if (!strcmp(what, "sharedheap")) sparse_probe(MTLStorageModeShared, pipeline(k_small, "probe"), [D newMTL4CommandQueue], [D newSharedEvent]);
        else if (strcmp(what, "limits") && strcmp(what, "chase") && strcmp(what, "all")) { fprintf(stderr, "usage: %s limits | chase [options] | all | msl [unroll] [reads] | sharedheap | wire\n", argv[0]); return 2; }
    }
    return 0;
}
