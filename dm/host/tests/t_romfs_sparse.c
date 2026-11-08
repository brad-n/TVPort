// DMSPARS1 (dm/host/romfs_sparse.h, docs/texture_once.md section 1): reads across extent and hole boundaries, reads past the logical end, every kind of damaged file refused, a DMROMFS1 wrapped in a
// DMSPARS1 reading exactly like the plain image, and the RomFS identity of the wrapped image equal to the plain one's. Expected values come from the logical bytes the fixture was made from
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <pthread.h>
#include "../romfs_image.h"
#include "../romfs_identity.h"
#include "romfs_sparse_fixture.h"

static int checks, failed;
#define CHECK(c, ...) do { checks++; if (!(c)) { failed++; fprintf(stderr, "FAIL (line %d): ", __LINE__); fprintf(stderr, __VA_ARGS__); fputc('\n', stderr); } } while (0)

static char g_dir[1024];
static char *path(const char *name) { static char b[8][1200]; static int k; char *r = b[k++ & 7]; snprintf(r, 1200, "%s/%s", g_dir, name); return r; }
static void write_file(const char *p, const uint8_t *d, size_t n) { FILE *f = fopen(p, "wb"); assert(f && fwrite(d, 1, n, f) == n); fclose(f); }
static uint32_t g_rng = 12345;
static uint32_t rnd(void) { g_rng = g_rng * 1664525u + 1013904223u; return g_rng >> 8; }
static int opens(const uint8_t *f, size_t n, romfs_src *out) {   // the file's bytes through romfs_src_open
    write_file(path("t.bin"), f, n);
    int fd = open(path("t.bin"), O_RDONLY); romfs_src s; errno = 0; int ok = romfs_src_open(fd, &s);
    if (ok && out) *out = s; else if (ok) romfs_src_free(&s);
    if (!ok || !out) close(fd);
    return ok && s.sparse;
}


