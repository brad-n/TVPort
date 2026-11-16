// HEVC sidecars of AV1 movies, decoded by VideoToolbox in place of the AV1 (docs/reference/movies.md, "AV1 movies as HEVC sidecars on the Apple TV"). The Apple TV 4K's A15 has no AV1
// decoder in hardware, so dav1d decodes the Switch 2's AV1 movies on its CPU, and a 1080p 60 fps movie fell behind its sound there; the A15 decodes HEVC in hardware. TVPort transcodes
// each AV1 movie of a game when it builds for the Apple TV (dm/tools/movie_hevc.py: one HEVC picture per AV1 temporal unit, no reordering) into one pack beside the game files, which the
// app names in DM_MOVIE_HEVC. The game still reads its WebM and submits each temporal unit to nn::codec (hle_codec_video.c), which never sees a file, so a unit is known by its bytes: the
// pack keys each one (mhevc_key) and holds the HEVC picture made from it. The decoder hands that picture over as the AV1 decoder would hers: NV12, the same size, with the unit's own time,
// one a unit, nothing held back, so the frame timing, the drain and the end of the stream are the AV1 path's (hle_codec_video.c cv_decode). A unit the pack does not hold goes to the AV1
// decoder (hle_movie_av1.c), which takes the stream from there until the next one.
// Identical units: a unit that only shows a frame decoded earlier is 3 bytes, and Ocarina of Time's 1,800-unit title loop holds 911 distinct ones. Each unit is first matched as the
// unit after the one before (the candidates below); only a jump (a new stream, a loop, a seek) is looked up in the whole pack, among the random access pictures, where a stream can start.
// Two movies that start with the same key frame give the same picture for it, so the candidates carry both until the units that follow tell them apart.
#include "hle.h"
#include <CommonCrypto/CommonDigest.h>
#include <VideoToolbox/VideoToolbox.h>
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <sys/stat.h>
#include <unistd.h>
#include "hle_movie_hevc.h"

typedef struct { uint64_t key, off; uint32_t size, av1, movie, flags; } mh_entry;   // the pack's tables (movie_hevc.py), little-endian as this host: size is the HEVC sample's, av1 the unit's
typedef struct { uint32_t first, count, w, h; uint64_t ps_off; uint32_t ps_size, pictures; uint64_t name_off; uint32_t name_len, zero; } mh_movie;
_Static_assert(sizeof(mh_entry) == 32 && sizeof(mh_movie) == 48, "the pack's table rows");
enum { MH_SYNC = 1, MH_NOPIC = 2, MH_CANDS = 16 };

static struct {
    int fd; uint32_t nm, ne;
    mh_movie *m; mh_entry *e; uint32_t *by_key;   // entries in key order (key, then size), for the mh_lookup of a jump
    char **name;
} g_pack = {-1};
static pthread_once_t g_pack_once = PTHREAD_ONCE_INIT;

struct mhevc {
    uint32_t cand[MH_CANDS]; int ncand;   // the entries the units since the last jump can be; the session decodes the first
    uint32_t movie, next;                 // the session's movie, and the entry whose sample it decodes next (UINT32_MAX: none)
    CMVideoFormatDescriptionRef fd; VTDecompressionSessionRef vs;
    CVPixelBufferRef got, locked;
    uint8_t *buf; size_t nbuf;
    uint64_t units, decoded, jumps; int red;
};

