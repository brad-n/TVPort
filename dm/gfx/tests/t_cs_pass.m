// Compute dispatches between the clears and draws of one render target: the production replay with literal Metal shaders, read back on the GPU.
// DM_NVN_LAZY_CLEAR_WIDE: a clear waiting for its pass waits across texture binds, counters and a dispatch that touches none of its textures (one pass, the clear as its load action),
// and lands before a dispatch that samples it (the dispatch reads the cleared colour). DM_NVN_CS_HOIST_WIDE: a dispatch between two draws of one pass, with occlusion queries around them,
// runs ahead of the pass (one pass), also an indirect one; one that samples the colour attachment the first draw wrote stays between them (two passes, it reads the draw's colour).
// DM_NVN_EMPTY_SUB: a submission with no GPU work completes in order without a command buffer. DM_NVN_CUT_DISPATCH: a dispatch that ends a draw pass commits a segment.
// DM_NVN_ALIAS_DIRTY: a word written through one chunk of a large pool and read through another after a pass that writes nothing.
// The expectations follow the switches, so the check target runs it with each of them off and on.
#import <Foundation/Foundation.h>
#include "../nvn/nvn_mtl.m"
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t *g_mod; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int checks, failed;
#define CHECK(s,c) do { int ok=!!(c); checks++; failed+=!ok; printf("%s: %s\n",s,ok?"PASS":"FAIL"); } while(0)
typedef struct { uint8_t p[16384]; size_t n; } chain;
static void emit(chain *c, unsigned op, const void *a, size_t n) {
    size_t sz=(8+n+7)&~7ull; if(c->n+sz>sizeof c->p) abort();
    op_hdr h={op,(uint32_t)sz}; memcpy(c->p+c->n,&h,8);
    if(n) memcpy(c->p+c->n+8,a,n); c->n+=sz;
}
static tex_t texture(void) {
    static uint64_t serial=810000; serial++;
    tex_t t={.magic=MAGIC('T','E','X',0),.serial=serial,.off=(int64_t)serial<<20};
    t.d=(nvn_texdesc){.target=NVN_TEXTURE_TARGET_2D,.format=NVN_FORMAT_RGBA8,.width=8,.height=8,.depth=1,.levels=1,.samples=1};
    nvn_tex_layout(&t.d,&t.L); return t;
}
static void rt(chain *c, const tex_t *t) { p_set_rt r={.n=1}; r.color[0]=t; emit(c,OP_SET_RT,&r,sizeof r); }
static void bind(chain *c, const prog_t *p, int stages) { p_bind_program b={p,stages}; emit(c,OP_BIND_PROGRAM,&b,sizeof b); }
static void scissor(chain *c, int x, int w) { p_scissor s={x,0,w,8}; emit(c,OP_SCISSOR,&s,sizeof s); }
static void triangle(chain *c) { p_draw d={.prim=NVN_DRAW_PRIMITIVE_TRIANGLES,.count=3,.instances=1}; emit(c,OP_DRAW,&d,sizeof d); }
static void clear_blue(chain *c) { p_clear_color k={.index=0,.mask=0xf,.rgba={0,0,1,1}}; emit(c,OP_CLEAR_COLOR,&k,sizeof k); }
static void bind_tex(chain *c, int stage, int tid) { p_bind_handles b={.stage=stage,.first=0,.n=1}; b.h[0]=(uint64_t)tid; emit(c,OP_BIND_TEX,&b,sizeof b); }
static void query(chain *c, uint64_t addr) {   // an occlusion query reset and report, as Ocarina of Time puts around its draws
    uint64_t t=NVN_COUNTER_TYPE_SAMPLES_PASSED; emit(c,OP_RESET_COUNTER,&t,sizeof t);
    uint64_t r[2]={NVN_COUNTER_TYPE_SAMPLES_PASSED,addr}; emit(c,OP_REPORT_COUNTER,r,sizeof r);
}
static void reset(void) { state_reset(); memset(&R,0,sizeof R); g_csh_n=0; }
static uint64_t execute(chain *c) {
    emit(c,OP_END,NULL,0); reset(); mtl_sub_begin(); uint64_t p0=g_stat_pass; mtl_exec(c->p);
    uint64_t f=mtl_sub_commit(); CHECK("submission completes",mtl_wait(f,2000000000ull));
    mtl_drain(); CHECK("no GPU error",!mtl_last_commit_error()); return g_stat_pass-p0;
}
static void pixels(const tex_t *t, uint8_t out[64][4]) {
    id<MTLTexture> mt=tex_mtl(t); id<MTLBuffer> b=[g_dev newBufferWithLength:256 options:MTLResourceStorageModeShared];
    id<MTLCommandBuffer> cb=[g_q commandBuffer]; id<MTLBlitCommandEncoder> e=[cb blitCommandEncoder];
    [e copyFromTexture:mt sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(8,8,1) toBuffer:b destinationOffset:0 destinationBytesPerRow:32 destinationBytesPerImage:256];
    [e endEncoding]; [cb commit]; [cb waitUntilCompleted]; memcpy(out,b.contents,256);
}
static int halves(const tex_t *t, const uint8_t left[4], const uint8_t right[4]) {   // every pixel of the left half and the right half
    uint8_t px[64][4]; pixels(t,px); int bad=0;
    for(int y=0;y<8;y++) for(int x=0;x<8;x++) bad+=memcmp(px[8*y+x],x<4?left:right,4)!=0;
    return !bad;
}
static const uint8_t RED[4]={255,0,0,255}, BLUE[4]={0,0,255,255};
static prog_t pg, cw, cr, cc;   // the red draw; a dispatch writing 73 to a storage buffer; one writing the colour it reads from texture slot 0 there
static void *mem;
static void programs(id<MTLLibrary> lib) {
    pg.serial=920001; NvProg *p=[NvProg new]; p->sh[0]=[NvShader new]; p->sh[1]=[NvShader new];
    p->sh[0]->fn=[lib newFunctionWithName:@"v"]; p->sh[0]->stage=0; p->sh[1]->fn=[lib newFunctionWithName:@"red"]; p->sh[1]->stage=1;
    p->sh[1]->rf.color_known=1; p->sh[1]->rf.color_mask=1; serial_put(pg.serial,p);
    for(int k=0;k<2;k++) { prog_t *q=k?&cr:&cw; q->serial=920002+k;
        NvProg *c=[NvProg new]; NvShader *s=c->sh[5]=[NvShader new]; s->stage=5; s->rf.tg[0]=s->rf.tg[1]=s->rf.tg[2]=1;
        s->fn=[lib newFunctionWithName:k?@"compute_read":@"compute_one"]; s->ae=[s->fn newArgumentEncoderWithBufferIndex:0];
        s->rf.nb=1+k; s->rf.b[0]=(nvn_rbind){.kind=NVN_RB_SBUFP,.rw=1,.reg=0,.aid=0};
        if(k) s->rf.b[1]=(nvn_rbind){.kind=NVN_RB_TEX,.reg=0,.aid=1,.dtt=MTLTextureType2D};
        snprintf(s->key,sizeof s->key,"%s",k?"t_cs_pass_read":"t_cs_pass_write"); serial_put(q->serial,c); }
    { cc.serial=920004; NvProg *c=[NvProg new]; NvShader *s=c->sh[5]=[NvShader new]; s->stage=5; s->rf.tg[0]=s->rf.tg[1]=s->rf.tg[2]=1;   // copies a word 16 MB into storage buffer 0 to storage buffer 1
      s->fn=[lib newFunctionWithName:@"compute_copy"]; s->ae=[s->fn newArgumentEncoderWithBufferIndex:0];
      s->rf.nb=2; s->rf.b[0]=(nvn_rbind){.kind=NVN_RB_SBUFP,.reg=0,.aid=0}; s->rf.b[1]=(nvn_rbind){.kind=NVN_RB_SBUFP,.rw=1,.reg=1,.aid=1};
      snprintf(s->key,sizeof s->key,"t_cs_pass_copy"); serial_put(cc.serial,c); }
}
static void compute(chain *c, const prog_t *q, int indirect) {
    bind(c,q,32); p_bind_buf b={.stage=5,.index=0,.addr=(uint64_t)mem,.size=4}; emit(c,OP_BIND_SSBO,&b,sizeof b);
    uint32_t *args=(uint32_t *)((uint8_t *)mem+512); args[0]=args[1]=args[2]=1;
    p_dispatch d={.x=1,.y=1,.z=1}; if(indirect) { d.x=d.y=d.z=0; d.ind=(uint64_t)args; }
    emit(c,OP_DISPATCH,&d,sizeof d);
}
static void clears(void) {
    int wide=cpd_on(); printf("DM_NVN_LAZY_CLEAR_WIDE %d, lazy clears %d\n",wide,lc_on());
    tex_t t=texture(), other=texture(), unrelated=texture(); mtl_reg_tex(601,&t,NULL); mtl_reg_tex(602,&unrelated,NULL);
    for(int lazy=0;lazy<2;lazy++) {
        // The clear waits (lazy: in a group, after another target was set; else as the open targets' pending clear), a texture bind and an independent dispatch come before its pass
        chain c={0}; rt(&c,&t); clear_blue(&c); if(lazy) { rt(&c,&other); bind_tex(&c,1,602); }
        *(uint32_t *)mem=0; compute(&c,&cw,0); rt(&c,&t); bind(&c,&pg,3); scissor(&c,0,4); triangle(&c);
        uint64_t landed=g_lc_landed; uint64_t passes=execute(&c);
        CHECK(lazy?"lazy clear: one pass when it waits across the bind and the dispatch":"pending clear: one pass when it waits across the dispatch",!lc_on() || passes==(wide?1u:2u));
        CHECK("no clear-only pass with the switch",!wide || !lc_on() || g_lc_landed==landed);
        CHECK("the dispatch ran",*(uint32_t *)mem==73);
        CHECK("left half drawn red, right half the clear's blue",halves(&t,RED,BLUE));
    }
    // A dispatch that samples the cleared texture: the clear lands before it, and the dispatch reads blue
    chain c={0}; rt(&c,&t); clear_blue(&c); bind_tex(&c,5,601); *(uint32_t *)mem=0; compute(&c,&cr,0); rt(&c,&t); bind(&c,&pg,3); scissor(&c,0,4); triangle(&c);
    uint64_t passes=execute(&c);
    CHECK("a dispatch sampling the cleared texture: the clear lands first (two passes)",passes==2);
    CHECK("that dispatch read the cleared blue",*(uint32_t *)mem==0xffff0000u);
    CHECK("left half drawn red, right half blue",halves(&t,RED,BLUE));
    CHECK("cpd_free refuses the sampling dispatch",({ reset(); R.has_rt=1; R.rt.n=1; R.rt.color[0]=&t; R.clear_c[0]=1; S.tex[5][0]=601; p_dispatch d={.x=1,.y=1,.z=1}; !cpd_free(prog_get(&cr)->sh[5],&d); }));
    CHECK("cpd_free takes the writing dispatch",({ S.ssbo[5][0]=(typeof(S.ssbo[5][0])){.addr=(uint64_t)mem,.size=4}; p_dispatch d={.x=1,.y=1,.z=1}; cpd_free(prog_get(&cw)->sh[5],&d); }));
    CHECK("cpd_free refuses raw global memory",({ NvShader *s=prog_get(&cw)->sh[5]; s->rf.b[1]=(nvn_rbind){.kind=NVN_RB_GMEM}; s->rf.nb=2; p_dispatch d={.x=1,.y=1,.z=1}; int r=!cpd_free(s,&d); s->rf.nb=1; r; }));
    reset();
}
static void hoists(void) {
    int wide=cshw_on(); printf("DM_NVN_CS_HOIST %d, DM_NVN_CS_HOIST_WIDE %d\n",cshoist_on(),wide);
    tex_t t=texture(); mtl_reg_tex(603,&t,NULL); uint64_t qa=(uint64_t)mem+1024;
    for(int indirect=0;indirect<2;indirect++) {
        chain c={0}; rt(&c,&t); bind(&c,&pg,3); scissor(&c,0,4); query(&c,qa); triangle(&c); query(&c,qa+16);
        *(uint32_t *)mem=0; compute(&c,&cw,indirect); bind(&c,&pg,3); scissor(&c,4,4); query(&c,qa+32); triangle(&c);
        uint64_t moved=g_csh_moved; uint64_t passes=execute(&c);
        int expect=cshoist_on() && wide;
        CHECK(indirect?"independent indirect dispatch between queried draws: moved ahead with the switch":"independent dispatch between queried draws: moved ahead with the switch",g_csh_moved-moved==(uint64_t)expect);
        CHECK("one pass when it moves, two when it does not",passes==(expect?1u:2u));
        CHECK("the dispatch ran",*(uint32_t *)mem==73);
        CHECK("both halves drawn red",halves(&t,RED,RED));
    }
    // The pass begins with a clear: the dispatch moves ahead of it only when the clear can wait across it too (both switches), and the clear is the pass's load action either way
    { chain c={0}; rt(&c,&t); clear_blue(&c); bind(&c,&pg,3); scissor(&c,0,4); query(&c,qa); triangle(&c);
      *(uint32_t *)mem=0; compute(&c,&cw,0); bind(&c,&pg,3); scissor(&c,0,4); query(&c,qa+16); triangle(&c);
      uint64_t moved=g_csh_moved; uint64_t passes=execute(&c); int expect=cshoist_on() && wide && cpd_on();
      CHECK("a pass that begins with a clear: the dispatch moves only with both switches",g_csh_moved-moved==(uint64_t)expect && passes==(expect?1u:2u));
      CHECK("the dispatch ran",*(uint32_t *)mem==73);
      CHECK("left half red, right half the clear's blue",halves(&t,RED,BLUE)); }
    // The dispatch samples the colour attachment the first draw wrote: it stays between the draws and reads red
    chain c={0}; rt(&c,&t); bind(&c,&pg,3); scissor(&c,0,8); query(&c,qa); triangle(&c);
    bind_tex(&c,5,603); *(uint32_t *)mem=0; compute(&c,&cr,0); bind(&c,&pg,3); query(&c,qa+16); triangle(&c);
    uint64_t moved=g_csh_moved; uint64_t passes=execute(&c);
    CHECK("a dispatch sampling the pass's colour is not moved",g_csh_moved==moved && passes==2);
    CHECK("it read the first draw's red",*(uint32_t *)mem==0xff0000ffu);
    reset();
}
// DM_NVN_EMPTY_SUB: a submission with only an event signal after one with GPU work. With the switch it is not committed; its fence completes through the shared event's listener (no
// waiter runs it here: the test polls the completed fence), after the work before it, and its event write is visible then
static void empty_subs(void) {
    int on=empty_sub_on(); printf("DM_NVN_EMPTY_SUB %d\n",on);
    for(int k=0;k<12;k++) {   // the next submission records into the command buffer the empty one began; enough rounds for the allocators to be reset and reused
        chain a={0}; *(volatile uint32_t *)mem=0; compute(&a,&cw,0); emit(&a,OP_END,NULL,0);
        reset(); mtl_sub_begin(); mtl_exec(a.p); uint64_t f1=mtl_sub_commit();
        volatile uint32_t ev=0; chain b={0}; struct { uint64_t val; uint32_t mode, v; } sg={(uint64_t)(uintptr_t)&ev,0,47u+(uint32_t)k}; emit(&b,OP_SIGNAL_EVENT,&sg,sizeof sg); emit(&b,OP_END,NULL,0);
        uint64_t e0=g_empty_subs; mtl_sub_begin(); mtl_exec(b.p); uint64_t f2=mtl_sub_commit();
        CHECK("the event-only submission is not committed with the switch, committed without",g_empty_subs-e0==(uint64_t)on);
        for(int i=0;i<4000 && mtl_completed_fence()<f2;i++) usleep(500);
        CHECK("its fence completes without a waiter",mtl_completed_fence()>=f2 && f2==f1+1);
        CHECK("its event was written, after the earlier GPU work",ev==47u+(uint32_t)k && *(volatile uint32_t *)mem==73);
        CHECK("a wait on it returns",mtl_wait(f2,2000000000ull));
    }
    mtl_drain(); CHECK("no GPU error",!mtl_last_commit_error());
}
// DM_NVN_CUT_DISPATCH: a dispatch that ends a draw pass is a segment boundary. Two draws, a dispatch reading their colour, a draw: with the switch and DM_NVN_CUT=2 the command buffer is committed there
static void cuts(void) {
    int on=cut_dispatch_on(); printf("DM_NVN_CUT %d, DM_NVN_CUT_DISPATCH %d\n",cut_draws(),on);
    tex_t t=texture(); mtl_reg_tex(604,&t,NULL);   // the dispatch samples the pass's colour, so it is not moved ahead of the pass (DM_NVN_CS_HOIST)
    chain c={0}; rt(&c,&t); bind(&c,&pg,3); scissor(&c,0,8); triangle(&c); triangle(&c);
    bind_tex(&c,5,604); *(uint32_t *)mem=0; compute(&c,&cr,0); bind(&c,&pg,3); triangle(&c);
    for(int i=0;i<4000 && atomic_load(&g_seg_inflight);i++) usleep(500);   // the cut commits only with nothing in flight when segment timestamps are kept (sub_cut's busy rule)
    uint64_t cut0=g_cuts; execute(&c);
    CHECK("a cut at the dispatch with the switch (and DM_NVN_CUT <= 2), none without",g_cuts-cut0==(uint64_t)(on && cut_draws()>0 && cut_draws()<=2 && (cut_first()<=0 || cut_first()<=2)));
    CHECK("the dispatch read the draws' red",*(uint32_t *)mem==0xff0000ffu);
    CHECK("both halves drawn red",halves(&t,RED,RED));
}
// DM_NVN_ALIAS_DIRTY: a dispatch writes a word of a large pool (in chunks, BIG_MIN) through one chunk, a draw pass that writes no memory follows, and a dispatch reads the word through
// another chunk (bound 16 MB earlier): it reads what the first wrote, the pass's start barrier carried the flush, and with the switch later barriers went without it
static void aliases(void) {
    int on=alias_dirty_on(); printf("DM_NVN_ALIAS_DIRTY %d\n",on);
    const uint64_t GB=1ull<<30; uint8_t *big=mmap(NULL,GB,PROT_READ|PROT_WRITE,MAP_ANON|MAP_PRIVATE,-1,0); if(big==MAP_FAILED) abort();
    mtl_pool_add(big,GB); CHECK("the pool is held in chunks",atomic_load(&g_big_n)>0);
    uint64_t x=(uint64_t)(uintptr_t)big+(GB/2), y=x-BIG_S; *(volatile uint32_t *)(uintptr_t)x=0;
    void *b1=NULL,*b2=NULL; uint64_t o; mtl_gpu_addr(x,4,&b1,&o,&o); mtl_gpu_addr(y,BIG_S+4,&b2,&o,&o);
    CHECK("the two bindings reach the word through different buffers",b1 && b2 && b1!=b2);
    tex_t t=texture();
    chain c={0}; rt(&c,&t);
    bind(&c,&cw,32); p_bind_buf w={.stage=5,.index=0,.addr=x,.size=4}; emit(&c,OP_BIND_SSBO,&w,sizeof w); p_dispatch d={.x=1,.y=1,.z=1}; emit(&c,OP_DISPATCH,&d,sizeof d);
    bind(&c,&pg,3); scissor(&c,0,8); triangle(&c);
    uint32_t bits=NVN_BARRIER_ORDER_PRIMITIVES_BIT|NVN_BARRIER_INVALIDATE_SHADER_BIT; emit(&c,OP_BARRIER,&bits,sizeof bits);   // the game's order between the draw and the read (it also keeps the read after the pass)
    bind(&c,&cc,32); p_bind_buf r0={.stage=5,.index=0,.addr=y,.size=BIG_S+4}, r1={.stage=5,.index=1,.addr=(uint64_t)mem,.size=4};
    emit(&c,OP_BIND_SSBO,&r0,sizeof r0); emit(&c,OP_BIND_SSBO,&r1,sizeof r1); emit(&c,OP_DISPATCH,&d,sizeof d);
    bind(&c,&pg,3); triangle(&c); bind(&c,&pg,3); rt(&c,&t); triangle(&c);
    *(uint32_t *)mem=0; uint64_t skip0=g_alias_skip; execute(&c);
    CHECK("the second dispatch read the first one's word through the other chunk",*(volatile uint32_t *)mem==73);
    CHECK("with the switch some barriers went without the flush",!on || g_alias_skip>skip0);
    CHECK("both halves drawn red",halves(&t,RED,RED));
    mtl_pool_del(big); munmap(big,GB);
}
int main(void) { @autoreleasepool {
    alarm(60); setbuf(stdout,NULL); mtl_init();
    NSError *error=nil;
    id<MTLLibrary> lib=[g_dev newLibraryWithSource:@"#include <metal_stdlib>\nusing namespace metal;\n"
        "vertex float4 v(uint i [[vertex_id]]) { float2 p[3]={float2(-1,-1),float2(3,-1),float2(-1,3)}; return float4(p[i],0,1); }\n"
        "fragment float4 red() { return float4(1,0,0,1); }\n"
        "struct Args { device uint *p [[id(0)]]; };\n"
        "kernel void compute_one(constant Args &a [[buffer(0)]]) { *a.p=73; }\n"
        "struct ArgsT { device uint *p [[id(0)]]; texture2d<float> t [[id(1)]]; };\n"
        "kernel void compute_read(constant ArgsT &a [[buffer(0)]]) { *a.p=pack_float_to_unorm4x8(a.t.read(uint2(6,0))); }\n"
        "struct Args2 { device uint *p [[id(0)]]; device uint *q [[id(1)]]; };\n"
        "kernel void compute_copy(constant Args2 &a [[buffer(0)]]) { *a.q=a.p[4194304]; }\n" options:nil error:&error];
    if(!lib) { fprintf(stderr,"%s\n",error.localizedDescription.UTF8String); return 2; }
    if(posix_memalign(&mem,getpagesize(),getpagesize())) abort(); memset(mem,0,getpagesize()); mtl_pool_add(mem,getpagesize());
    programs(lib); clears(); hoists(); empty_subs(); cuts(); aliases();
    mtl_pool_del(mem); free(mem);
    printf("compute between clears and draws: %d checks, %d failed\n",checks,failed); return failed!=0;
} }
