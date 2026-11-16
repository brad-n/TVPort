// HEVC sidecars of AV1 movies (hle_movie_hevc.c) against the AV1 decoder they stand in for (hle_movie_av1.c), on movie_hevc_fixture.h (a 96x64 SVT-AV1 clip of 24 units and the pack
// dm/tools/movie_hevc.py made of it; no game data). The units go through mav1 as hle_codec_video.c sends them, once with the pack and once without (dav1d), and the two must give the same
// pictures in the same order with the same times and sizes, the pictures alike within the codec's loss. Then: a loop back to the first unit and a stream started at the second key frame
// (jumps), units only the AV1 decoder gets (one the pack does not hold, in the middle of a stream it was decoding: the AV1 decoder from the next key frame), a unit of temporal delimiters
// only, the key with and without a leading delimiter, and packs the loader refuses (cut off, another size, no magic).
#include "../hle.h"
#include "../hle_movie_av1.c"
#include "../hle_movie_hevc.c"
#include "movie_hevc_fixture.h"
#include <assert.h>
#include <math.h>
#include <stdio.h>

typedef struct { const uint8_t *p; size_t n; } unit;
static unit U[64]; static int NU;
typedef struct { int w, h, matrix; int64_t ts; uint8_t *y, *uv; } frame;   // a picture, its planes packed
static frame F_ref[128], F_got[128];

static int64_t ts_of(int i) { return 1000 + (int64_t)i * 16667; }
static frame copy(const mav1_picture *p) {
    frame f = {p->w, p->h, p->matrix, p->ts, malloc((size_t)p->w * p->h), malloc((size_t)p->w * p->h / 2)};
    assert(f.y && f.uv);
    for (int r = 0; r < p->h; r++) memcpy(f.y + (size_t)r * p->w, p->y + r * p->ystride, (size_t)p->w);
    for (int r = 0; r < p->h / 2; r++) memcpy(f.uv + (size_t)r * p->w, p->uv + r * p->uvstride, (size_t)p->w);
    return f;
}
static void drop(frame *f, int n) { for (int i = 0; i < n; i++) { free(f[i].y); free(f[i].uv); } }
// Units [from, to) through a, as cv_decode sends them: every picture a unit gives, then the drain at the end of the stream. *direct: how many came out of mav1_decode itself
static int run(mav1 *a, int from, int to, frame *out, int *direct) {
    int k = 0; mav1_picture p;
    if (direct) *direct = 0;
    for (int i = from; i < to; i++) {
        int r = mav1_decode(a, U[i].p, U[i].n, ts_of(i), &p);
        if (r == 1 && direct) (*direct)++;
        for (; r == 1; r = mav1_next(a, 0, &p)) out[k++] = copy(&p);
    }
    while (mav1_next(a, 1, &p) == 1) out[k++] = copy(&p);
    return k;
}
static double psnr(const frame *a, const frame *b) {   // over luma and chroma
    double se = 0; size_t n = (size_t)a->w * a->h;
    for (size_t i = 0; i < n; i++) { double d = (double)a->y[i] - b->y[i]; se += d * d; }
    for (size_t i = 0; i < n / 2; i++) { double d = (double)a->uv[i] - b->uv[i]; se += d * d; }
    double mse = se / (n * 1.5);
    return mse ? 10 * log10(255.0 * 255.0 / mse) : 99;
}
static double same_as_ref(const frame *got, int n, int ref0) {   // every picture as the reference's from ref0 on: time, size, matrix; returns the lowest PSNR
    double low = 99;
    for (int i = 0; i < n; i++) {
        const frame *r = &F_ref[ref0 + i];
        assert(got[i].ts == r->ts && got[i].w == r->w && got[i].h == r->h && got[i].matrix == r->matrix);
        double p = psnr(&got[i], r); if (p < low) low = p;
    }
    return low;
}
static void write_file(const char *path, const void *p, size_t n) { FILE *f = fopen(path, "wb"); assert(f && fwrite(p, 1, n, f) == n); fclose(f); }