uint64_t mhevc_key(const uint8_t *p, size_t n, size_t *size) {
    size_t i = 0;
    while (i < n && (p[i] >> 3 & 15) == 2 && (p[i] & 2)) {   // a temporal delimiter with its size field
        size_t at = i + (p[i] & 4 ? 2 : 1), l = 0; uint64_t v = 0; int end = 0;
        while (!end && at + l < n && l < 8) { v |= (uint64_t)(p[at + l] & 0x7f) << (7 * l); end = !(p[at + l] & 0x80); l++; }
        if (!end || v > n - at - l) break;
        i = at + l + (size_t)v;
    }
    uint8_t d[CC_SHA256_DIGEST_LENGTH]; CC_SHA256(p + i, (CC_LONG)(n - i), d);
    uint64_t k; memcpy(&k, d, 8);
    *size = n - i;
    return k;
}
static int mh_by_key_cmp(const void *a, const void *b) {
    const mh_entry *x = &g_pack.e[*(const uint32_t *)a], *y = &g_pack.e[*(const uint32_t *)b];
    return x->key != y->key ? (x->key < y->key ? -1 : 1) : x->av1 != y->av1 ? (x->av1 < y->av1 ? -1 : 1) : *(const uint32_t *)a < *(const uint32_t *)b ? -1 : 1;
}
static int mh_read_at(int fd, void *p, size_t n, uint64_t off) {
    for (size_t got = 0; got < n;) { ssize_t r = pread(fd, (uint8_t *)p + got, n - got, (off_t)(off + got)); if (r <= 0) return 0; got += (size_t)r; }
    return 1;
}
static void mh_pack_load(void) {
    const char *path = getenv("DM_MOVIE_HEVC");
    if (!path || !*path || !strcmp(path, "0") || !strcmp(path, "off")) return;
    int fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0) { LOG("[movie] HEVC sidecars: no pack at %s (%s): AV1 movies decode as AV1", path, strerror(errno)); return; }
    uint8_t h[64]; struct stat st; uint32_t ver, nm, ne, q; uint64_t moff, eoff, size;
    if (fstat(fd, &st) || !mh_read_at(fd, h, sizeof h, 0) || memcmp(h, "DMHEVC01", 8)) {   // an older build's pack emptied by TVPort, or one cut off before its header
        LOG("[movie] HEVC sidecars: %s is not a complete pack: AV1 movies decode as AV1", path); close(fd); return;
    }
    memcpy(&ver, h + 8, 4); memcpy(&nm, h + 12, 4); memcpy(&ne, h + 16, 4); memcpy(&q, h + 20, 4); memcpy(&moff, h + 24, 8); memcpy(&eoff, h + 32, 8); memcpy(&size, h + 40, 8);
    mh_movie *m = NULL; mh_entry *e = NULL; uint32_t *bk = NULL; char **name = NULL; const char *bad = NULL;
    if (ver != 1) bad = "of another version";
    else if (size != (uint64_t)st.st_size) bad = "not the size its header says";
    else if (moff > size || (uint64_t)nm * sizeof *m > size - moff || eoff > size || (uint64_t)ne * sizeof *e > size - eoff) bad = "with tables past its end";
    else if (!(m = calloc(nm + 1, sizeof *m)) || !(e = calloc(ne + 1, sizeof *e)) || !(bk = calloc(ne + 1, sizeof *bk)) || !(name = calloc(nm + 1, sizeof *name))) bad = "too large for memory";
    else if (!mh_read_at(fd, m, nm * sizeof *m, moff) || !mh_read_at(fd, e, ne * sizeof *e, eoff)) bad = "unreadable";
    for (uint32_t i = 0; !bad && i < nm; i++) {
        if (m[i].first > ne || m[i].count > ne - m[i].first || m[i].ps_off > size || m[i].ps_size > size - m[i].ps_off || m[i].name_off > size || m[i].name_len > size - m[i].name_off) bad = "with a movie out of range";
        else if (!(name[i] = calloc(1, m[i].name_len + 1)) || !mh_read_at(fd, name[i], m[i].name_len, m[i].name_off)) bad = "unreadable";
    }
    for (uint32_t i = 0; !bad && i < ne; i++) {
        if (e[i].movie >= nm || i < m[e[i].movie].first || i >= m[e[i].movie].first + m[e[i].movie].count || e[i].off > size || e[i].size > size - e[i].off) bad = "with an entry out of range";
        bk[i] = i;
    }
    if (bad) {
        LOG("[RED] movie: the HEVC sidecar pack %s is %s: AV1 movies decode as AV1", path, bad);
        if (name) for (uint32_t i = 0; i < nm; i++) free(name[i]);
        free(m); free(e); free(bk); free(name); close(fd); return;
    }
    if (!ne) { LOG("[movie] HEVC sidecars: %s holds no movie: AV1 movies decode as AV1", path); for (uint32_t i = 0; i < nm; i++) free(name[i]); free(m); free(e); free(bk); free(name); close(fd); return; }
    g_pack.fd = fd; g_pack.nm = nm; g_pack.ne = ne; g_pack.m = m; g_pack.e = e; g_pack.by_key = bk; g_pack.name = name;
    qsort(bk, ne, sizeof *bk, mh_by_key_cmp);
    LOG("[movie] HEVC sidecars: %u movies, %u temporal units (quality %u), %s", nm, ne, q, path);
}