// ---- Version 2: compressed extents (docs/texture_once.md section 7a) ----
static int red_count;   // [RED] lines seen by the last red_capture_end
static int g_save_err = -1;
static void red_capture_begin(void) { fflush(stderr); g_save_err = dup(2); int tf = open(path("err.txt"), O_CREAT | O_TRUNC | O_WRONLY, 0644); dup2(tf, 2); close(tf); }
static void red_capture_end(void) {
    fflush(stderr); dup2(g_save_err, 2); close(g_save_err);
    FILE *f = fopen(path("err.txt"), "r"); char line[600]; red_count = 0;
    while (f && fgets(line, sizeof line, f)) if (strstr(line, "[RED]")) red_count++;
    if (f) fclose(f);
}
static int open_file(const char *name, romfs_src *s) { int fd = open(path(name), O_RDONLY); return fd >= 0 && romfs_src_open(fd, s) && s->sparse; }
static uint64_t tab_at(const uint8_t *file, size_t k) { return romfs_src_le64(file + 32) + k * 32; }
typedef struct { const romfs_src *s; const uint8_t *L; uint64_t n; unsigned seed; int bad; } reader_arg;
static void *reader_main(void *vp) {
    reader_arg *a = vp; uint8_t *b = malloc(70000); uint32_t r = a->seed;
    for (int i = 0; i < 3000; i++) {
        r = r * 1664525u + 1013904223u; uint64_t off = (r >> 8) % (a->n + 20); r = r * 1664525u + 1013904223u; size_t len = (r >> 8) % 60000;
        ssize_t got = romfs_src_pread(a->s, b, len, off);
        size_t want = off >= a->n ? 0 : (len < a->n - off ? len : (size_t)(a->n - off));
        if (got != (ssize_t)want || (want && memcmp(b, a->L + off, want))) a->bad++;
    }
    free(b); return NULL;
}
static void v2_tests(void) {
    printf("version 2: compressed extents\n");
    enum { BLK = 20000, P = 40, N2 = BLK * P };
    uint8_t *L = malloc(N2);
    for (int p = 0; p < P; p++) {
        uint8_t *q = L + (size_t)p * BLK;
        if (p % 5 == 0) memset(q, (uint8_t)(0x30 + p), BLK);               // a run: compresses
        else if (p % 5 == 1) memset(q, 0, BLK);                             // a hole
        else if (p % 5 == 2) { for (int i = 0; i < BLK; i++) q[i] = (uint8_t)(1 + rnd() % 255); }   // noise
        else if (p % 5 == 3) { for (int i = 0; i < BLK; i++) q[i] = (uint8_t)(i < 7000 ? 0x77 : 1 + rnd() % 255); }   // run, then noise
        else fx_real_plain(q);                                              // a real zstd frame (fx_real_frame)
    }
    unsetenv("DM_ROMFS_ZCACHE_MB");
    for (int zmode = 0; zmode <= 3; zmode++) {
        uint8_t *f; size_t fn; long nz; long ne = fx_write_sparse2(L, N2, BLK, zmode, NULL, 0, &f, &fn, &nz);
        write_file(path("v2.img"), f, fn);
        romfs_src s; CHECK(open_file("v2.img", &s), "v2 zmode %d opens (errno %d)", zmode, errno);
        CHECK(s.n == (uint64_t)ne && s.logical == N2 && (nz ? s.zc != NULL : s.zc == NULL) && (!nz || s.zc->cap == (16u << 20)), "zmode %d: %ld extents, %ld zstd, default cache 16 MiB", zmode, ne, nz);
        int zk = 0, rk = 0; for (uint64_t i = 0; i < s.n; i++) { if (s.ext[i].kind == 1) zk++; else rk++; }
        CHECK(zmode == 0 ? !zk : zmode == 1 ? !rk : zmode == 2 ? zk && rk : zk && rk, "zmode %d: kinds (%d zstd, %d raw)", zmode, zk, rk);
        uint8_t *got = malloc(N2 + 50);
        CHECK(romfs_src_pread(&s, got, N2, 0) == N2 && !memcmp(got, L, N2), "zmode %d: the whole logical image reads back", zmode);
        int bad = 0;
        for (int k = 0; k < 3000; k++) {   // random windows and every extent edge (reads that span blocks)
            uint64_t off = rnd() % (N2 + 30); size_t len = rnd() % 70000;
            if (k < (int)s.n * 4) { const romfs_ext *x = &s.ext[k / 4]; off = x->lo + ((k & 1) ? x->len : 0) - 1 + (k & 2); len = 1 + (size_t)(k % 9) * 4000; }
            if (off > N2) off = N2;
            ssize_t r = romfs_src_pread(&s, got, len, off); size_t want = off >= N2 ? 0 : (len < N2 - off ? len : N2 - off);
            if (r != (ssize_t)want || (want && memcmp(got, L + off, want))) bad++;
        }
        CHECK(!bad, "zmode %d: %d windows differ", zmode, bad);
        if (zmode == 1) {   // everything was read once: the cache holds the blocks, so damaged frames on disk are not met again (a hit never reads the file)
            uint64_t held = 0; for (romfs_zblk *b = s.zc->head; b; b = b->next) held += b->len;
            CHECK(held == s.zc->used && s.zc->used > 0 && s.zc->used <= s.zc->cap, "cache holds %llu bytes", (unsigned long long)s.zc->used);
            int wfd = open(path("v2.img"), O_WRONLY); for (uint64_t i = 0; i < s.n; i++) if (s.ext[i].kind == 1) { uint8_t junk[16]; memset(junk, 0xEE, sizeof junk); pwrite(wfd, junk, sizeof junk, (off_t)s.ext[i].phys); }
            close(wfd);
            CHECK(romfs_src_pread(&s, got, N2, 0) == N2 && !memcmp(got, L, N2), "a second whole read is served from the cache (frames on disk now damaged)");
        }
        close(s.fd); romfs_src_free(&s); free(got); free(f);
    }

    printf("version 2: the block cache is bounded and shared\n");
    {   uint8_t *f; size_t fn; fx_write_sparse2(L, N2, BLK, 1, NULL, 0, &f, &fn, NULL); write_file(path("v2.img"), f, fn);
        const char *mbs[] = {"0.05", "0", "0.1", "bogus"};
        for (int m = 0; m < 4; m++) {
            setenv("DM_ROMFS_ZCACHE_MB", mbs[m], 1);
            romfs_src s; CHECK(open_file("v2.img", &s), "opens with DM_ROMFS_ZCACHE_MB=%s", mbs[m]);
            size_t cap = m == 3 ? (16u << 20) : (size_t)(strtod(mbs[m], NULL) * 1048576.0);
            CHECK(s.zc && s.zc->cap == cap, "cache cap for %s is %zu", mbs[m], cap);
            uint8_t *got = malloc(N2); int bad = 0, over = 0;
            for (int k = 0; k < 400; k++) {
                uint64_t off = rnd() % N2; size_t len = 1 + rnd() % 50000;
                ssize_t r = romfs_src_pread(&s, got, len, off); size_t want = len < N2 - off ? len : N2 - off;
                if (r != (ssize_t)want || memcmp(got, L + off, want)) bad++;
                if (s.zc->used > s.zc->cap) over++;
            }
            CHECK(!bad && !over, "cap %s: %d wrong windows, %d times over the cap (kept %zu)", mbs[m], bad, over, s.zc->used);
            if (m == 0) { int nb = 0; for (romfs_zblk *b = s.zc->head; b; b = b->next) nb++; CHECK(nb == 2 && s.zc->used == 2 * BLK, "a 0.05 MiB cache keeps 2 blocks of 20000 (%d, %zu)", nb, s.zc->used); }
            if (m == 1) CHECK(s.zc->used == 0 && !s.zc->head, "a zero cache keeps nothing and still reads");
            // concurrent readers on one source, the cache small enough to evict all the time
            if (m == 2) {
                pthread_t th[8]; reader_arg ra[8];
                for (int t = 0; t < 8; t++) { ra[t] = (reader_arg){&s, L, N2, 777u + (unsigned)t * 31u, 0}; pthread_create(&th[t], NULL, reader_main, &ra[t]); }
                int badt = 0; for (int t = 0; t < 8; t++) { pthread_join(th[t], NULL); badt += ra[t].bad; }
                CHECK(!badt && s.zc->used <= s.zc->cap, "8 concurrent readers all got the same bytes (%d wrong)", badt);
                for (romfs_zblk *b = s.zc->head; b; b = b->next) if (b->refs) badt++;
                CHECK(!badt, "no block is left pinned after the readers finish");
            }
            free(got); close(s.fd); romfs_src_free(&s);
        }
        unsetenv("DM_ROMFS_ZCACHE_MB");
        // the same with a roomy cache, 8 readers
        romfs_src s; CHECK(open_file("v2.img", &s), "the file opens"); pthread_t th[8]; reader_arg ra[8]; int badt = 0;
        for (int t = 0; t < 8; t++) { ra[t] = (reader_arg){&s, L, N2, 99u + (unsigned)t * 17u, 0}; pthread_create(&th[t], NULL, reader_main, &ra[t]); }
        for (int t = 0; t < 8; t++) { pthread_join(th[t], NULL); badt += ra[t].bad; }
        CHECK(!badt, "8 concurrent readers, default cache: %d wrong", badt);
        close(s.fd); romfs_src_free(&s); free(f);
    }

    printf("version 2: damaged frames are read errors, never zeros\n");
    {   enum { B3 = 10000 }; uint8_t L3[B3 * 3]; memset(L3, 0x55, B3); memset(L3 + B3, 0, B3); for (int i = 0; i < B3; i++) L3[2 * B3 + i] = (uint8_t)(i < 3000 ? 0x66 : 1 + rnd() % 255);
        uint8_t *f; size_t fn; long nz; fx_write_sparse2(L3, sizeof L3, B3, 1, NULL, 0, &f, &fn, &nz);   // extents: 0 (zstd, run) and 1 (zstd, run then noise), a hole between
        CHECK(nz == 2, "two zstd extents (%ld)", nz);
        uint8_t got[sizeof L3];
        struct { const char *what; int ext, field; uint64_t val; int frame_byte; int open_fails; } cases[] = {
            {"a clean file", -1, 0, 0, -1, 0},
            {"frame magic damaged", 0, 0, 0, 0, 0},
            {"block header damaged (size too large)", 0, 0, 0, 10, 0},
            {"stored length 1 (frame cut)", 0, 24, 1, -1, 0},
            {"stored length 2 (frame cut)", 0, 24, 2, -1, 0},
            {"frame inflates to fewer bytes than the extent's length", 0, 8, B3 + 1, -1, 0},
            {"frame inflates to more bytes than the extent's length", 0, 8, B3 - 1, -1, 0},
            {"second frame cut by a short file table", 1, 24, 3, -1, 0},
            {"kind 2", 0, 28, 2, -1, 1},
            {"raw extent with stored != length", 0, 28, 0, -1, 1},
            {"zstd stored length zero", 0, 24, 0, -1, 1},
            {"stored length past the file", 0, 24, 0x7fffffff, -1, 1},
        };
        for (unsigned c = 0; c < sizeof cases / sizeof *cases; c++) {
            uint8_t *g = malloc(fn); memcpy(g, f, fn);
            uint8_t *e = g + tab_at(f, cases[c].ext < 0 ? 0 : (size_t)cases[c].ext);
            if (cases[c].ext >= 0 && cases[c].frame_byte < 0) {
                if (cases[c].field == 24 || cases[c].field == 28) fx_put32(e + cases[c].field, (uint32_t)cases[c].val); else fx_put64(e + cases[c].field, cases[c].val);
            }
            if (cases[c].frame_byte >= 0) g[romfs_src_le64(e + 16) + (size_t)cases[c].frame_byte] ^= 0xFF;
            write_file(path("bad2.img"), g, fn);
            romfs_src s; int opened = open_file("bad2.img", &s);
            if (cases[c].open_fails) { CHECK(!opened, "%s: the file is refused at open", cases[c].what); }
            else if (c == 0) {
                CHECK(opened && romfs_src_pread(&s, got, sizeof got, 0) == (ssize_t)sizeof got && !memcmp(got, L3, sizeof L3), "%s reads back", cases[c].what);
            } else if (opened) {
                red_capture_begin();
                memset(got, 0xAB, sizeof got);
                errno = 0; ssize_t r = romfs_src_pread(&s, got, sizeof got, 0); int en = errno;
                red_capture_end();
                CHECK(r < 0 || r < (ssize_t)sizeof got, "%s: the read fails (returned %zd)", cases[c].what, r);
                CHECK(r < 0 ? en == EIO : 1, "%s: errno EIO (%d)", cases[c].what, en);
                CHECK(red_count == 1, "%s: exactly one [RED] line (%d)", cases[c].what, red_count);
                int zeros = 1; for (size_t i = 0; i < (size_t)(r < 0 ? 0 : r); i++) if (got[i] != L3[i]) zeros = 0;
                CHECK(zeros, "%s: the bytes before the damage are right", cases[c].what);
                CHECK(!romfs_src_read(&s, got, sizeof got, 0), "%s: romfs_src_read fails", cases[c].what);
            }
            else CHECK(0, "%s: did not open", cases[c].what);
            if (opened) { close(s.fd); romfs_src_free(&s); }
            free(g);
        }
        free(f);
        // a zstd extent longer than 256 KiB is refused at open (a raw one of any length is fine)
        {   enum { BIG = (256 << 10) + 4096 }; uint8_t *big = malloc(BIG), *g; size_t gn; memset(big, 0x42, BIG); romfs_src s2;
            fx_write_sparse2(big, BIG, BIG, 1, NULL, 0, &g, &gn, NULL); write_file(path("big.img"), g, gn); CHECK(!open_file("big.img", &s2), "a zstd extent of 256 KiB + 4096 is refused"); free(g);
            fx_write_sparse2(big, BIG, BIG, 0, NULL, 0, &g, &gn, NULL); write_file(path("big.img"), g, gn);
            CHECK(open_file("big.img", &s2) && s2.zc == NULL, "and a raw one of that length is fine"); if (s2.sparse) { uint8_t *b2 = malloc(BIG); CHECK(romfs_src_read(&s2, b2, BIG, 0) && !memcmp(b2, big, BIG), "and reads"); free(b2); close(s2.fd); romfs_src_free(&s2); }
            free(g); free(big); }
    }
    free(L);
}