int main(void) {
    for (size_t at = 32; at + 12 <= sizeof fixture_ivf;) {   // IVF: a 32-byte header, then each unit with its size (u32) and time (u64)
        uint32_t n; memcpy(&n, fixture_ivf + at, 4); assert(at + 12 + n <= sizeof fixture_ivf && NU < 64);
        U[NU++] = (unit){fixture_ivf + at + 12, n}; at += 12 + n;
    }
    assert(NU == FIXTURE_FRAMES);
    char pack[] = "/tmp/t_movie_hevc.XXXXXX"; int fd = mkstemp(pack); assert(fd >= 0); close(fd);
    write_file(pack, fixture_pack, sizeof fixture_pack);
    setenv("DM_MOVIE_HEVC", pack, 1);
    setenv("DM_AV1_DAV1D", "1", 1);   // the reference: dav1d, the decoder the Apple TV has for AV1

    // The key: the IVF's units carry a temporal delimiter the WebM's (which the pack was keyed from) do not
    size_t s1, s2; assert(U[0].p[0] == 0x12 && U[0].p[1] == 0);
    assert(mhevc_key(U[0].p, U[0].n, &s1) == mhevc_key(U[0].p + 2, U[0].n - 2, &s2) && s1 == s2 && s1 == U[0].n - 2);
    assert(mhevc_key(U[0].p, 2, &s1) && s1 == 0);

    // The reference: the AV1 decoder alone
    mav1 *ref = mav1_new(); assert(ref->hevc); mhevc_free(ref->hevc); ref->hevc = NULL;
    assert(!strcmp(mav1_backend(ref), "dav1d"));
    int nref = run(ref, 0, NU, F_ref, NULL);
    assert(nref == NU);
    for (int i = 0; i < nref; i++) assert(F_ref[i].ts == ts_of(i) && F_ref[i].w == 96 && F_ref[i].h == 64);

    // The pack: the same pictures, each out of its own unit's decode (nothing for the drain), with the unit's time
    mav1 *a = mav1_new(); assert(a->hevc && !strcmp(mav1_backend(a), "HEVC sidecars, else dav1d"));
    assert(g_pack.nm == 1 && g_pack.ne == (uint32_t)NU);
    int distinct = 0;
    for (uint32_t i = 0; i < g_pack.ne; i++) { int seen = 0; for (uint32_t j = 0; j < i; j++) seen |= g_pack.e[j].key == g_pack.e[i].key; distinct += !seen; }
    int direct, n = run(a, 0, NU, F_got, &direct);
    assert(n == NU && direct == NU && !a->hevc_off && a->hevc->units == (uint64_t)NU && a->hevc->jumps == 1);
    double low = same_as_ref(F_got, n, 0);
    printf("t_movie_hevc: %d units (%d distinct), the pack's pictures as dav1d's: same times and sizes, PSNR %.1f dB at the lowest\n", NU, distinct, low);
    assert(low >= 30);
    drop(F_got, n);

    // A loop: the first unit again, with no flush (a jump back to the random access picture)
    n = run(a, 0, NU, F_got, &direct);
    assert(n == NU && direct == NU && a->hevc->jumps == 2 && same_as_ref(F_got, n, 0) >= 30);
    drop(F_got, n);
    // A stream that starts at the second key frame (a seek): the pack's IDR there
    mav1_reset(a);
    n = run(a, FIXTURE_KEYINT, NU, F_got, &direct);
    assert(n == NU - FIXTURE_KEYINT && direct == n && a->hevc->jumps == 3 && same_as_ref(F_got, n, FIXTURE_KEYINT) >= 30);
    drop(F_got, n);
    // A unit of temporal delimiters only: no picture, and the pack goes on
    mav1_picture p;
    assert(mav1_decode(a, U[0].p, 2, 5, &p) == 0 && !a->hevc_off);

    // A unit the pack does not hold, in the middle of a stream it was decoding: no picture until the next key frame, from where dav1d decodes, as the reference did
    mav1_reset(a);
    uint8_t bad[4096]; int mid = FIXTURE_KEYINT / 2; assert(U[mid].n <= sizeof bad);
    memcpy(bad, U[mid].p, U[mid].n); bad[U[mid].n - 1] ^= 0x55;
    n = 0;
    for (int i = 0; i < NU; i++) {
        int r = mav1_decode(a, i == mid ? bad : U[i].p, U[i].n, ts_of(i), &p);
        if (i >= mid && i < FIXTURE_KEYINT) assert(r == 0 && a->hevc_off);
        for (; r == 1; r = mav1_next(a, 0, &p)) F_got[n++] = copy(&p);
    }
    while (mav1_next(a, 1, &p) == 1) F_got[n++] = copy(&p);
    assert(n == NU - (FIXTURE_KEYINT - mid) && same_as_ref(F_got, mid, 0) >= 30);
    for (int i = mid; i < n; i++) { const frame *r = &F_ref[FIXTURE_KEYINT + i - mid]; assert(F_got[i].ts == r->ts && psnr(&F_got[i], r) == 99); }   // dav1d's own pictures
    drop(F_got, n);
    mav1_reset(a);   // a new stream: the pack again
    n = run(a, 0, 3, F_got, &direct); assert(n == 3 && direct == 3 && !a->hevc_off);
    drop(F_got, n);
    mav1_free(a); mav1_free(ref); drop(F_ref, nref);

    // Packs the loader refuses: cut off, a header that says another size, no magic (an earlier build's pack TVPort emptied)
    __typeof__(g_pack) good = g_pack;
    char cut[] = "/tmp/t_movie_hevc_cut.XXXXXX"; fd = mkstemp(cut); assert(fd >= 0); close(fd);
    uint8_t copy_of[sizeof fixture_pack]; memcpy(copy_of, fixture_pack, sizeof copy_of);
    setenv("DM_MOVIE_HEVC", cut, 1);
    for (int k = 0; k < 4; k++) {
        size_t len = sizeof copy_of;
        if (k == 0) len = sizeof copy_of - 100;
        if (k == 1) { uint64_t sz = sizeof copy_of + 8; memcpy(copy_of + 40, &sz, 8); }
        if (k == 2) { memcpy(copy_of, fixture_pack, sizeof copy_of); memset(copy_of, 0, 8); }
        if (k == 3) len = 0;
        write_file(cut, copy_of, len);
        g_pack.fd = -1; mh_pack_load(); assert(g_pack.fd < 0);
    }
    setenv("DM_MOVIE_HEVC", "0", 1); g_pack.fd = -1; mh_pack_load(); assert(g_pack.fd < 0);
    g_pack = good;
    unlink(cut); unlink(pack);
    printf("t_movie_hevc: loops, a seek, a unit the pack does not hold and refused packs: ok\n");
    return 0;
}