mhevc *mhevc_new(void) {
    pthread_once(&g_pack_once, mh_pack_load);
    if (g_pack.fd < 0) return NULL;
    mhevc *h = calloc(1, sizeof *h); if (!h) die("movie: HEVC sidecar decoder allocation failed");
    h->movie = h->next = UINT32_MAX;
    return h;
}
static void mh_unlock_picture(mhevc *h) { if (h->locked) { CVPixelBufferUnlockBaseAddress(h->locked, kCVPixelBufferLock_ReadOnly); CVPixelBufferRelease(h->locked); h->locked = NULL; } }
static void mh_session_close(mhevc *h) {
    if (h->vs) { VTDecompressionSessionWaitForAsynchronousFrames(h->vs); VTDecompressionSessionInvalidate(h->vs); CFRelease(h->vs); h->vs = NULL; }
    if (h->fd) { CFRelease(h->fd); h->fd = NULL; }
    if (h->got) { CVPixelBufferRelease(h->got); h->got = NULL; }
    h->movie = h->next = UINT32_MAX;
}
void mhevc_reset(mhevc *h) { if (h) { mh_unlock_picture(h); h->ncand = 0; } }   // the session stays: a stream that starts again decodes from its random access picture anyway
void mhevc_free(mhevc *h) {
    if (!h) return;
    if (h->units) LOG("[movie] HEVC sidecar: %llu temporal units shown from the pack, %llu pictures decoded, %llu jumps", (unsigned long long)h->units, (unsigned long long)h->decoded, (unsigned long long)h->jumps);
    mh_unlock_picture(h); mh_session_close(h); free(h->buf); free(h);
}
static void mh_on_frame(void *ref, void *src, OSStatus st, VTDecodeInfoFlags fl, CVImageBufferRef img, CMTime pts, CMTime dur) {
    (void)src; (void)fl; (void)pts; (void)dur; mhevc *h = ref;
    if (st || !img) { if (st && !h->red++) LOG("[RED] movie: HEVC sidecar decode error (VideoToolbox %d, first case)", (int)st); return; }
    if (h->got) CVPixelBufferRelease(h->got);
    h->got = CVPixelBufferRetain(img);
}
static int mh_grow(mhevc *h, size_t want) {
    if (h->nbuf >= want) return 1;
    uint8_t *p = realloc(h->buf, want); if (!p) return 0;
    h->buf = p; h->nbuf = want; return 1;
}
static int mh_session_open(mhevc *h, uint32_t mi) {
    mh_session_close(h);
    const mh_movie *m = &g_pack.m[mi];
    const uint8_t *ps[8]; size_t pn[8]; uint32_t count = 0;
    if (!mh_grow(h, m->ps_size) || !mh_read_at(g_pack.fd, h->buf, m->ps_size, m->ps_off) || m->ps_size < 4) return 0;
    memcpy(&count, h->buf, 4);
    size_t at = 4;
    for (uint32_t i = 0; i < count; i++) {
        uint32_t l; if (i >= 8 || at + 4 > m->ps_size) return 0;
        memcpy(&l, h->buf + at, 4); at += 4;
        if (l > m->ps_size - at) return 0;
        ps[i] = h->buf + at; pn[i] = l; at += l;
    }
    OSStatus st = CMVideoFormatDescriptionCreateFromHEVCParameterSets(NULL, count, ps, pn, 4, NULL, &h->fd);
    if (st) { if (!h->red++) LOG("[RED] movie: no format description for the HEVC sidecar of %s (%d)", g_pack.name[mi], (int)st); h->fd = NULL; return 0; }
    int32_t pf = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;   // NV12 at video range, as the AV1 decoder hands over (hle_movie_av1.c)
    CFNumberRef num = CFNumberCreate(NULL, kCFNumberSInt32Type, &pf);
    const void *k[] = {kCVPixelBufferPixelFormatTypeKey}, *v[] = {num};
    CFDictionaryRef attrs = CFDictionaryCreate(NULL, k, v, 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks); CFRelease(num);
    VTDecompressionOutputCallbackRecord cb = {mh_on_frame, h};
    st = VTDecompressionSessionCreate(NULL, h->fd, NULL, attrs, &cb, &h->vs); CFRelease(attrs);
    if (st) { if (!h->red++) LOG("[RED] movie: VideoToolbox cannot create an HEVC session for the sidecar of %s (%d)", g_pack.name[mi], (int)st); h->vs = NULL; return 0; }
    h->movie = mi;
    LOG("[movie] AV1 movie %s: its HEVC sidecar decodes (VideoToolbox, %u pictures %ux%u)", g_pack.name[mi], m->pictures, m->w, m->h);
    return 1;
}
// One sample through the session, synchronously: its picture is in h->got when this returns (no reordering: movie_hevc.py encodes without B frames)
static int mh_decode_sample(mhevc *h, uint32_t i) {
    const mh_entry *e = &g_pack.e[i];
    if (h->got) { CVPixelBufferRelease(h->got); h->got = NULL; }
    if (!mh_grow(h, e->size) || !mh_read_at(g_pack.fd, h->buf, e->size, e->off)) { if (!h->red++) LOG("[RED] movie: an HEVC sidecar sample could not be read (%u bytes)", e->size); return 0; }
    CMBlockBufferRef bb = NULL; CMSampleBufferRef sb = NULL; size_t ssz = e->size;
    OSStatus st = CMBlockBufferCreateWithMemoryBlock(NULL, h->buf, e->size, kCFAllocatorNull, NULL, 0, e->size, 0, &bb);   // the decode is synchronous: buf outlives it
    if (!st) st = CMSampleBufferCreateReady(NULL, bb, h->fd, 1, 0, NULL, 1, &ssz, &sb);
    if (!st) st = VTDecompressionSessionDecodeFrame(h->vs, sb, 0, NULL, NULL);
    if (sb) CFRelease(sb);
    if (bb) CFRelease(bb);
    if (!st && !h->got) { VTDecompressionSessionFinishDelayedFrames(h->vs); VTDecompressionSessionWaitForAsynchronousFrames(h->vs); }   // a decoder that held the picture back
    if (st || !h->got) { if (!h->red++) LOG("[RED] movie: an HEVC sidecar picture did not decode (%d, first case)", (int)st); return 0; }
    h->decoded++;
    return 1;
}
static int mh_matches(uint32_t i, uint64_t key, size_t size) { return g_pack.e[i].key == key && g_pack.e[i].av1 == size; }
// A jump: the random access pictures the unit can be, in pack order
static int mh_lookup(uint64_t key, size_t size, uint32_t *out) {
    size_t lo = 0, hi = g_pack.ne;
    while (lo < hi) {
        size_t mid = (lo + hi) / 2; const mh_entry *e = &g_pack.e[g_pack.by_key[mid]];
        if (e->key < key || (e->key == key && e->av1 < size)) lo = mid + 1; else hi = mid;
    }
    int n = 0;
    for (size_t i = lo; i < g_pack.ne && n < MH_CANDS && mh_matches(g_pack.by_key[i], key, size); i++) if (g_pack.e[g_pack.by_key[i]].flags & MH_SYNC) out[n++] = g_pack.by_key[i];
    return n;
}
int mhevc_decode(mhevc *h, const uint8_t *data, size_t n, int64_t ts, mav1_picture *out) {
    mh_unlock_picture(h);
    size_t size; uint64_t key = mhevc_key(data, n, &size);
    if (!size) return 0;   // temporal delimiters only
    uint32_t c[MH_CANDS]; int nc = 0;
    for (int i = 0; i < h->ncand; i++) {   // the unit after each candidate, where it mh_matches
        uint32_t x = h->cand[i] + 1; const mh_movie *m = &g_pack.m[g_pack.e[h->cand[i]].movie];
        if (x < m->first + m->count && mh_matches(x, key, size)) c[nc++] = x;
    }
    if (!nc && (nc = mh_lookup(key, size, c))) h->jumps++;
    h->ncand = nc;
    if (!nc) return -1;
    for (int i = 1; i < nc; i++) if (c[i] == h->next) { uint32_t t = c[0]; c[0] = c[i]; c[i] = t; break; }   // the session's own place, when it is one of them
    memcpy(h->cand, c, (size_t)nc * sizeof *c);
    uint32_t k = c[0]; const mh_entry *e = &g_pack.e[k];
    if (e->flags & MH_NOPIC) return 0;
    if (h->movie != e->movie && !mh_session_open(h, e->movie)) { h->ncand = 0; return -1; }
    if (h->next != k) {   // decode from the random access picture before it, or from where the session is when that is between the two
        uint32_t from = k, first = g_pack.m[e->movie].first;
        while (from > first && !(g_pack.e[from].flags & MH_SYNC)) from--;
        if (h->next != UINT32_MAX && h->next > from && h->next < k) from = h->next;
        for (uint32_t i = from; i < k; i++) if (!(g_pack.e[i].flags & MH_NOPIC) && !mh_decode_sample(h, i)) { h->ncand = 0; h->next = UINT32_MAX; return -1; }
    }
    if (!mh_decode_sample(h, k)) { h->ncand = 0; h->next = UINT32_MAX; return -1; }
    h->next = k + 1; h->units++;
    CVPixelBufferRef pb = h->got; h->got = NULL; h->locked = pb;
    CVPixelBufferLockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
    CFStringRef mx = CVBufferCopyAttachment(pb, kCVImageBufferYCbCrMatrixKey, NULL);
    *out = (mav1_picture){CVPixelBufferGetBaseAddressOfPlane(pb, 0), CVPixelBufferGetBaseAddressOfPlane(pb, 1), CVPixelBufferGetBytesPerRowOfPlane(pb, 0), CVPixelBufferGetBytesPerRowOfPlane(pb, 1),
                          (int)CVPixelBufferGetWidthOfPlane(pb, 0), (int)CVPixelBufferGetHeightOfPlane(pb, 0),
                          !mx || CFEqual(mx, kCVImageBufferYCbCrMatrix_ITU_R_709_2) ? 2 : CFEqual(mx, kCVImageBufferYCbCrMatrix_ITU_R_2020) ? 5 : 1, 0, ts};
    if (mx) CFRelease(mx);
    return 1;
}