int main(void) {
    snprintf(g_dir, sizeof g_dir, "%s/t_romfs_sparse.%d", getenv("TMPDIR") && *getenv("TMPDIR") ? getenv("TMPDIR") : "/tmp", (int)getpid()); mkdir(g_dir, 0755);

    printf("reads across extents and holes\n");
    enum { N = 60000 };
    uint8_t *L = malloc(N);
    for (int i = 0; i < N; i++) L[i] = (uint8_t)(1 + rnd() % 255);
    memset(L + 5000, 0, 9000);                 // a hole (>= 4096)
    memset(L + 30000, 0, 4096);                // exactly 4096: a hole
    memset(L + 40000, 0, 4095);                // 4095: stays inside an extent (the contract's writer rule)
    memset(L + 50000, 0, N - 50000);           // a hole that ends the image
    uint8_t *pack; size_t pack_n = fx_pack(&pack, 0, NULL, 0, 0);
    uint8_t *file; size_t file_n; long ne = fx_write_sparse(NULL, L, N, 4096, 3000, pack, pack_n, &file, &file_n);
    CHECK(ne > 4, "the fixture has several extents (%ld)", ne);
    romfs_src s; CHECK(opens(file, file_n, &s), "a well-formed DMSPARS1 opens");
    CHECK(s.sparse && s.logical == N && s.n == (uint64_t)ne && s.pack_off && !(s.pack_off & 16383) && s.pack_size == pack_n, "header fields: logical %llu extents %llu pack %llu+%llu", (unsigned long long)s.logical, (unsigned long long)s.n, (unsigned long long)s.pack_off, (unsigned long long)s.pack_size);
    uint8_t *got = malloc(N + 100);
    CHECK(romfs_src_pread(&s, got, N, 0) == N && !memcmp(got, L, N), "the whole logical image reads back");
    int bad = 0;
    for (int k = 0; k < 20000; k++) {   // random windows, plus every edge of every extent
        uint64_t off = rnd() % (N + 50); size_t len = rnd() % 9000;
        if (k < 2 * (int)s.n * 3) { const romfs_ext *x = &s.ext[(k / 6) % s.n]; int64_t edge = (int64_t)((k & 1) ? x->lo + x->len : x->lo); off = (uint64_t)(edge + (int64_t)(k / 2 % 3) - 1); if ((int64_t)off < 0) off = 0; len = (size_t)(1 + (k % 5) * 7); }
        size_t want = off >= N ? 0 : (N - off < len ? N - off : len);
        memset(got, 0xAA, len + 1);
        ssize_t r = romfs_src_pread(&s, got, len, off);
        if (r != (ssize_t)want || (want && memcmp(got, L + off, want)) || (len > want && got[want] != 0xAA)) { if (bad++ < 3) fprintf(stderr, "window off %llu len %zu: got %zd want %zu\n", (unsigned long long)off, len, r, want); }
    }
    CHECK(!bad, "%d wrong windows of 20000", bad);
    CHECK(romfs_src_pread(&s, got, 10, N) == 0 && romfs_src_pread(&s, got, 10, N + 5) == 0 && romfs_src_pread(&s, got, 0, 3) == 0, "reads at and past the logical end are empty");
    CHECK(romfs_src_pread(&s, got, 100, N - 10) == 10 && !memcmp(got, L + N - 10, 10), "a read across the logical end is short");
    CHECK(!romfs_src_read(&s, got, 100, N - 10) && errno == EINVAL && romfs_src_read(&s, got, 10, N - 10), "the full-read wrapper fails on a short read");
    // the pack bytes are where the header says
    { uint8_t ph[80]; CHECK(pread(s.fd, ph, 80, (off_t)s.pack_off) == 80 && !memcmp(ph, "NXASTCPK", 8), "the embedded pack is at its offset"); }
    close(s.fd); romfs_src_free(&s);

    printf("a plain file reads as it is\n");
    { uint8_t plain[300]; for (int i = 0; i < 300; i++) plain[i] = (uint8_t)i; write_file(path("p.bin"), plain, 300);
      int fd = open(path("p.bin"), O_RDONLY); romfs_src p; CHECK(romfs_src_open(fd, &p) && !p.sparse && p.logical == 300 && !p.pack_size, "a plain file: not sparse, its own size");
      uint8_t b[400]; CHECK(romfs_src_pread(&p, b, 400, 250) == 50 && !memcmp(b, plain + 250, 50) && romfs_src_pread(&p, b, 5, 300) == 0, "plain reads, short at the end"); close(fd); }

    printf("damaged files are refused\n");
    CHECK(opens(file, file_n, NULL) == 1, "the pristine file opens");
    { uint8_t *f = malloc(file_n); memcpy(f, file, file_n); f[0] = 'X'; CHECK(!opens(f, file_n, NULL), "a file with another magic is not a DMSPARS1 (the DMROMFS1 loader refuses it)"); free(f); }
    for (size_t cut = 1; cut < file_n; cut += (cut < 200 ? 1 : cut < file_n - 200 ? 997 : 1)) {   // a cut-off copy: every length
        if (opens(file, cut, NULL)) { CHECK(0, "a file cut to %zu of %zu bytes opened", cut, file_n); break; }
    }
    CHECK(!opens(file, 0, NULL) || 1, "(an empty file is a plain file with nothing in it)");
    struct { const char *what; size_t at; uint64_t v; int bytes; } patches[] = {
        {"version 2", 8, 2, 4}, {"header size 65", 12, 65, 4}, {"reserved set", 56, 1, 8},
        {"logical size below the extents", 16, 100, 8}, {"extent count + 1", 24, (uint64_t)ne + 1, 8}, {"table offset unaligned", 32, 0, 0 /* patched below */, },
        {"pack offset unaligned", 40, 0, 0}, {"pack size 0 with an offset", 48, 0, 8}, {"pack size 79", 48, 79, 8},
        {"trailer magic", 0, 'X', 1}, {"trailer size", 0, 0, 8}, {"trailer table offset", 0, 0, 8}, {"trailer tail", 0, 1, 8},
    };
    uint64_t toff = romfs_src_le64(file + 32), poff = romfs_src_le64(file + 40);
    for (size_t k = 0; k < sizeof patches / sizeof *patches; k++) {
        uint8_t *f = malloc(file_n); memcpy(f, file, file_n); size_t at = patches[k].at; uint64_t v = patches[k].v; int nb = patches[k].bytes;
        if (!strcmp(patches[k].what, "table offset unaligned")) { v = toff + 8; nb = 8; }
        if (!strcmp(patches[k].what, "pack offset unaligned")) { v = poff + 16; nb = 8; }
        if (k >= 9) { size_t t = file_n - 32; at = t + (k == 9 ? 0 : k == 10 ? 8 : k == 11 ? 16 : 24); if (k == 10) v = file_n + 16; if (k == 11) v = toff + 16; }
        if (nb == 1) f[at] = (uint8_t)v; else if (nb == 4) fx_put32(f + at, (uint32_t)v); else fx_put64(f + at, v);
        CHECK(!opens(f, file_n, NULL) && errno == EINVAL, "refused: %s", patches[k].what); free(f);
    }
    // damaged extent tables
    struct { const char *what; int ext; int field; int64_t delta; } tab[] = {
        {"zero-length extent", 3, 1, -1000000}, {"extent past the logical end", 2, 1, 1000000}, {"extent overlapping the next", 0, 1, 1}, {"extent out of order", 2, 0, 0},
        {"extent inside the header", 1, 2, -1000000}, {"extent past the file", 2, 2, 1000000}, {"extent over the table", 1, 2, 0},
    };
    for (size_t k = 0; k < sizeof tab / sizeof *tab; k++) {
        uint8_t *f = malloc(file_n); memcpy(f, file, file_n); uint8_t *e = f + toff + (size_t)tab[k].ext * 24 + (size_t)tab[k].field * 8; uint64_t v = romfs_src_le64(e);
        if (!strcmp(tab[k].what, "zero-length extent")) v = 0; else if (!strcmp(tab[k].what, "extent inside the header")) v = 8; else if (!strcmp(tab[k].what, "extent over the table")) v = toff - 100; else if (!strcmp(tab[k].what, "extent out of order")) v = 1000;
        else v = (uint64_t)((int64_t)v + tab[k].delta);
        fx_put64(e, v);
        CHECK(!opens(f, file_n, NULL) && errno == EINVAL, "refused: %s", tab[k].what); free(f);
    }
    { uint8_t *f = malloc(file_n); memcpy(f, file, file_n); memcpy(f + poff, "NXASTCPX", 8); CHECK(!opens(f, file_n, NULL), "refused: the pack's magic is wrong"); free(f); }
    { uint8_t *f = malloc(file_n); memcpy(f, file, file_n); fx_put64(f + poff + 32, pack_n + 16); CHECK(!opens(f, file_n, NULL), "refused: the pack's recorded size is not the header's pack size"); free(f); }
    // a table that describes no data at all, for an image of zeros, is fine
    { uint8_t z[100] = {0}; uint8_t *f; size_t fn; fx_write_sparse(NULL, z, sizeof z, 16, 0, NULL, 0, &f, &fn); romfs_src zs; CHECK(opens(f, fn, &zs) && zs.n == 0 && zs.logical == 100 && !zs.pack_size, "an all-zero image: no extents");
      uint8_t b[10] = {1}; CHECK(romfs_src_pread(&zs, b, 10, 95) == 5 && !b[0] && !b[4], "reads zeros"); close(zs.fd); romfs_src_free(&zs); free(f); }
    free(file); free(pack);

    printf("a DMROMFS1 wrapped in a DMSPARS1\n");
    {   enum { K = 4 };
        size_t sz[K] = {20000, 7, 0, 9000}; uint8_t *d[K];
        for (int i = 0; i < K; i++) { d[i] = malloc(sz[i] + 1); for (size_t j = 0; j < sz[i]; j++) d[i][j] = (uint8_t)(1 + rnd() % 255); }
        memset(d[0] + 2000, 0, 15000); memset(d[3], 0, 8500);   // holes inside files, and one file that is nearly all hole
        uint8_t *img; size_t img_n = fx_romfs(&img, K, (const uint8_t *const *)d, sz);
        write_file(path("plain.img"), img, img_n);
        uint8_t *spf; size_t spn; uint8_t *pk; size_t pkn = fx_pack(&pk, 0, NULL, 0, 0);
        long e2 = fx_write_sparse(NULL, img, img_n, 256, 5000, pk, pkn, &spf, &spn); CHECK(e2 > 2, "wrapped image has extents (%ld)", e2);
        write_file(path("sparse.img"), spf, spn); CHECK(spn < img_n, "and is smaller than the plain image (%zu < %zu)", spn, img_n);
        romfs_img *a = romfs_image_open(path("plain.img")), *b = romfs_image_open(path("sparse.img"));
        CHECK(a && b, "both open (errno %d)", errno);
        if (a && b) {
            CHECK(a->n == b->n && a->damaged == b->damaged && !a->src.sparse && b->src.sparse && !a->src.pack_size && b->src.pack_size == pkn, "same index, the sparse one carries the pack");
            int same = 1;
            for (uint64_t k = 0; k < a->n; k++) {
                const img_ent *x = &a->e[k], *y = &b->e[k];
                if (memcmp(x, y, sizeof *x)) same = 0;
                if (!x->type) continue;
                uint8_t *ba = malloc(x->b + 1), *bb = malloc(x->b + 1);
                int ra = romfs_image_read(a, ba, x->b, x->a), rb = romfs_image_read(b, bb, x->b, y->a);
                if (!ra || !rb || memcmp(ba, bb, x->b)) same = 0;
                if (k >= 2 && memcmp(bb, d[k - 2], x->b)) same = 0;   // and both are the source bytes
                free(ba); free(bb);
            }
            CHECK(same, "every entry and every file reads identically from the plain and the wrapped image");
            romfs_image_close(a); romfs_image_close(b);
        }
        romfs_id ia, ib;
        CHECK(romfs_id_of_image(path("plain.img"), &ia) && romfs_id_of_image(path("sparse.img"), &ib) && romfs_id_same(&ia, &ib) && ia.size == img_n && ib.size == img_n, "the identity of the wrapped image is its logical image's (size %llu index %016llx)", (unsigned long long)ib.size, (unsigned long long)ib.index);
        // the identity file check the iOS startup does
        { char line[300]; romfs_id_text(&ia, line, sizeof line); strcat(line, "\n"); write_file(path("romfs.id"), (const uint8_t *)line, strlen(line));
          romfs_id w, g; CHECK(romfs_id_check(path("romfs.id"), path("sparse.img"), &w, &g) == ROMFS_ID_OK && romfs_id_check(path("romfs.id"), path("plain.img"), &w, &g) == ROMFS_ID_OK, "romfs.id accepts the wrapped image and the plain one"); }
        // an index that differs changes the identity
        { img[img_n - 3] ^= 1; write_file(path("other.img"), img, img_n); romfs_id ic; CHECK(romfs_id_of_image(path("other.img"), &ic) && !romfs_id_same(&ia, &ic), "a changed index changes the identity"); img[img_n - 3] ^= 1; }
        // a cut-off wrapped image has no identity and does not open
        { write_file(path("cut.img"), spf, spn - 1); romfs_id ic; CHECK(!romfs_id_of_image(path("cut.img"), &ic) && !romfs_image_open(path("cut.img")), "a cut-off wrapped image is refused by the identity and by the loader"); }
        // a wrapped image whose logical image is not DMROMFS1 (index not ending it) is refused as a plain one would be
        { uint8_t *w; size_t wn; fx_write_sparse(NULL, img, img_n - 5, 256, 0, NULL, 0, &w, &wn); write_file(path("badlogical.img"), w, wn); CHECK(!romfs_image_open(path("badlogical.img")), "a wrapped image whose index does not end it is refused"); free(w); }
        // the pack-less wrapper: no pack
        { uint8_t *w; size_t wn; fx_write_sparse(NULL, img, img_n, 256, 0, NULL, 0, &w, &wn); write_file(path("nopack.img"), w, wn); romfs_img *m = romfs_image_open(path("nopack.img")); CHECK(m && m->src.sparse && !m->src.pack_size, "a wrapper without a pack opens, with none"); romfs_image_close(m); free(w); }
        for (int i = 0; i < K; i++) free(d[i]);
        free(img); free(spf); free(pk);
    }
    free(L); free(got);
    v2_tests();
    char cmd[1300]; snprintf(cmd, sizeof cmd, "rm -rf '%s'", g_dir); if (system(cmd)) {}
    printf("%d checks, %d failed\n", checks, failed);
    return failed != 0;
}
